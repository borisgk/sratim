pub const c = @cImport({
    @cInclude("sqlite3.h");
    @cInclude("time.h");
    @cInclude("stdlib.h");
    @cInclude("ifaddrs.h");
    @cInclude("netinet/in.h");
    @cInclude("arpa/inet.h");
    @cInclude("net/if.h");
});
