const std = @import("std");
const builtin = @import("builtin");
const posix = @import("posix.zig");
const net = @import("net.zig");

const log = std.log.scoped(.zio_dns);

// DNS constants (getaddrinfo/getnameinfo flags)
const AI = struct {
    pub const PASSIVE: c_int = 0x0001;
    pub const CANONNAME: c_int = 0x0002;
    pub const NUMERICHOST: c_int = 0x0004;
    pub const NUMERICSERV: c_int = 0x0400;
    pub const V4MAPPED: c_int = 0x0008;
    pub const ALL: c_int = 0x0010;
    pub const ADDRCONFIG: c_int = 0x0020;
};

const NI = struct {
    pub const NUMERICHOST: c_int = 0x01;
    pub const NUMERICSERV: c_int = 0x02;
    pub const NAMEREQD: c_int = 0x04;
    pub const DGRAM: c_int = 0x10;
};

const EAI = struct {
    pub const ADDRFAMILY: c_int = -9;
    pub const AGAIN: c_int = -3;
    pub const BADFLAGS: c_int = -1;
    pub const FAIL: c_int = -4;
    pub const NODATA: c_int = -5;
    pub const NONAME: c_int = -2;
    pub const SERVICE: c_int = -8;
    pub const MEMORY: c_int = -10;
    pub const OVERFLOW: c_int = -12;
    pub const SYSTEM: c_int = -11;
};

pub const AddrInfoFlags = packed struct {
    passive: bool = false,
    canonname: bool = false,
    numerichost: bool = false,
    numericserv: bool = false,
    v4mapped: bool = false,
    all: bool = false,
    addrconfig: bool = false,
};

pub const NameInfoFlags = packed struct {
    numerichost: bool = false,
    numericserv: bool = false,
    namereqd: bool = false,
    dgram: bool = false,
};

pub const AddrInfo = struct {
    flags: AddrInfoFlags,
    family: net.Domain,
    socktype: net.Type,
    protocol: net.Protocol,
    addr: net.sockaddr,
    addr_len: net.socklen_t,
    canonname: ?[]const u8,
};

pub const NameInfo = struct {
    host_len: usize,
    service_len: usize,
};

pub const GetAddrInfoError = error{
    AddressFamilyNotSupported,
    TemporaryNameServerFailure,
    InvalidFlags,
    PermanentNameServerFailure,
    NameHasNoUsableAddress,
    UnknownHostName,
    ServiceNotAvailableForSocketType,
    SystemResources,
    Unexpected,
};

pub const GetNameInfoError = error{
    AddressFamilyNotSupported,
    InvalidFlags,
    NameTooLong,
    SystemResources,
    SystemFailure,
    Unexpected,
};

fn addrInfoFlagsToSystem(flags: AddrInfoFlags) c_int {
    var result: c_int = 0;
    if (flags.passive) result |= AI.PASSIVE;
    if (flags.canonname) result |= AI.CANONNAME;
    if (flags.numerichost) result |= AI.NUMERICHOST;
    if (flags.numericserv) result |= AI.NUMERICSERV;
    if (flags.v4mapped) result |= AI.V4MAPPED;
    if (flags.all) result |= AI.ALL;
    if (flags.addrconfig) result |= AI.ADDRCONFIG;
    return result;
}

fn nameInfoFlagsToSystem(flags: NameInfoFlags) c_int {
    var result: c_int = 0;
    if (flags.numerichost) result |= NI.NUMERICHOST;
    if (flags.numericserv) result |= NI.NUMERICSERV;
    if (flags.namereqd) result |= NI.NAMEREQD;
    if (flags.dgram) result |= NI.DGRAM;
    return result;
}

fn getAddrInfoErrorFromEAI(err: c_int) GetAddrInfoError {
    return switch (err) {
        EAI.ADDRFAMILY => error.AddressFamilyNotSupported,
        EAI.AGAIN => error.TemporaryNameServerFailure,
        EAI.BADFLAGS => error.InvalidFlags,
        EAI.FAIL => error.PermanentNameServerFailure,
        EAI.NODATA => error.NameHasNoUsableAddress,
        EAI.NONAME => error.UnknownHostName,
        EAI.SERVICE => error.ServiceNotAvailableForSocketType,
        EAI.MEMORY => error.SystemResources,
        else => {
            if (posix.unexpected_error_tracing) {
                std.debug.print(
                    \\unexpected getaddrinfo error: {}
                    \\please file a bug report: https://github.com/lalinsky/aio.zig/issues/new
                    \\
                , .{err});
                std.debug.dumpCurrentStackTrace(null);
            }
            return error.Unexpected;
        },
    };
}

fn getNameInfoErrorFromEAI(err: c_int) GetNameInfoError {
    return switch (err) {
        EAI.ADDRFAMILY => error.AddressFamilyNotSupported,
        EAI.BADFLAGS => error.InvalidFlags,
        EAI.OVERFLOW => error.NameTooLong,
        EAI.MEMORY => error.SystemResources,
        EAI.SYSTEM => error.SystemFailure,
        else => {
            if (posix.unexpected_error_tracing) {
                std.debug.print(
                    \\unexpected getnameinfo error: {}
                    \\please file a bug report: https://github.com/lalinsky/aio.zig/issues/new
                    \\
                , .{err});
                std.debug.dumpCurrentStackTrace(null);
            }
            return error.Unexpected;
        },
    };
}

