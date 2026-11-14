require "./ip_network"

# Decides which address to show for a request that came through a reverse proxy. Only proxies in
# the configured list are believed: the client address is the last `X-Forwarded-For` entry that is
# not itself a trusted proxy, so a client cannot spoof its address by sending the header.
class TrustedProxies
  @networks : Array(IPNetwork)

  # *entries* are addresses or CIDR ranges, such as `127.0.0.1` or `10.0.0.0/8`.
  def initialize(entries : Array(String))
    @networks = entries.map { |entry| IPNetwork.parse?(entry) || raise ArgumentError.new("invalid trusted proxy #{entry}") }
  end

  def self.valid?(entry : String) : Bool
    !IPNetwork.parse?(entry).nil?
  end

  def trusted?(address : String) : Bool
    bytes = IPNetwork.address_bytes(address)
    return false unless bytes
    @networks.any?(&.includes?(bytes))
  end

  def client_address(socket_address : String, forwarded_for : String?) : String
    return socket_address if @networks.empty? || !trusted?(socket_address) || forwarded_for.nil?
    hops = forwarded_for.split(',').map(&.strip).reject(&.empty?)
    hops.reverse_each do |hop|
      hop = hop.lchop('[').rchop(']')
      return socket_address unless IPNetwork.valid_address?(hop)
      return hop unless trusted?(hop)
    end
    hops.first?.try(&.lchop('[').rchop(']')) || socket_address
  end
end
