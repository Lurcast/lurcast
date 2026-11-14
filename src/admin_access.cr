# Who is signed in to an admin endpoint. The server admin may see and change everything. A login
# that an extension grants (a Hosting edition customer, for example) is limited to its own mounts:
# it sees only those, may only act on them, and cannot reload the configuration.
struct AdminAccess
  getter user : String
  # The mounts this login may manage, or nil for every mount.
  getter mounts : Set(String)?

  def initialize(@user : String, mounts : Enumerable(String)? = nil)
    @mounts = mounts.try(&.to_set)
  end

  def full? : Bool
    @mounts.nil?
  end

  def allows?(mount : String) : Bool
    mounts = @mounts
    mounts.nil? || mounts.includes?(mount)
  end
end
