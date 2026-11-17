# Finds the places where a listener can start a stream that needs its headers first, such as native
# FLAC or WebM, so late-joining listeners get the headers and then audio from a clean boundary.
# The mount feeds it every byte it publishes, in order; offsets count those bytes from the start.
abstract class StreamJoin
  # A place to start at *offset*: send *header* (the stream's headers) and *extra* (anything the
  # container needs to resume there, such as a Matroska cluster header), then the stream from *offset*.
  record Point, offset : Int64, header : Bytes, extra : Bytes = Bytes.empty

  # Bytes fed so far.
  getter position = 0_i64

  # Join points older than this many bytes are dropped.
  getter window : Int32

  def initialize(@window : Int32)
  end

  def feed(data : Bytes) : Nil
    return if data.empty?
    scan(data)
    @position += data.size
    prune(@position - @window)
  end

  # The stream's headers, once they are known.
  abstract def header : Bytes?

  # The first join point at or after *from*, with the bytes to send before it.
  abstract def join(from : Int64) : Point?

  # Reads *data*, which starts at `position`.
  private abstract def scan(data : Bytes) : Nil

  private abstract def prune(before : Int64) : Nil
end