/// Performs blocking getaddrinfo syscall, writing results to user-provided buffer.
/// Returns the number of results written.
/// If buffer is too small, returns error.SystemResources.
pub fn getaddrinfo(
    node: ?[]const u8,
    service: ?[]const u8,
    hints: ?AddrInfoFlags,
    domain: net.Domain,
    socktype: net.Type,
    protocol: net.Protocol,
    results: []AddrInfo,
) GetAddrInfoError!usize {
    net.ensureWSAInitialized();

    // Prepare null-terminated strings
    var node_buf: [256]u8 = undefined;
    var service_buf: [32]u8 = undefined;

    const node_z: ?[*:0]const u8 = if (node) |n| blk: {
        if (n.len >= node_buf.len) return error.SystemResources;
        @memcpy(node_buf[0..n.len], n);
        node_buf[n.len] = 0;
        break :blk @ptrCast(&node_buf);
    } else null;

    const service_z: ?[*:0]const u8 = if (service) |s| blk: {
        if (s.len >= service_buf.len) return error.SystemResources;
        @memcpy(service_buf[0..s.len], s);
        service_buf[s.len] = 0;
        break :blk @ptrCast(&service_buf);
    } else null;

    // Prepare hints structure
    const sys_hints: std.c.addrinfo = .{
        .flags = @bitCast(if (hints) |h| addrInfoFlagsToSystem(h) else 0),
        .family = @intFromEnum(domain),
        .socktype = @intFromEnum(socktype),
        .protocol = @intFromEnum(protocol),
        .addrlen = 0,
        .addr = null,
        .canonname = null,
        .next = null,
    };

    // Call getaddrinfo
    var res: ?*std.c.addrinfo = null;
    const rc = std.c.getaddrinfo(node_z, service_z, &sys_hints, &res);
    if (@intFromEnum(rc) != 0) {
        return getAddrInfoErrorFromEAI(@intFromEnum(rc));
    }
    defer if (res) |r| std.c.freeaddrinfo(r);

    // Copy results to user buffer
    var count: usize = 0;
    var current = res;
    while (current) |info| : (current = info.next) {
        if (count >= results.len) {
            return error.SystemResources; // Buffer too small
        }

        // Copy address
        var addr: net.sockaddr = undefined;
        var addr_len: net.socklen_t = @intCast(info.addrlen);
        if (addr_len > @sizeOf(net.sockaddr)) {
            addr_len = @sizeOf(net.sockaddr);
        }
        @memcpy(
            @as([*]u8, @ptrCast(&addr))[0..addr_len],
            @as([*]const u8, @ptrCast(info.addr))[0..addr_len],
        );

        results[count] = .{
            .flags = .{}, // Response doesn't include flags
            .family = @enumFromInt(info.family),
            .socktype = @enumFromInt(info.socktype),
            .protocol = @enumFromInt(info.protocol),
            .addr = addr,
            .addr_len = addr_len,
            .canonname = null, // TODO: handle canonname if needed
        };

        count += 1;
    }

    return count;
}

/// Performs blocking getnameinfo syscall, writing results to user-provided buffers.
/// Either host or service buffer can be null if only one is needed.
pub fn getnameinfo(
    addr: *const net.sockaddr,
    addr_len: net.socklen_t,
    host: ?[]u8,
    service: ?[]u8,
    flags: NameInfoFlags,
) GetNameInfoError!NameInfo {
    net.ensureWSAInitialized();

    const sys_flags = nameInfoFlagsToSystem(flags);

    const host_ptr: ?[*]u8 = if (host) |h| h.ptr else null;
    const host_len: net.socklen_t = if (host) |h| @intCast(h.len) else 0;

    const service_ptr: ?[*]u8 = if (service) |s| s.ptr else null;
    const service_len: net.socklen_t = if (service) |s| @intCast(s.len) else 0;

    const rc = std.c.getnameinfo(
        addr,
        addr_len,
        host_ptr,
        host_len,
        service_ptr,
        service_len,
        @bitCast(sys_flags),
    );

    if (@intFromEnum(rc) != 0) {
        return getNameInfoErrorFromEAI(@intFromEnum(rc));
    }

    // Calculate actual lengths (find null terminators)
    const actual_host_len: usize = if (host) |h| blk: {
        var len: usize = 0;
        while (len < h.len and h[len] != 0) : (len += 1) {}
        break :blk len;
    } else 0;

    const actual_service_len: usize = if (service) |s| blk: {
        var len: usize = 0;
        while (len < s.len and s[len] != 0) : (len += 1) {}
        break :blk len;
    } else 0;

    return .{
        .host_len = actual_host_len,
        .service_len = actual_service_len,
    };
}
