pub const c = @cImport({
    @cInclude("time.h");
    @cInclude("stdlib.h");
    @cInclude("ifaddrs.h");
    @cInclude("netinet/in.h");
    @cInclude("arpa/inet.h");
    @cInclude("net/if.h");
});
