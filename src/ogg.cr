@[Link("ogg", pkg_config: "ogg")]
lib LibOgg
  struct SyncState
    data : UInt8*
    storage : Int32
    fill : Int32
    returned : Int32
    unsynced : Int32
    headerbytes : Int32
    bodybytes : Int32
  end

  struct Page
    header : UInt8*
    header_len : LibC::Long
    body : UInt8*
    body_len : LibC::Long
  end

  fun sync_init = ogg_sync_init(state : SyncState*) : Int32
  fun sync_clear = ogg_sync_clear(state : SyncState*) : Int32
  fun sync_buffer = ogg_sync_buffer(state : SyncState*, size : LibC::Long) : UInt8*
  fun sync_wrote = ogg_sync_wrote(state : SyncState*, bytes : LibC::Long) : Int32
  fun sync_pageseek = ogg_sync_pageseek(state : SyncState*, page : Page*) : LibC::Long
end

module Ogg
  class Sync
    @state : LibOgg::SyncState
    @offset = 0_i64
    @closed = true

    def initialize
      @state = uninitialized LibOgg::SyncState
      raise IO::Error.new("could not initialize libogg") unless LibOgg.sync_init(pointerof(@state)).zero?
      @closed = false
    end

    # The yielded slices remain valid only until the block returns.
    def each_page(data : Bytes, & : Int64, Bytes, Bytes ->)
      raise IO::Error.new("libogg synchronizer is closed") if @closed
      return if data.empty?

      buffer = LibOgg.sync_buffer(pointerof(@state), LibC::Long.new(data.size))
      raise IO::Error.new("libogg could not allocate its input buffer") if buffer.null?

      data.copy_to(buffer.to_slice(data.size))
      raise IO::Error.new("libogg rejected its input buffer") unless LibOgg.sync_wrote(pointerof(@state), LibC::Long.new(data.size)).zero?

      page = uninitialized LibOgg::Page
      loop do
        consumed = LibOgg.sync_pageseek(pointerof(@state), pointerof(page)).to_i64
        if consumed.positive?
          offset = @offset
          @offset += consumed
          yield offset, page.header.to_slice(page.header_len.to_i), page.body.to_slice(page.body_len.to_i)
        elsif consumed.negative?
          @offset -= consumed
        else
          break
        end
      end
    end

    def close
      return if @closed

      LibOgg.sync_clear(pointerof(@state))
      @closed = true
    end

    def finalize
      close
    end
  end
end
