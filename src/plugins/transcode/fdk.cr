# The Fraunhofer FDK AAC library, used for AAC when the operator has installed it. Lurcast doesn't
# ship it or link it: it is opened at run time, so a server without it simply can't transcode AAC.
# FDK's license grants no patent rights, so whoever installs it decides whether they may use it.
lib LibFDK
  # aacenc_lib.h: AACENC_BufDesc, AACENC_InArgs and AACENC_OutArgs.
  struct BufDesc
    num_bufs : Int32
    bufs : Void**
    buffer_identifiers : Int32*
    buf_sizes : Int32*
    buf_el_sizes : Int32*
  end

  struct InArgs
    num_in_samples : Int32
    num_anc_bytes : Int32
  end

  struct OutArgs
    num_out_bytes : Int32
    num_in_samples : Int32
    num_anc_bytes : Int32
    bit_res_state : Int32
  end

  # The leading fields of AACENC_InfoStruct.
  struct EncoderInfo
    max_out_buf_bytes : UInt32
    max_anc_bytes : UInt32
    in_buf_fill_level : UInt32
    input_channels : UInt32
    frame_length : UInt32
    n_delay : UInt32
    n_delay_core : UInt32
    conf_buf : StaticArray(UInt8, 64)
    conf_size : UInt32
  end

  # The leading fields of aacdecoder_lib.h's CStreamInfo, which stay first in every version.
  struct StreamInfo
    sample_rate : Int32
    frame_size : Int32
    num_channels : Int32
  end
end

