pub const c = @cImport({
    @cInclude("libavformat/avformat.h");
    @cInclude("libavcodec/avcodec.h");
    @cInclude("libswresample/swresample.h");
    @cInclude("libavutil/opt.h");
    @cInclude("libavutil/channel_layout.h");
    @cInclude("libavutil/audio_fifo.h");
    @cInclude("libavutil/avutil.h");
    @cInclude("libavutil/dict.h");
    @cInclude("libavutil/time.h");
    @cInclude("sqlite3.h");
    @cInclude("time.h");
    @cInclude("stdlib.h");
    @cInclude("ifaddrs.h");
    @cInclude("netinet/in.h");
    @cInclude("arpa/inet.h");
    @cInclude("net/if.h");
});
