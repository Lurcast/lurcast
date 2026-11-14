require "socket"

# An IPv4 or IPv6 address or CIDR range, such as `203.0.113.7`, `10.0.0.0/8`, or `2001:db8::/32`.
# IPv4-mapped IPv6 addresses (`::ffff:203.0.113.7`) count as IPv4.
struct IPNetwork
  getter bytes : Bytes
  getter prefix : Int32

  def initialize(@bytes : Bytes, @prefix : Int32)
  end

  def self.parse?(entry : String) : IPNetwork?
    address, slash, prefix_text = entry.strip.partition('/')
    bytes = address_bytes(address)
    return unless bytes
    prefix = slash.empty? ? bytes.size * 8 : prefix_text.to_i?
    return unless prefix && 0 <= prefix <= bytes.size * 8
    new(bytes, prefix)
  end

  def self.valid_address?(address : String) : Bool
    !address_bytes(address).nil?
  end

  # IPv4 addresses as 4 bytes, IPv6 as 16; brackets and a zone (`%eth0`) are ignored.
  def self.address_bytes(address : String) : Bytes?
    address = address.lchop('[').rchop(']')
    if fields = Socket::IPAddress.parse_v4_fields?(address)
      return Bytes.new(4) { |i| fields[i] }
    end
    fields = Socket::IPAddress.parse_v6_fields?(address.split('%').first)
    return unless fields
    bytes = Bytes.new(16)
    fields.each_with_index do |field, i|
      bytes[i * 2] = (field >> 8).to_u8
      bytes[i * 2 + 1] = (field & 0xff).to_u8
    end
    mapped = bytes[0, 10].all?(&.zero?) && bytes[10] == 0xff && bytes[11] == 0xff
    mapped ? bytes[12, 4].dup : bytes
  end

  def includes?(address : String) : Bool
    other = IPNetwork.address_bytes(address)
    !other.nil? && includes?(other)
  end

  def includes?(other : Bytes) : Bool
    return false unless @bytes.size == other.size
    full, rest = @prefix.divmod(8)
    return false unless @bytes[0, full] == other[0, full]
    return true if rest.zero?
    mask = (0xff_u8 << (8 - rest))
    (@bytes[full] & mask) == (other[full] & mask)
  end
end
