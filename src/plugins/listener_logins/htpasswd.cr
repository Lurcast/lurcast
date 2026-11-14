require "base64"
require "crypto/bcrypt/password"
require "crypto/subtle"
require "digest/md5"
require "digest/sha1"

module Lurcast::Plugins
  # A password file in the Apache `htpasswd` format: one `user:hash` per line. Reads bcrypt
  # (`$2y$`, `$2a$`, `$2b$`), Apache MD5 (`$apr1$`), `{SHA}` and Icecast's plain MD5 hex hashes;
  # writes bcrypt. The file is read again when it changes on disk, so it can be edited by hand.
  class Htpasswd
    BCRYPT_COST = 10
    CHECK_EVERY = 1.second

    getter path : String
    @users = {} of String => String
    @mtime : Time? = nil
    @checked_at : Time::Instant? = nil
    @mutex = Mutex.new

    def initialize(@path : String)
    end

    def self.valid_user?(user : String) : Bool
      !user.empty? && user.size <= 255 && user.each_char.none? { |char| char == ':' || char.control? }
    end

    def users : Array(String)
      @mutex.synchronize do
        refresh
        @users.keys.sort!
      end
    end

    def includes?(user : String) : Bool
      @mutex.synchronize do
        refresh
        @users.has_key?(user)
      end
    end

    # The stored hash for *user*, or nil.
    def hash_for(user : String) : String?
      @mutex.synchronize do
        refresh
        @users[user]?
      end
    end

    def verify?(user : String, password : String) : Bool
      hash = hash_for(user) || return false
      Htpasswd.matches?(hash, password)
    end

    # Adds *user* or changes their password.
    def set(user : String, password : String) : Nil
      raise ArgumentError.new("invalid user name") unless Htpasswd.valid_user?(user)
      raise ArgumentError.new("the password must not be empty") if password.empty?
      hash = Crypto::Bcrypt::Password.create(password, cost: BCRYPT_COST).to_s
      @mutex.synchronize do
        refresh(force: true)
        @users[user] = hash
        write
      end
    end

    # Returns false when there was no such user.
    def delete(user : String) : Bool
      @mutex.synchronize do
        refresh(force: true)
        removed = !@users.delete(user).nil?
        write if removed
        removed
      end
    end

    def self.matches?(hash : String, password : String) : Bool
      if hash.starts_with?("$2")
        Crypto::Bcrypt::Password.new(hash).verify(password)
      elsif hash.starts_with?("$apr1$")
        salt = hash.lchop("$apr1$").partition('$')[0]
        Crypto::Subtle.constant_time_compare(apr1(password, salt), hash)
      elsif hash.starts_with?("{SHA}")
        Crypto::Subtle.constant_time_compare("{SHA}#{Base64.strict_encode(Digest::SHA1.digest(password))}", hash)
      elsif hash.size == 32 && hash.each_char.all?(&.hex?)
        Crypto::Subtle.constant_time_compare(Digest::MD5.hexdigest(password), hash.downcase)
      else
        false
      end
    rescue ArgumentError | Crypto::Bcrypt::Error
      false
    end

    ITOA64 = "./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

    # Apache's MD5-based crypt, `$apr1$salt$hash`.
    def self.apr1(password : String, salt : String) : String
      magic = "$apr1$"
      salt = salt[0, Math.min(salt.size, 8)]
      alternate = Digest::MD5.digest { |ctx| ctx << password << salt << password }
      result = Digest::MD5.digest do |ctx|
        ctx << password << magic << salt
        length = password.bytesize
        while length > 0
          ctx << alternate[0, Math.min(length, 16)]
          length -= 16
        end
        bits = password.bytesize
        while bits > 0
          bits.odd? ? (ctx << Bytes[0]) : (ctx << password.to_slice[0, 1])
          bits >>= 1
        end
      end
      1000.times do |round|
        result = Digest::MD5.digest do |ctx|
          round.odd? ? (ctx << password) : (ctx << result)
          ctx << salt if round % 3 != 0
          ctx << password if round % 7 != 0
          round.odd? ? (ctx << result) : (ctx << password)
        end
      end
      encoded = String.build do |io|
        { {0, 6, 12}, {1, 7, 13}, {2, 8, 14}, {3, 9, 15}, {4, 10, 5} }.each do |first, second, third|
          to64(io, (result[first].to_u32 << 16) | (result[second].to_u32 << 8) | result[third], 4)
        end
        to64(io, result[11].to_u32, 2)
      end
      "#{magic}#{salt}$#{encoded}"
    end

    private def self.to64(io : IO, value : UInt32, count : Int32) : Nil
      count.times do
        io << ITOA64[(value & 0x3f).to_i]
        value >>= 6
      end
    end

    private def refresh(force = false) : Nil
      now = Time.instant
      unless force
        checked = @checked_at
        return if checked && now - checked < CHECK_EVERY
      end
      @checked_at = now
      info = File.info?(@path)
      unless info
        @users.clear
        @mtime = nil
        return
      end
      return if info.modification_time == @mtime
      users = {} of String => String
      File.each_line(@path) do |line|
        line = line.strip
        next if line.empty? || line.starts_with?('#')
        user, separator, hash = line.partition(':')
        users[user] = hash.strip unless separator.empty? || user.empty?
      end
      @users = users
      @mtime = info.modification_time
    rescue ex : IO::Error
      Log.error { "Could not read the listener logins in #{@path}: #{ex.message}" }
    end

    private def write : Nil
      directory = File.dirname(@path)
      Dir.mkdir_p(directory)
      temporary = File.join(directory, ".#{File.basename(@path)}.#{Random::Secure.hex(4)}.tmp")
      File.open(temporary, "w", perm: 0o600) do |file|
        @users.each { |user, hash| file << user << ':' << hash << '\n' }
      end
      File.rename(temporary, @path)
      @mtime = File.info(@path).modification_time
    end
  end
end
