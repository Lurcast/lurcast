# Bindings for the audio libraries the transcode plugin uses: libopus and LAME (MP3 encoding) from
# the system, and the vendored decoders and resampler in `ext/`, which `ext/build.sh` compiles into
# a static archive while Crystal compiles this file.

@[Link("opus", pkg_config: "opus")]
lib LibOpus
  APPLICATION_AUDIO   = 2049
  OK                  =    0
  SET_BITRATE_REQUEST = 4002
  GET_BITRATE_REQUEST = 4003
  GET_LOOKAHEAD       = 4027

  type Encoder = Void*
  type Decoder = Void*

  fun encoder_create = opus_encoder_create(rate : Int32, channels : Int32, application : Int32, error : Int32*) : Encoder
  fun encode_float = opus_encode_float(encoder : Encoder, pcm : Float32*, frame_size : Int32, data : UInt8*, max_data_bytes : Int32) : Int32
  fun encoder_ctl = opus_encoder_ctl(encoder : Encoder, request : Int32, ...) : Int32
  fun encoder_destroy = opus_encoder_destroy(encoder : Encoder) : Void

  fun decoder_create = opus_decoder_create(rate : Int32, channels : Int32, error : Int32*) : Decoder
  fun decode_float = opus_decode_float(decoder : Decoder, data : UInt8*, length : Int32, pcm : Float32*, frame_size : Int32, decode_fec : Int32) : Int32
  fun decoder_destroy = opus_decoder_destroy(decoder : Decoder) : Void

  fun strerror = opus_strerror(error : Int32) : UInt8*
  fun get_version_string = opus_get_version_string : UInt8*
end

{% begin %}
  @[Link(ldflags: {{ system("sh \"" + __DIR__ + "/../../../ext/build.sh\"").stringify }})]
  @[Link("m")]
  lib LibLurcastExt
    MP3_MAX_SAMPLES_PER_FRAME = 1152 * 2
    VORBIS_NEED_MORE_DATA     =        1

    # minimp3's `mp3dec_t`.
    struct MP3Decoder
      mdct_overlap : StaticArray(Float32, 576)
      qmf_state : StaticArray(Float32, 960)
      reserv : Int32
      free_format_bytes : Int32
      header : StaticArray(UInt8, 4)
      reserv_buf : StaticArray(UInt8, 511)
    end

    struct MP3FrameInfo
      frame_bytes : Int32
      frame_offset : Int32
      channels : Int32
      hz : Int32
      layer : Int32
      bitrate_kbps : Int32
    end

    fun mp3dec_init(decoder : MP3Decoder*) : Void
    fun mp3dec_decode_frame(decoder : MP3Decoder*, mp3 : UInt8*, mp3_bytes : Int32, pcm : Float32*, info : MP3FrameInfo*) : Int32

    type Vorbis = Void*

    struct VorbisInfo
      sample_rate : UInt32
      channels : Int32
      setup_memory_required : UInt32
      setup_temp_memory_required : UInt32
      temp_memory_required : UInt32
      max_frame_size : Int32
    end

    fun stb_vorbis_open_pushdata(data : UInt8*, length : Int32, consumed : Int32*, error : Int32*, alloc : Void*) : Vorbis
    fun stb_vorbis_decode_frame_pushdata(vorbis : Vorbis, data : UInt8*, length : Int32, channels : Int32*, output : Float32***, samples : Int32*) : Int32
    fun stb_vorbis_get_info(vorbis : Vorbis) : VorbisInfo
    fun stb_vorbis_close(vorbis : Vorbis) : Void

    type Resampler = Void*

    fun resampler_init = lurcast_resampler_init(channels : UInt32, in_rate : UInt32, out_rate : UInt32, quality : Int32, error : Int32*) : Resampler
    fun resampler_process_interleaved_float = lurcast_resampler_process_interleaved_float(resampler : Resampler, input : Float32*, in_length : UInt32*, output : Float32*, out_length : UInt32*) : Int32
    fun resampler_destroy = lurcast_resampler_destroy(resampler : Resampler) : Void
  end
{% end %}

# LAME, the MP3 encoder (LGPL 2 or later).
@[Link("mp3lame", pkg_config: "lame")]
lib LibLame
  MONO         = 3
  JOINT_STEREO = 1

  type Flags = Void*

  fun init = lame_init : Flags
  fun set_in_samplerate = lame_set_in_samplerate(flags : Flags, rate : Int32) : Int32
  fun set_out_samplerate = lame_set_out_samplerate(flags : Flags, rate : Int32) : Int32
  fun set_num_channels = lame_set_num_channels(flags : Flags, channels : Int32) : Int32
  fun set_brate = lame_set_brate(flags : Flags, kbps : Int32) : Int32
  fun set_mode = lame_set_mode(flags : Flags, mode : Int32) : Int32
  fun set_write_vbr_tag = lame_set_bWriteVbrTag(flags : Flags, write : Int32) : Int32
  fun init_params = lame_init_params(flags : Flags) : Int32
  fun get_out_samplerate = lame_get_out_samplerate(flags : Flags) : Int32
  fun encode_buffer_ieee_float = lame_encode_buffer_ieee_float(flags : Flags, left : Float32*, right : Float32*, samples : Int32, output : UInt8*, size : Int32) : Int32
  fun close = lame_close(flags : Flags) : Int32
  fun get_lame_version : UInt8*
end