class Lurcast::Plugins::Transcode < Lurcast::Plugin
  module FDK
    # Where to look: the library name (found in the release's lib/ folder and the system's library
    # paths), then the usual Homebrew locations on macOS.
    NAMES = {"libfdk-aac.so.2", "libfdk-aac.so", "libfdk-aac.2.dylib",
             "/opt/homebrew/lib/libfdk-aac.2.dylib", "/usr/local/lib/libfdk-aac.2.dylib"}

    # aacenc_lib.h
    AOT         = 0x0100_u32
    BITRATE     = 0x0101_u32
    SAMPLERATE  = 0x0103_u32
    CHANNELMODE = 0x0106_u32
    AFTERBURNER = 0x0200_u32
    TRANSMUX    = 0x0300_u32
    ADTS        =      2_u32
    IN_AUDIO    =          0
    OUT_STREAM  =          3
    # aacdecoder_lib.h and FDK_audio.h
    TT_MP4_ADTS     =  2_u32
    TT_MP4_LOAS     = 10_u32
    NOT_ENOUGH_BITS = 0x1002

    # The functions Lurcast calls, looked up in the opened library.
    class Library
      getter enc_open : Proc(Void**, UInt32, UInt32, Int32)
      getter enc_close : Proc(Void**, Int32)
      getter enc_encode : Proc(Void*, LibFDK::BufDesc*, LibFDK::BufDesc*, LibFDK::InArgs*, LibFDK::OutArgs*, Int32)
      getter enc_info : Proc(Void*, LibFDK::EncoderInfo*, Int32)
      getter enc_set_param : Proc(Void*, UInt32, UInt32, Int32)
      getter dec_open : Proc(UInt32, UInt32, Void*)
      getter dec_fill : Proc(Void*, UInt8**, UInt32*, UInt32*, Int32)
      getter dec_decode : Proc(Void*, Int16*, Int32, UInt32, Int32)
      getter dec_info : Proc(Void*, LibFDK::StreamInfo*)
      getter dec_close : Proc(Void*, Nil)
      getter path : String

      def initialize(@path : String, handle : Void*)
        @enc_open = Proc(Void**, UInt32, UInt32, Int32).new(symbol(handle, "aacEncOpen"), Pointer(Void).null)
        @enc_close = Proc(Void**, Int32).new(symbol(handle, "aacEncClose"), Pointer(Void).null)
        @enc_encode = Proc(Void*, LibFDK::BufDesc*, LibFDK::BufDesc*, LibFDK::InArgs*, LibFDK::OutArgs*, Int32).new(symbol(handle, "aacEncEncode"), Pointer(Void).null)
        @enc_info = Proc(Void*, LibFDK::EncoderInfo*, Int32).new(symbol(handle, "aacEncInfo"), Pointer(Void).null)
        @enc_set_param = Proc(Void*, UInt32, UInt32, Int32).new(symbol(handle, "aacEncoder_SetParam"), Pointer(Void).null)
        @dec_open = Proc(UInt32, UInt32, Void*).new(symbol(handle, "aacDecoder_Open"), Pointer(Void).null)
        @dec_fill = Proc(Void*, UInt8**, UInt32*, UInt32*, Int32).new(symbol(handle, "aacDecoder_Fill"), Pointer(Void).null)
        @dec_decode = Proc(Void*, Int16*, Int32, UInt32, Int32).new(symbol(handle, "aacDecoder_DecodeFrame"), Pointer(Void).null)
        @dec_info = Proc(Void*, LibFDK::StreamInfo*).new(symbol(handle, "aacDecoder_GetStreamInfo"), Pointer(Void).null)
        @dec_close = Proc(Void*, Nil).new(symbol(handle, "aacDecoder_Close"), Pointer(Void).null)
      end

      private def symbol(handle : Void*, name : String) : Void*
        pointer = LibC.dlsym(handle, name)
        raise ArgumentError.new("#{@path} has no #{name}") if pointer.null?
        pointer
      end
    end

    @@mutex = Mutex.new
    @@loaded = false
    @@library : Library?
    @@error : String?

    # The library, opened the first time it is asked for; nil when it isn't installed.
    def self.library : Library?
      @@mutex.synchronize do
        unless @@loaded
          @@loaded = true
          load
        end
        @@library
      end
    end

    def self.available? : Bool
      !library.nil?
    end

    # Why the library couldn't be used, for messages.
    def self.error : String
      library
      @@error || "it isn't installed"
    end

    private def self.load : Nil
      errors = [] of String
      NAMES.each do |name|
        handle = LibC.dlopen(name, LibC::RTLD_NOW | LibC::RTLD_LOCAL)
        if handle.null?
          message = LibC.dlerror
          errors << String.new(message) unless message.null?
          next
        end
        begin
          @@library = Library.new(name, handle)
          Log.info { "AAC transcoding uses the Fraunhofer FDK AAC library (#{name})" }
          return
        rescue ex : ArgumentError
          errors << (ex.message || name)
          LibC.dlclose(handle)
        end
      end
      # Most attempts fail because the file isn't there; report the one that found a file, if any.
      found = errors.find { |message| !message.downcase.includes?("no such file") && !message.downcase.includes?("not found") }
      @@error = found ? "libfdk-aac could not be loaded: #{found}" : "libfdk-aac isn't installed"
    end
  end

  # AAC in ADTS or LATM frames, including HE-AAC (v1 and v2), with FDK; the first frame says which.
  class AACDecoder < Decoder
    MAX_OUTPUT = 2048 * 8 # samples per channel in an HE-AAC frame, times eight channels

    @handle : Void*?
    @pending = ByteQueue.new(1 << 20)
    @pcm = Slice(Int16).new(MAX_OUTPUT)
    @float = Slice(Float32).new(MAX_OUTPUT)

    def initialize(@fdk : FDK::Library)
    end

    def decode(data : Bytes, & : Slice(Float32), Int32, Int32 ->) : Nil
      @pending.append(data)
      loop do
        input = @pending.bytes
        break if input.size < AAC::SYNC_PROBE_SIZE
        frame = AAC.parse_header(input)
        unless frame
          # Not on a frame boundary: skip to the next one.
          located = AAC.find_frame(input) || break
          @pending.consume(located.offset.positive? ? located.offset : 1)
          next
        end
        break if input.size < frame.frame_size
        handle = @handle ||= open(frame.transport)
        buffer = input.to_unsafe
        size = frame.frame_size.to_u32
        valid = size
        @fdk.dec_fill.call(handle, pointerof(buffer), pointerof(size), pointerof(valid))
        @pending.consume(frame.frame_size)
        loop do
          # A damaged frame is skipped, as players do.
          break unless @fdk.dec_decode.call(handle, @pcm.to_unsafe, @pcm.size, 0_u32).zero?
          info = @fdk.dec_info.call(handle)
          break if info.null?
          channels = info.value.num_channels
          count = info.value.frame_size * channels
          break unless channels.positive? && 0 < count <= @pcm.size
          count.times { |index| @float[index] = @pcm[index] / 32768_f32 }
          yield @float[0, count], channels, info.value.sample_rate
        end
      end
    end

    def close : Nil
      @handle.try { |handle| @fdk.dec_close.call(handle) }
      @handle = nil
    end

    def finalize
      close
    end

    private def open(transport : AAC::Transport) : Void*
      handle = @fdk.dec_open.call(transport.loas? ? FDK::TT_MP4_LOAS : FDK::TT_MP4_ADTS, 1_u32)
      raise UnsupportedInput.new("AAC the FDK decoder can't open") if handle.null?
      handle
    end
  end

  # AAC in ADTS frames with FDK, at 44.1 kHz: AAC-LC, HE-AAC (AAC+), or HE-AAC v2 (stereo only).
  class AACEncoder < Encoder
    RATE     = 44_100
    PROFILES = {"lc" => 2_u32, "he" => 5_u32, "hev2" => 29_u32}

    @handle : Void*
    @input : Slice(Int16)
    @output : Bytes

    def initialize(bitrate_kbps : Int32, channels : Int32, profile : String, @fdk : FDK::Library)
      handle = Pointer(Void).null
      raise ArgumentError.new("the FDK AAC encoder could not start") unless fdk.enc_open.call(pointerof(handle), 0_u32, channels.to_u32).zero?
      unless fdk.enc_set_param.call(handle, FDK::AOT, PROFILES[profile]? || 2_u32).zero?
        fdk.enc_close.call(pointerof(handle))
        # Some distributions (Alpine, Fedora) ship FDK without HE-AAC.
        raise ArgumentError.new("this build of libfdk-aac has no #{profile == "hev2" ? "HE-AAC v2" : profile == "he" ? "HE-AAC" : profile.upcase}; install one with it, or use profile lc")
      end
      settings = {FDK::SAMPLERATE => RATE.to_u32, FDK::CHANNELMODE => channels.to_u32,
                  FDK::BITRATE => (bitrate_kbps * 1000).to_u32, FDK::TRANSMUX => FDK::ADTS, FDK::AFTERBURNER => 1_u32}
      info = LibFDK::EncoderInfo.new
      configured = settings.all? { |param, value| fdk.enc_set_param.call(handle, param, value).zero? } &&
                   fdk.enc_encode.call(handle, Pointer(LibFDK::BufDesc).null, Pointer(LibFDK::BufDesc).null, Pointer(LibFDK::InArgs).null, Pointer(LibFDK::OutArgs).null).zero? &&
                   fdk.enc_info.call(handle, pointerof(info)).zero?
      unless configured
        fdk.enc_close.call(pointerof(handle))
        raise ArgumentError.new("the FDK AAC encoder rejects #{profile.upcase} at #{bitrate_kbps} kbps with #{channels} channel(s)")
      end
      @handle = handle
      frame = info.frame_length.to_i
      @input = Slice(Int16).new(frame * channels)
      @output = Bytes.new(Math.max(info.max_out_buf_bytes.to_i, 8192))
      super(channels, RATE, frame)
    end

    def content_type : String
      "audio/aac"
    end

    def writer(io : IO) : StreamWriter
      RawWriter.new(io)
    end

    private def encode_frame(frame : Slice(Float32), & : Bytes ->) : Nil
      frame.each_with_index { |sample, index| @input[index] = (sample.clamp(-1_f32, 1_f32) * 32767).round.to_i16 }
      in_buf = @input.to_unsafe.as(Void*)
      in_id = FDK::IN_AUDIO
      in_size = @input.size * 2
      in_el = 2
      out_buf = @output.to_unsafe.as(Void*)
      out_id = FDK::OUT_STREAM
      out_size = @output.size
      out_el = 1
      in_desc = LibFDK::BufDesc.new(num_bufs: 1, bufs: pointerof(in_buf), buffer_identifiers: pointerof(in_id), buf_sizes: pointerof(in_size), buf_el_sizes: pointerof(in_el))
      out_desc = LibFDK::BufDesc.new(num_bufs: 1, bufs: pointerof(out_buf), buffer_identifiers: pointerof(out_id), buf_sizes: pointerof(out_size), buf_el_sizes: pointerof(out_el))
      in_args = LibFDK::InArgs.new(num_in_samples: @input.size, num_anc_bytes: 0)
      out_args = LibFDK::OutArgs.new
      error = @fdk.enc_encode.call(@handle, pointerof(in_desc), pointerof(out_desc), pointerof(in_args), pointerof(out_args))
      raise IO::Error.new("AAC encoding failed (FDK error 0x#{error.to_s(16)})") unless error.zero?
      yield @output[0, out_args.num_out_bytes] if out_args.num_out_bytes.positive?
    end

    private def close_codec : Nil
      handle = @handle
      @fdk.enc_close.call(pointerof(handle))
    end
  end
end
