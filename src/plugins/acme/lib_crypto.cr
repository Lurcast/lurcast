require "openssl"

# The libcrypto (OpenSSL 3.0+) functions the ACME plugin needs beyond Crystal's standard library:
# key generation, signing, PEM, certificate requests, and certificate inspection. Functions the
# standard library already binds (`LibCrypto`) are used from there, since a C function can only be
# bound with one signature. `LibCrypto` also links libcrypto (through pkg-config), so this binding
# adds no `@[Link]` of its own, which would only pass `-lcrypto` to the linker twice.
lib LibAcmeCrypto
  alias Char = LibC::Char
  alias Int = LibC::Int
  alias Long = LibC::Long
  alias ULong = LibC::ULong
  alias SizeT = LibC::SizeT

  alias Bio = LibCrypto::Bio
  alias BioMethod = LibCrypto::BioMethod
  alias EvpMd = LibCrypto::EVP_MD
  alias EvpMdCtx = LibCrypto::EVP_MD_CTX
  alias X509 = LibCrypto::X509
  alias X509Name = LibCrypto::X509_NAME
  alias X509Extension = LibCrypto::X509_EXTENSION
  alias Asn1String = LibCrypto::ASN1_STRING
  alias STACK = Void*

  type EVP_PKEY = Void*
  alias BIGNUM = Void*
  type X509_REQ = Void*
  type ASN1_TIME = Void*

  struct GeneralName
    type : Int
    d : Asn1String
  end

  MBSTRING_ASC  = 0x1001
  BIO_CTRL_INFO =      3

  fun evp_pkey_q_keygen = EVP_PKEY_Q_keygen(libctx : Void*, propq : Char*, type : Char*, ...) : EVP_PKEY
  fun evp_pkey_free = EVP_PKEY_free(pkey : EVP_PKEY)
  fun evp_pkey_get_bn_param = EVP_PKEY_get_bn_param(pkey : EVP_PKEY, key_name : Char*, bn : BIGNUM*) : Int
  fun bn_bn2binpad = BN_bn2binpad(bn : BIGNUM, to : UInt8*, tolen : Int) : Int
  fun bn_free = BN_free(bn : BIGNUM)

  fun evp_digest_sign_init = EVP_DigestSignInit(ctx : EvpMdCtx, pctx : Void**, type : EvpMd, engine : Void*, pkey : EVP_PKEY) : Int
  fun evp_digest_sign = EVP_DigestSign(ctx : EvpMdCtx, sig : UInt8*, siglen : SizeT*, tbs : UInt8*, tbslen : SizeT) : Int
  fun evp_digest_verify_init = EVP_DigestVerifyInit(ctx : EvpMdCtx, pctx : Void**, type : EvpMd, engine : Void*, pkey : EVP_PKEY) : Int
  fun evp_digest_verify = EVP_DigestVerify(ctx : EvpMdCtx, sig : UInt8*, siglen : SizeT, tbs : UInt8*, tbslen : SizeT) : Int

  fun bio_s_mem = BIO_s_mem : BioMethod*
  fun bio_new_mem_buf = BIO_new_mem_buf(buf : Void*, len : Int) : Bio*

  fun pem_write_bio_private_key = PEM_write_bio_PrivateKey(bio : Bio*, pkey : EVP_PKEY, enc : Void*, kstr : UInt8*, klen : Int, cb : Void*, u : Void*) : Int
  fun pem_read_bio_private_key = PEM_read_bio_PrivateKey(bio : Bio*, x : Void*, cb : Void*, u : Void*) : EVP_PKEY
  fun pem_read_bio_x509 = PEM_read_bio_X509(bio : Bio*, x : Void*, cb : Void*, u : Void*) : X509

  fun x509_get0_not_before = X509_get0_notBefore(x : X509) : ASN1_TIME
  fun x509_get0_not_after = X509_get0_notAfter(x : X509) : ASN1_TIME
  fun x509_check_private_key = X509_check_private_key(x : X509, pkey : EVP_PKEY) : Int
  fun asn1_time_diff = ASN1_TIME_diff(pday : Int*, psec : Int*, from : ASN1_TIME, to : ASN1_TIME) : Int

  fun x509_req_new = X509_REQ_new : X509_REQ
  fun x509_req_free = X509_REQ_free(req : X509_REQ)
  fun x509_req_set_version = X509_REQ_set_version(req : X509_REQ, version : Long) : Int
  fun x509_req_get_subject_name = X509_REQ_get_subject_name(req : X509_REQ) : X509Name
  fun x509_name_add_entry_by_nid = X509_NAME_add_entry_by_NID(name : X509Name, nid : Int, type : Int, bytes : UInt8*, len : Int, loc : Int, set : Int) : Int
  fun x509_req_set_pubkey = X509_REQ_set_pubkey(req : X509_REQ, pkey : EVP_PKEY) : Int
  fun x509_req_add_extensions = X509_REQ_add_extensions(req : X509_REQ, exts : STACK) : Int
  fun x509_req_get_extensions = X509_REQ_get_extensions(req : X509_REQ) : STACK
  fun x509_req_sign = X509_REQ_sign(req : X509_REQ, pkey : EVP_PKEY, md : EvpMd) : Int
  fun x509_req_verify = X509_REQ_verify(req : X509_REQ, pkey : EVP_PKEY) : Int
  fun i2d_x509_req = i2d_X509_REQ(req : X509_REQ, out : UInt8**) : Int
  fun d2i_x509_req = d2i_X509_REQ(req : Void*, input : UInt8**, length : Long) : X509_REQ
  fun x509v3_ext_conf_nid = X509V3_EXT_conf_nid(conf : Void*, ctx : Void*, ext_nid : Int, value : Char*) : X509Extension
  fun x509v3_get_d2i = X509V3_get_d2i(exts : STACK, nid : Int, crit : Int*, idx : Int*) : STACK
  fun general_names_free = GENERAL_NAMES_free(names : STACK)

  fun openssl_sk_new_null = OPENSSL_sk_new_null : STACK
  fun openssl_sk_push = OPENSSL_sk_push(sk : STACK, data : Void*) : Int

  fun err_error_string_n = ERR_error_string_n(error : ULong, buf : Char*, len : SizeT)
end
