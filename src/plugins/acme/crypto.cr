require "base64"
require "digest/sha256"
require "json"
require "./lib_crypto"

module Lurcast::ACMESupport
  class CryptoError < Exception
    # Raises with *message* and the most recent libcrypto error, clearing the error queue.
    def self.raise_last(message : String) : NoReturn
      details = [] of String
      while (code = LibCrypto.err_get_error) != 0
        buffer = Bytes.new(256)
        LibAcmeCrypto.err_error_string_n(code, buffer.to_unsafe.as(LibC::Char*), buffer.size)
        details << String.new(buffer.to_unsafe)
      end
      raise new(details.empty? ? message : "#{message}: #{details.join("; ")}")
    end
  end

  def self.base64url(data : Bytes | String) : String
    Base64.urlsafe_encode(data, padding: false)
  end

  # Runs the block with a read-only memory BIO over *data*, freeing it afterwards.
  def self.with_read_bio(data : String | Bytes, &)
    bytes = data.to_slice
    bio = LibAcmeCrypto.bio_new_mem_buf(bytes.to_unsafe.as(Void*), bytes.size)
    CryptoError.raise_last("BIO_new_mem_buf failed") if bio.null?
    begin
      yield bio
    ensure
      LibCrypto.BIO_free(bio)
    end
  end

  # Runs the block with a writable memory BIO and returns what it wrote.
  def self.write_bio(&) : String
    bio = LibCrypto.BIO_new(LibAcmeCrypto.bio_s_mem)
    CryptoError.raise_last("BIO_new failed") if bio.null?
    begin
      yield bio
      data = Pointer(UInt8).null
      size = LibCrypto.BIO_ctrl(bio, LibAcmeCrypto::BIO_CTRL_INFO, 0, pointerof(data).as(Void*))
      String.new(data, size)
    ensure
      LibCrypto.BIO_free(bio)
    end
  end

  # The DNS names in a GENERAL_NAMES stack, which it frees.
  def self.dns_names(names : LibAcmeCrypto::STACK) : Array(String)
    return [] of String if names.null?
    result = [] of String
    LibCrypto.sk_num(names).times do |index|
      name = LibCrypto.sk_value(names, index).as(LibAcmeCrypto::GeneralName*).value
      next unless name.type == LibCrypto::GEN_DNS
      data = LibCrypto.asn1_string_get0_data(name.d)
      result << String.new(data, LibCrypto.asn1_string_length(name.d)).downcase
    end
    result
  ensure
    LibAcmeCrypto.general_names_free(names) unless names.null?
  end

  # An ECDSA P-256 private key, used both for the ACME account (ES256) and for certificates.
  class Key
    getter pointer : LibAcmeCrypto::EVP_PKEY

    def self.generate : Key
      pointer = LibAcmeCrypto.evp_pkey_q_keygen(nil, nil, "EC", "P-256".to_unsafe)
      CryptoError.raise_last("Could not generate a P-256 key") if pointer.null?
      new(pointer)
    end

    def self.from_pem(pem : String) : Key
      pointer = ACMESupport.with_read_bio(pem) { |bio| LibAcmeCrypto.pem_read_bio_private_key(bio, nil, nil, nil) }
      CryptoError.raise_last("Could not read the private key") if pointer.null?
      key = new(pointer)
      key.public_coordinates # rejects keys that are not EC P-256
      key
    end

    def initialize(@pointer : LibAcmeCrypto::EVP_PKEY)
    end

    def finalize
      LibAcmeCrypto.evp_pkey_free(@pointer)
    end

    def to_pem : String
      ACMESupport.write_bio do |bio|
        if LibAcmeCrypto.pem_write_bio_private_key(bio, @pointer, nil, nil, 0, nil, nil) != 1
          CryptoError.raise_last("Could not write the private key")
        end
      end
    end

    # The public point as 32-byte big-endian X and Y coordinates.
    def public_coordinates : Tuple(Bytes, Bytes)
      {coordinate("qx"), coordinate("qy")}
    end

    # The public key as a JWK (RFC 7517), with only the members a thumbprint uses.
    def jwk : Hash(String, String)
      x, y = public_coordinates
      {"crv" => "P-256", "kty" => "EC", "x" => ACMESupport.base64url(x), "y" => ACMESupport.base64url(y)}
    end

    def thumbprint : String
      ACMESupport.thumbprint(jwk)
    end

    # An ES256 signature of *data*: the raw 64-byte r || s form JWS uses.
    def sign(data : Bytes | String) : Bytes
      ACMESupport.ecdsa_der_to_raw(sign_der(data.to_slice))
    end

    # Checks a raw r || s ES256 signature.
    def verify(data : Bytes | String, signature : Bytes) : Bool
      return false unless signature.size == 64
      der = ACMESupport.ecdsa_raw_to_der(signature)
      bytes = data.to_slice
      with_digest_context do |context|
        if LibAcmeCrypto.evp_digest_verify_init(context, nil, LibCrypto.evp_sha256, nil, @pointer) != 1
          CryptoError.raise_last("EVP_DigestVerifyInit failed")
        end
        LibAcmeCrypto.evp_digest_verify(context, der.to_unsafe, der.size, bytes.to_unsafe, bytes.size) == 1
      end
    end

    private def sign_der(data : Bytes) : Bytes
      with_digest_context do |context|
        if LibAcmeCrypto.evp_digest_sign_init(context, nil, LibCrypto.evp_sha256, nil, @pointer) != 1
          CryptoError.raise_last("EVP_DigestSignInit failed")
        end
        length = LibC::SizeT.new(0)
        if LibAcmeCrypto.evp_digest_sign(context, nil, pointerof(length), data.to_unsafe, data.size) != 1
          CryptoError.raise_last("EVP_DigestSign failed")
        end
        signature = Bytes.new(length)
        if LibAcmeCrypto.evp_digest_sign(context, signature.to_unsafe, pointerof(length), data.to_unsafe, data.size) != 1
          CryptoError.raise_last("EVP_DigestSign failed")
        end
        signature[0, length]
      end
    end

    private def with_digest_context(&)
      context = LibCrypto.evp_md_ctx_new
      CryptoError.raise_last("EVP_MD_CTX_new failed") if context.null?
      begin
        yield context
      ensure
        LibCrypto.evp_md_ctx_free(context)
      end
    end

    private def coordinate(name : String) : Bytes
      number = Pointer(Void).null
      if LibAcmeCrypto.evp_pkey_get_bn_param(@pointer, name, pointerof(number)) != 1
        CryptoError.raise_last("The key is not an EC P-256 key")
      end
      begin
        bytes = Bytes.new(32)
        CryptoError.raise_last("The key is not an EC P-256 key") if LibAcmeCrypto.bn_bn2binpad(number, bytes, 32) != 32
        bytes
      ensure
        LibAcmeCrypto.bn_free(number)
      end
    end
  end

  # The JWK thumbprint (RFC 7638): SHA-256 over the required members in lexical order, base64url.
  def self.thumbprint(jwk : Hash(String, String)) : String
    json = JSON.build do |builder|
      builder.object do
        jwk.keys.sort!.each { |name| builder.field(name, jwk[name]) }
      end
    end
    base64url(Digest::SHA256.digest(json))
  end

  # Converts a DER ECDSA-Sig-Value (SEQUENCE of two INTEGERs) to the fixed-size r || s form.
  def self.ecdsa_der_to_raw(der : Bytes, size = 32) : Bytes
    reader = IO::Memory.new(der)
    raise CryptoError.new("Invalid ECDSA signature") unless reader.read_byte == 0x30
    read_der_length(reader)
    raw = Bytes.new(size * 2)
    2.times do |index|
      raise CryptoError.new("Invalid ECDSA signature") unless reader.read_byte == 0x02
      value = Bytes.new(read_der_length(reader))
      reader.read_fully(value)
      while value.size > size && value[0] == 0
        value = value[1..]
      end
      raise CryptoError.new("Invalid ECDSA signature") if value.size > size
      value.copy_to(raw[index * size + size - value.size, value.size])
    end
    raw
  end

  # Converts a raw r || s signature back to DER, as libcrypto verifies it.
  def self.ecdsa_raw_to_der(raw : Bytes) : Bytes
    half = raw.size // 2
    integers = {raw[0, half], raw[half, half]}.map do |value|
      while value.size > 1 && value[0] == 0
        value = value[1..]
      end
      value = Bytes[0] + value if value[0] >= 0x80
      Bytes[0x02, value.size] + value
    end
    body = integers[0] + integers[1]
    Bytes[0x30, body.size] + body
  end

  private def self.read_der_length(reader : IO) : Int32
    first = reader.read_byte || raise CryptoError.new("Invalid ECDSA signature")
    return first.to_i if first < 0x80
    length = 0
    (first & 0x7f).times { length = (length << 8) | (reader.read_byte || raise CryptoError.new("Invalid ECDSA signature")).to_i }
    length
  end

  # A certificate signing request (DER) for *domains*, signed with *key*: the first domain is the
  # common name and every domain is a subjectAltName.
  def self.csr(key : Key, domains : Array(String)) : Bytes
    raise ArgumentError.new("A certificate needs at least one domain") if domains.empty?
    request = LibAcmeCrypto.x509_req_new
    CryptoError.raise_last("X509_REQ_new failed") if request.null?
    begin
      LibAcmeCrypto.x509_req_set_version(request, 0)
      name = LibAcmeCrypto.x509_req_get_subject_name(request)
      common_name = domains.first
      if LibAcmeCrypto.x509_name_add_entry_by_nid(name, LibCrypto::NID_commonName, LibAcmeCrypto::MBSTRING_ASC, common_name, common_name.bytesize, -1, 0) != 1
        CryptoError.raise_last("Could not set the common name")
      end
      CryptoError.raise_last("X509_REQ_set_pubkey failed") if LibAcmeCrypto.x509_req_set_pubkey(request, key.pointer) != 1
      add_subject_alt_names(request, domains)
      CryptoError.raise_last("X509_REQ_sign failed") if LibAcmeCrypto.x509_req_sign(request, key.pointer, LibCrypto.evp_sha256) <= 0
      length = LibAcmeCrypto.i2d_x509_req(request, nil)
      CryptoError.raise_last("i2d_X509_REQ failed") if length <= 0
      der = Bytes.new(length)
      output = der.to_unsafe
      LibAcmeCrypto.i2d_x509_req(request, pointerof(output))
      der
    ensure
      LibAcmeCrypto.x509_req_free(request)
    end
  end

  private def self.add_subject_alt_names(request : LibAcmeCrypto::X509_REQ, domains : Array(String)) : Nil
    extension = LibAcmeCrypto.x509v3_ext_conf_nid(nil, nil, LibCrypto::NID_subject_alt_name, domains.join(',') { |domain| "DNS:#{domain}" })
    CryptoError.raise_last("Could not build the subjectAltName extension") if extension.null?
    stack = LibAcmeCrypto.openssl_sk_new_null
    begin
      CryptoError.raise_last("OPENSSL_sk_new_null failed") if stack.null?
      LibAcmeCrypto.openssl_sk_push(stack, extension.as(Void*))
      CryptoError.raise_last("X509_REQ_add_extensions failed") if LibAcmeCrypto.x509_req_add_extensions(request, stack) != 1
    ensure
      LibCrypto.sk_free(stack) unless stack.null?
      LibCrypto.x509_extension_free(extension)
    end
  end

  # The subjectAltName DNS names in a DER certificate request, and whether *key* signed it.
  def self.csr_details(der : Bytes, key : Key) : Tuple(Array(String), Bool)
    input = der.to_unsafe
    request = LibAcmeCrypto.d2i_x509_req(nil, pointerof(input), der.size)
    CryptoError.raise_last("Invalid certificate request") if request.null?
    begin
      extensions = LibAcmeCrypto.x509_req_get_extensions(request)
      names = begin
        dns_names(LibAcmeCrypto.x509v3_get_d2i(extensions, LibCrypto::NID_subject_alt_name, nil, nil))
      ensure
        unless extensions.null?
          LibCrypto.sk_num(extensions).times do |index|
            LibCrypto.x509_extension_free(LibCrypto.sk_value(extensions, index).as(LibAcmeCrypto::X509Extension))
          end
          LibCrypto.sk_free(extensions)
        end
      end
      {names, LibAcmeCrypto.x509_req_verify(request, key.pointer) == 1}
    ensure
      LibAcmeCrypto.x509_req_free(request)
    end
  end

  # What the plugin needs to know about a certificate: its names and validity.
  record CertificateInfo, names : Array(String), not_before : Time, not_after : Time do
    # Reads the first certificate in *pem*; nil when *key* is given and is not the certificate's key.
    def self.parse(pem : String, key : Key? = nil) : CertificateInfo?
      certificate = ACMESupport.with_read_bio(pem) { |bio| LibAcmeCrypto.pem_read_bio_x509(bio, nil, nil, nil) }
      CryptoError.raise_last("Could not read the certificate") if certificate.null?
      begin
        return if key && LibAcmeCrypto.x509_check_private_key(certificate, key.pointer) != 1
        names = ACMESupport.dns_names(LibCrypto.x509_get_ext_d2i(certificate, LibCrypto::NID_subject_alt_name, nil, nil))
        new(names, time(LibAcmeCrypto.x509_get0_not_before(certificate)), time(LibAcmeCrypto.x509_get0_not_after(certificate)))
      ensure
        LibCrypto.x509_free(certificate)
        while LibCrypto.err_get_error != 0 # a failed key check leaves errors behind
        end
      end
    end

    private def self.time(value : LibAcmeCrypto::ASN1_TIME) : Time
      now = Time.utc
      days = 0
      seconds = 0
      CryptoError.raise_last("Invalid certificate time") if LibAcmeCrypto.asn1_time_diff(pointerof(days), pointerof(seconds), nil, value) != 1
      now + days.days + seconds.seconds
    end

    def covers?(domains : Array(String)) : Bool
      domains.all? { |domain| names.includes?(domain) }
    end

    def lifetime : Time::Span
      not_after - not_before
    end
  end
end
