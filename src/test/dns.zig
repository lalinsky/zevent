const std = @import("std");
const Loop = @import("../loop.zig").Loop;
const ThreadPool = @import("../thread_pool.zig").ThreadPool;
const NetGetAddrInfo = @import("../completion.zig").NetGetAddrInfo;
const NetGetNameInfo = @import("../completion.zig").NetGetNameInfo;
const dns = @import("../os/dns.zig");
const net = @import("../os/net.zig");

test "DNS: getaddrinfo localhost" {
    var thread_pool: ThreadPool = undefined;
    try thread_pool.init(std.testing.allocator, .{ .min_threads = 1, .max_threads = 4 });
    defer thread_pool.deinit();

    var loop: Loop = undefined;
    try loop.init(.{ .allocator = std.testing.allocator, .thread_pool = &thread_pool });
    defer loop.deinit();

    var results: [8]dns.AddrInfo = undefined;
    var getaddrinfo_op = NetGetAddrInfo.init(
        "localhost",
        null,
        .{},
        .ipv4,
        .stream,
        .tcp,
        &results,
    );

    loop.add(&getaddrinfo_op.c);
    try loop.run(.until_done);

    try std.testing.expectEqual(.completed, getaddrinfo_op.c.state);
    try std.testing.expectEqual(true, getaddrinfo_op.c.has_result);

    const count = try getaddrinfo_op.getResult();
    try std.testing.expect(count > 0);
    try std.testing.expect(count <= results.len);
}

test "DNS: getaddrinfo with service" {
    var thread_pool: ThreadPool = undefined;
    try thread_pool.init(std.testing.allocator, .{ .min_threads = 1, .max_threads = 4 });
    defer thread_pool.deinit();

    var loop: Loop = undefined;
    try loop.init(.{ .allocator = std.testing.allocator, .thread_pool = &thread_pool });
    defer loop.deinit();

    var results: [8]dns.AddrInfo = undefined;
    var getaddrinfo_op = NetGetAddrInfo.init(
        "localhost",
        "80",
        .{},
        .ipv4,
        .stream,
        .tcp,
        &results,
    );

    loop.add(&getaddrinfo_op.c);
    try loop.run(.until_done);

    try std.testing.expectEqual(.completed, getaddrinfo_op.c.state);
    const count = try getaddrinfo_op.getResult();
    try std.testing.expect(count > 0);

    // Verify port is set to 80
    const addr_in: *const std.posix.sockaddr.in = @ptrCast(@alignCast(&results[0].addr));
    try std.testing.expectEqual(@as(u16, 80), std.mem.bigToNative(u16, addr_in.port));
}

test "DNS: getnameinfo for localhost" {
    var thread_pool: ThreadPool = undefined;
    try thread_pool.init(std.testing.allocator, .{ .min_threads = 1, .max_threads = 4 });
    defer thread_pool.deinit();

    var loop: Loop = undefined;
    try loop.init(.{ .allocator = std.testing.allocator, .thread_pool = &thread_pool });
    defer loop.deinit();

    // First resolve localhost to get an address
    var results: [8]dns.AddrInfo = undefined;
    var getaddrinfo_op = NetGetAddrInfo.init(
        "localhost",
        "80",
        .{},
        .ipv4,
        .stream,
        .tcp,
        &results,
    );

    loop.add(&getaddrinfo_op.c);
    try loop.run(.until_done);
    const count = try getaddrinfo_op.getResult();
    try std.testing.expect(count > 0);

    // Now reverse lookup
    var host_buf: [256]u8 = undefined;
    var service_buf: [32]u8 = undefined;
    var getnameinfo_op = NetGetNameInfo.init(
        &results[0].addr,
        results[0].addr_len,
        &host_buf,
        &service_buf,
        .{},
    );

    loop.add(&getnameinfo_op.c);
    try loop.run(.until_done);

    try std.testing.expectEqual(.completed, getnameinfo_op.c.state);
    const result = try getnameinfo_op.getResult();
    try std.testing.expect(result.host_len > 0);
    try std.testing.expect(result.service_len > 0);

    // Should get "80" or "http" as the service
    const service = service_buf[0..result.service_len];
    try std.testing.expect(std.mem.eql(u8, service, "80") or std.mem.eql(u8, service, "http"));
}

test "DNS: getnameinfo numeric" {
    var thread_pool: ThreadPool = undefined;
    try thread_pool.init(std.testing.allocator, .{ .min_threads = 1, .max_threads = 4 });
    defer thread_pool.deinit();

    var loop: Loop = undefined;
    try loop.init(.{ .allocator = std.testing.allocator, .thread_pool = &thread_pool });
    defer loop.deinit();

    // Create a known address: 127.0.0.1:8080
    const addr: net.sockaddr = @bitCast(std.posix.sockaddr.in{
        .family = net.AF.INET,
        .port = std.mem.nativeToBig(u16, 8080),
        .addr = 0x0100007F, // 127.0.0.1 in network byte order
        .zero = [_]u8{0} ** 8,
    });

    var host_buf: [256]u8 = undefined;
    var service_buf: [32]u8 = undefined;
    var getnameinfo_op = NetGetNameInfo.init(
        &addr,
        @sizeOf(std.posix.sockaddr.in),
        &host_buf,
        &service_buf,
        .{ .numerichost = true, .numericserv = true },
    );

    loop.add(&getnameinfo_op.c);
    try loop.run(.until_done);

    try std.testing.expectEqual(.completed, getnameinfo_op.c.state);
    const result = try getnameinfo_op.getResult();

    const host = host_buf[0..result.host_len];
    const service = service_buf[0..result.service_len];

    try std.testing.expectEqualStrings("127.0.0.1", host);
    try std.testing.expectEqualStrings("8080", service);
}

test "DNS: getaddrinfo invalid hostname" {
    var thread_pool: ThreadPool = undefined;
    try thread_pool.init(std.testing.allocator, .{ .min_threads = 1, .max_threads = 4 });
    defer thread_pool.deinit();

    var loop: Loop = undefined;
    try loop.init(.{ .allocator = std.testing.allocator, .thread_pool = &thread_pool });
    defer loop.deinit();

    var results: [8]dns.AddrInfo = undefined;
    var getaddrinfo_op = NetGetAddrInfo.init(
        "this-hostname-does-not-exist-12345.invalid",
        null,
        .{},
        .ipv4,
        .stream,
        .tcp,
        &results,
    );

    loop.add(&getaddrinfo_op.c);
    try loop.run(.until_done);

    try std.testing.expectEqual(.completed, getaddrinfo_op.c.state);
    try std.testing.expectError(error.UnknownHostName, getaddrinfo_op.getResult());
}

test "DNS: no thread pool" {
    var loop: Loop = undefined;
    try loop.init(.{ .allocator = std.testing.allocator, .thread_pool = null });
    defer loop.deinit();

    var results: [8]dns.AddrInfo = undefined;
    var getaddrinfo_op = NetGetAddrInfo.init(
        "localhost",
        null,
        .{},
        .ipv4,
        .stream,
        .tcp,
        &results,
    );

    loop.add(&getaddrinfo_op.c);
    try loop.run(.until_done);

    try std.testing.expectEqual(.completed, getaddrinfo_op.c.state);
    try std.testing.expectError(error.NoThreadPool, getaddrinfo_op.getResult());
}
