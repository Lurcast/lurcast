require "json"
require "log"
require "./ip_network"

# Listeners refused by address (or address range) or by player. A ban applies to one mount or to
# every mount, and may expire. With `data_dir` set, bans are kept in `bans.json` there, so they
# survive restarts; the file is read again when the configuration reloads.
class BanList
  Log = ::Log.for("lurcast.bans")

  MAX_BANS            = 10_000
  MIN_USER_AGENT_SIZE =      3
  MAX_VALUE_SIZE      =    512
  MAX_REASON_SIZE     =    200

  enum Kind
    Address
    UserAgent
  end

  @[JSON::Serializable::Options(emit_nulls: true)]
  record Ban,
    id : String,
    kind : Kind,
    value : String,
    mount : String?,
    reason : String?,
    created_by : String,
    created_at : Time,
    expires_at : Time? do
    include JSON::Serializable

    def expired?(now = Time.utc) : Bool
      expires = expires_at
      !expires.nil? && expires <= now
    end

    def applies_to?(mount : String) : Bool
      scope = self.mount
      scope.nil? || scope == mount
    end
  end

  # A ban with its address range parsed, or its player text lowercased, once.
  private record Entry, ban : Ban, network : IPNetwork?, agent : String

  getter path : String?
  @entries = [] of Entry
  @mutex = Mutex.new

  def initialize(@path : String?)
    load
  end

  def persistent? : Bool
    !@path.nil?
  end

  # Reads the file again, for example after someone edited it. A broken file keeps the current bans.
  def load : Nil
    path = @path
    return unless path && File.exists?(path)
    entries = Array(Ban).from_json(File.read(path)).compact_map { |ban| entry(ban) }
    @mutex.synchronize { @entries = entries }
  rescue ex : JSON::ParseException | IO::Error
    Log.error { "Could not read #{path}; keeping the current bans: #{ex.message}" }
  end

  # The bans in effect, oldest first.
  def list(now = Time.utc) : Array(Ban)
    @mutex.synchronize do
      prune(now)
      @entries.map(&.ban)
    end
  end

  def find(id : String) : Ban?
    @mutex.synchronize { @entries.find { |entry| entry.ban.id == id }.try(&.ban) }
  end

  # The ban that refuses a listener at *address* with *user_agent* on *mount*, or nil.
  def match(address : String, user_agent : String, mount : String, now = Time.utc) : Ban?
    bytes = IPNetwork.address_bytes(address)
    agent = user_agent.downcase
    @mutex.synchronize do
      @entries.each do |entry|
        ban = entry.ban
        next if ban.expired?(now) || !ban.applies_to?(mount)
        network = entry.network
        matched = network ? (!bytes.nil? && network.includes?(bytes)) : agent.includes?(entry.agent)
        return ban if matched
      end
    end
    nil
  end

  # Adds a ban. *value* is an address or CIDR range for `Kind::Address`, or text found in the
  # player's User-Agent for `Kind::UserAgent`. Raises ArgumentError for invalid input.
  def add(kind : Kind, value : String, *, mount : String?, reason : String?, created_by : String,
          duration : Time::Span? = nil, now = Time.utc) : Ban
    value = value.strip
    raise ArgumentError.new("the value is longer than #{MAX_VALUE_SIZE} characters") if value.size > MAX_VALUE_SIZE
    if kind.address?
      network = IPNetwork.parse?(value) || raise ArgumentError.new("#{value} is not an IP address or CIDR range")
      minimum = network.bytes.size == 4 ? 8 : 16
      raise ArgumentError.new("#{value} is too wide; use a /#{minimum} or narrower range") if network.prefix < minimum
    elsif value.size < MIN_USER_AGENT_SIZE
      raise ArgumentError.new("a player ban needs at least #{MIN_USER_AGENT_SIZE} characters")
    end
    raise ArgumentError.new("the duration must be positive") if duration && !duration.positive?
    reason = reason.try(&.strip.presence).try(&.[0, MAX_REASON_SIZE]?)
    ban = Ban.new(Random::Secure.hex(8), kind, value, mount, reason, created_by, now, duration.try { |span| now + span })

    @mutex.synchronize do
      prune(now)
      raise ArgumentError.new("there are already #{MAX_BANS} bans") if @entries.size >= MAX_BANS
      @entries << (entry(ban) || raise ArgumentError.new("invalid ban"))
      save
    end
    ban
  end

  def remove(id : String) : Ban?
    @mutex.synchronize do
      index = @entries.index { |entry| entry.ban.id == id }
      return unless index
      removed = @entries.delete_at(index)
      save
      removed.ban
    end
  end

  private def entry(ban : Ban) : Entry?
    if ban.kind.address?
      network = IPNetwork.parse?(ban.value)
      unless network
        Log.warn { "Ignoring ban #{ban.id}: #{ban.value} is not an IP address or range" }
        return
      end
      Entry.new(ban, network, "")
    else
      Entry.new(ban, nil, ban.value.downcase)
    end
  end

  private def prune(now : Time) : Nil
    @entries.reject!(&.ban.expired?(now))
  end

  # Writes the bans in effect, replacing the file atomically. Called with the mutex held.
  private def save : Nil
    return unless path = @path
    Dir.mkdir_p(File.dirname(path))
    temporary = "#{path}.#{Random::Secure.hex(4)}.tmp"
    File.write(temporary, @entries.map(&.ban).to_pretty_json, perm: 0o600)
    File.rename(temporary, path)
  rescue ex : IO::Error
    Log.error { "Could not save bans to #{path}: #{ex.message}" }
  end
end
