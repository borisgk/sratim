const std = @import("std");

pub const c = struct {
    pub const ifaddrs = extern struct {
        ifa_next: ?*ifaddrs,
        ifa_name: [*:0]const u8,
        ifa_flags: c_uint,
        ifa_addr: ?*std.c.sockaddr,
        ifa_netmask: ?*std.c.sockaddr,
        ifa_dstaddr: ?*std.c.sockaddr,
        ifa_data: ?*anyopaque,
    };

    pub extern "c" fn getifaddrs(ifap: *?*ifaddrs) c_int;
    pub extern "c" fn freeifaddrs(ifa: ?*ifaddrs) void;

    pub const getenv = std.c.getenv;

    pub const AF_INET = std.posix.AF.INET;
    pub const IFF_UP = 0x1;
    pub const IFF_LOOPBACK = 0x8;
    pub const sockaddr_in = std.c.sockaddr.in;
};
