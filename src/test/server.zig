const std = @import("std");
const Loop = @import("../loop.zig").Loop;
const Backend = @import("../backend.zig").Backend;
const Completion = @import("../completion.zig").Completion;
const NetOpen = @import("../completion.zig").NetOpen;
const NetBind = @import("../completion.zig").NetBind;
const NetListen = @import("../completion.zig").NetListen;
const NetAccept = @import("../completion.zig").NetAccept;
const NetConnect = @import("../completion.zig").NetConnect;
const NetRecv = @import("../completion.zig").NetRecv;
const NetSend = @import("../completion.zig").NetSend;
const NetClose = @import("../completion.zig").NetClose;
const socket = @import("../os/posix/socket.zig");

pub fn EchoServer(comptime domain: socket.Domain, comptime sockaddr: type) type {
    return struct {
        state: State = .init,
        loop: *Loop,

        // Server socket
        server_sock: Backend.NetHandle = undefined,
        server_addr: sockaddr,
        bound_port: u16 = 0,

        // Client socket
        client_sock: ?Backend.NetHandle = null,

        // Union of completions - only one active at a time
        comp: union(enum) {
            none: void,
            open: NetOpen,
            bind: NetBind,
            listen: NetListen,
            accept: NetAccept,
            recv: NetRecv,
            send: NetSend,
            close_client: NetClose,
            close_server: NetClose,
        },

        // Buffer for echo
        recv_buf: [1024]u8 = undefined,
        recv_iov: [1]socket.iovec = undefined,
        send_iov: [1]socket.iovec_const = undefined,
        bytes_received: usize = 0,

        pub const State = enum {
            init,
            opening,
            binding,
            listening,
            accepting,
            receiving,
            sending,
            closing_client,
            closing_server,
            done,
            failed,
        };

        const Self = @This();

        pub fn init(loop: *Loop) Self {
            var self: Self = .{
                .loop = loop,
                .server_addr = undefined,
                .comp = .{ .none = {} },
            };

            switch (domain) {
                .ipv4 => {
                    self.server_addr = .{
                        .family = socket.AF.INET,
                        .addr = @bitCast([4]u8{ 127, 0, 0, 1 }),
                        .port = 0,
                        .zero = [_]u8{0} ** 8,
                    };
                },
                .ipv6 => {
                    self.server_addr = .{
                        .family = socket.AF.INET6,
                        .addr = [_]u8{0} ** 15 ++ [_]u8{1},
                        .port = 0,
                        .flowinfo = 0,
                        .scope_id = 0,
                    };
                },
                .unix => {
                    self.server_addr = .{
                        .family = socket.AF.UNIX,
                        .path = undefined,
                    };
                    const pid = std.os.linux.getpid();
                    const timestamp = std.time.timestamp();
                    _ = std.fmt.bufPrintZ(&self.server_addr.path, "/tmp/zevent-test-{d}-{d}.sock", .{ pid, timestamp }) catch unreachable;
                },
            }

            return self;
        }

        pub fn start(self: *Self) void {
            self.state = .opening;
            const protocol: socket.Protocol = if (domain == .unix) .default else .tcp;
            self.comp = .{ .open = NetOpen.init(domain, .stream, protocol) };
            self.comp.open.c.callback = openCallback;
            self.comp.open.c.userdata = self;
            self.loop.add(&self.comp.open.c);
        }

        fn openCallback(loop: *Loop, c: *Completion) void {
            const self: *Self = @ptrCast(@alignCast(c.userdata.?));

            self.server_sock = self.comp.open.c.getResult(.net_open) catch {
                self.state = .failed;
                loop.stop();
                return;
            };

            // Start bind
            self.state = .binding;
            self.comp = .{ .bind = NetBind.init(
                self.server_sock,
                @ptrCast(&self.server_addr),
                @sizeOf(sockaddr),
            ) };
            self.comp.bind.c.callback = bindCallback;
            self.comp.bind.c.userdata = self;
            loop.add(&self.comp.bind.c);
        }

        fn bindCallback(loop: *Loop, c: *Completion) void {
            const self: *Self = @ptrCast(@alignCast(c.userdata.?));

            self.comp.bind.c.getResult(.net_bind) catch {
                self.state = .failed;
                loop.stop();
                return;
            };

            // Get the actual bound port/path
            switch (domain) {
                .ipv4 => {
                    var bound_addr: socket.sockaddr.in = undefined;
                    var bound_addr_len: socket.socklen_t = @sizeOf(@TypeOf(bound_addr));
                    socket.getsockname(self.server_sock, @ptrCast(&bound_addr), &bound_addr_len) catch {
                        self.state = .failed;
                        loop.stop();
                        return;
                    };
                    self.bound_port = std.mem.bigToNative(u16, bound_addr.port);
                },
                .ipv6 => {
                    var bound_addr: socket.sockaddr.in6 = undefined;
                    var bound_addr_len: socket.socklen_t = @sizeOf(@TypeOf(bound_addr));
                    socket.getsockname(self.server_sock, @ptrCast(&bound_addr), &bound_addr_len) catch {
                        self.state = .failed;
                        loop.stop();
                        return;
                    };
                    self.bound_port = std.mem.bigToNative(u16, bound_addr.port);
                },
                .unix => {
                    // Unix sockets don't have ports
                },
            }

            // Start listen
            self.state = .listening;
            self.comp = .{ .listen = NetListen.init(self.server_sock, 1) };
            self.comp.listen.c.callback = listenCallback;
            self.comp.listen.c.userdata = self;
            loop.add(&self.comp.listen.c);
        }

        fn listenCallback(loop: *Loop, c: *Completion) void {
            const self: *Self = @ptrCast(@alignCast(c.userdata.?));

            self.comp.listen.c.getResult(.net_listen) catch {
                self.state = .failed;
                loop.stop();
                return;
            };

            // Start accept
            self.state = .accepting;
            self.comp = .{ .accept = NetAccept.init(self.server_sock, null, null) };
            self.comp.accept.c.callback = acceptCallback;
            self.comp.accept.c.userdata = self;
            loop.add(&self.comp.accept.c);
        }

        fn acceptCallback(loop: *Loop, c: *Completion) void {
            const self: *Self = @ptrCast(@alignCast(c.userdata.?));

            self.client_sock = self.comp.accept.getResult() catch {
                self.state = .failed;
                loop.stop();
                return;
            };

            // Start recv
            self.state = .receiving;
            self.recv_iov = [_]socket.iovec{socket.iovecFromSlice(&self.recv_buf)};
            self.comp = .{ .recv = NetRecv.init(self.client_sock.?, &self.recv_iov, .{}) };
            self.comp.recv.c.callback = recvCallback;
            self.comp.recv.c.userdata = self;
            loop.add(&self.comp.recv.c);
        }

        fn recvCallback(loop: *Loop, c: *Completion) void {
            const self: *Self = @ptrCast(@alignCast(c.userdata.?));

            self.bytes_received = self.comp.recv.getResult() catch {
                self.state = .failed;
                loop.stop();
                return;
            };

            // Echo back
            self.state = .sending;
            const send_buf = self.recv_buf[0..self.bytes_received];
            self.send_iov = [_]socket.iovec_const{socket.iovecConstFromSlice(send_buf)};
            self.comp = .{ .send = NetSend.init(self.client_sock.?, &self.send_iov, .{}) };
            self.comp.send.c.callback = sendCallback;
            self.comp.send.c.userdata = self;
            loop.add(&self.comp.send.c);
        }

        fn sendCallback(loop: *Loop, c: *Completion) void {
            const self: *Self = @ptrCast(@alignCast(c.userdata.?));

            _ = self.comp.send.getResult() catch {
                self.state = .failed;
                loop.stop();
                return;
            };

            // Close client socket
            self.state = .closing_client;
            self.comp = .{ .close_client = NetClose.init(self.client_sock.?) };
            self.comp.close_client.c.callback = closeClientCallback;
            self.comp.close_client.c.userdata = self;
            loop.add(&self.comp.close_client.c);
        }

        fn closeClientCallback(loop: *Loop, c: *Completion) void {
            const self: *Self = @ptrCast(@alignCast(c.userdata.?));

            self.comp.close_client.c.getResult(.net_close) catch {
                self.state = .failed;
                loop.stop();
                return;
            };

            // Close server socket
            self.state = .closing_server;
            self.comp = .{ .close_server = NetClose.init(self.server_sock) };
            self.comp.close_server.c.callback = closeServerCallback;
            self.comp.close_server.c.userdata = self;
            loop.add(&self.comp.close_server.c);
        }

        fn closeServerCallback(loop: *Loop, c: *Completion) void {
            const self: *Self = @ptrCast(@alignCast(c.userdata.?));

            self.comp.close_server.c.getResult(.net_close) catch {
                self.state = .failed;
                loop.stop();
                return;
            };

            self.state = .done;
        }
    };
}

pub fn EchoClient(comptime domain: socket.Domain, comptime sockaddr: type) type {
    return struct {
        state: State = .init,
        loop: *Loop,

        server_port_or_path: if (domain == .unix) []const u8 else u16,
        client_sock: Backend.NetHandle = undefined,
        connect_addr: sockaddr,

        // Union of completions - only one active at a time
        comp: union(enum) {
            open: NetOpen,
            connect: NetConnect,
            send: NetSend,
            recv: NetRecv,
            close: NetClose,
        },

        // Buffers
        send_buf: []const u8,
        send_iov: [1]socket.iovec_const = undefined,
        recv_buf: [1024]u8 = undefined,
        recv_iov: [1]socket.iovec = undefined,
        bytes_received: usize = 0,

        pub const State = enum {
            init,
            opening,
            connecting,
            sending,
            receiving,
            closing,
            done,
            failed,
        };

        const Self = @This();

        pub fn init(loop: *Loop, server_port_or_path: if (domain == .unix) []const u8 else u16, message: []const u8) Self {
            var self: Self = .{
                .loop = loop,
                .server_port_or_path = server_port_or_path,
                .send_buf = message,
                .comp = undefined,
                .connect_addr = undefined,
            };

            const protocol: socket.Protocol = if (domain == .unix) .default else .tcp;
            self.comp = .{ .open = NetOpen.init(domain, .stream, protocol) };

            return self;
        }

        pub fn start(self: *Self) void {
            self.state = .opening;
            self.comp.open.c.callback = openCallback;
            self.comp.open.c.userdata = self;
            self.loop.add(&self.comp.open.c);
        }

        fn openCallback(loop: *Loop, c: *Completion) void {
            const self: *Self = @ptrCast(@alignCast(c.userdata.?));

            self.client_sock = self.comp.open.c.getResult(.net_open) catch {
                self.state = .failed;
                loop.stop();
                return;
            };

            // Start connect
            self.state = .connecting;
            switch (domain) {
                .ipv4 => {
                    self.connect_addr = .{
                        .family = socket.AF.INET,
                        .addr = @bitCast([4]u8{ 127, 0, 0, 1 }),
                        .port = std.mem.nativeToBig(u16, self.server_port_or_path),
                        .zero = [_]u8{0} ** 8,
                    };
                },
                .ipv6 => {
                    self.connect_addr = .{
                        .family = socket.AF.INET6,
                        .addr = [_]u8{0} ** 15 ++ [_]u8{1}, // ::1
                        .port = std.mem.nativeToBig(u16, self.server_port_or_path),
                        .flowinfo = 0,
                        .scope_id = 0,
                    };
                },
                .unix => {
                    self.connect_addr = .{
                        .family = socket.AF.UNIX,
                        .path = undefined,
                    };
                    @memcpy(self.connect_addr.path[0..self.server_port_or_path.len], self.server_port_or_path);
                    self.connect_addr.path[self.server_port_or_path.len] = 0;
                },
            }
            self.comp = .{ .connect = NetConnect.init(
                self.client_sock,
                @ptrCast(&self.connect_addr),
                @sizeOf(sockaddr),
            ) };
            self.comp.connect.c.callback = connectCallback;
            self.comp.connect.c.userdata = self;
            loop.add(&self.comp.connect.c);
        }

        fn connectCallback(loop: *Loop, c: *Completion) void {
            const self: *Self = @ptrCast(@alignCast(c.userdata.?));

            self.comp.connect.getResult() catch {
                self.state = .failed;
                loop.stop();
                return;
            };

            // Start send
            self.state = .sending;
            self.send_iov = [_]socket.iovec_const{socket.iovecConstFromSlice(self.send_buf)};
            self.comp = .{ .send = NetSend.init(self.client_sock, &self.send_iov, .{}) };
            self.comp.send.c.callback = sendCallback;
            self.comp.send.c.userdata = self;
            loop.add(&self.comp.send.c);
        }

        fn sendCallback(loop: *Loop, c: *Completion) void {
            const self: *Self = @ptrCast(@alignCast(c.userdata.?));

            _ = self.comp.send.getResult() catch {
                self.state = .failed;
                loop.stop();
                return;
            };

            // Start recv
            self.state = .receiving;
            self.recv_iov = [_]socket.iovec{socket.iovecFromSlice(&self.recv_buf)};
            self.comp = .{ .recv = NetRecv.init(self.client_sock, &self.recv_iov, .{}) };
            self.comp.recv.c.callback = recvCallback;
            self.comp.recv.c.userdata = self;
            loop.add(&self.comp.recv.c);
        }

        fn recvCallback(loop: *Loop, c: *Completion) void {
            const self: *Self = @ptrCast(@alignCast(c.userdata.?));

            self.bytes_received = self.comp.recv.getResult() catch {
                self.state = .failed;
                loop.stop();
                return;
            };

            // Close socket
            self.state = .closing;
            self.comp = .{ .close = NetClose.init(self.client_sock) };
            self.comp.close.c.callback = closeCallback;
            self.comp.close.c.userdata = self;
            loop.add(&self.comp.close.c);
        }

        fn closeCallback(loop: *Loop, c: *Completion) void {
            const self: *Self = @ptrCast(@alignCast(c.userdata.?));

            self.comp.close.c.getResult(.net_close) catch {
                self.state = .failed;
                loop.stop();
                return;
            };

            self.state = .done;
        }
    };
}

fn testEcho(comptime domain: socket.Domain, comptime sockaddr: type) !void {
    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    const Server = EchoServer(domain, sockaddr);
    const Client = EchoClient(domain, sockaddr);

    // Start server
    var server = Server.init(&loop);
    defer {
        if (domain == .unix) {
            const path = std.mem.sliceTo(&server.server_addr.path, 0);
            std.fs.deleteFileAbsolute(path) catch {};
        }
    }
    server.start();

    // Run loop until server reaches accepting state
    var iterations: usize = 0;
    while (server.state != .accepting and server.state != .failed) {
        try loop.run(.once);
        iterations += 1;
        if (iterations > 100) {
            return error.Timeout;
        }
    }

    if (server.state == .failed) {
        return error.ServerSetupFailed;
    }

    // Start client
    const message = "Hello, Echo Server!";
    const port_or_path = if (domain == .unix)
        std.mem.sliceTo(&server.server_addr.path, 0)
    else
        server.bound_port;
    var client = Client.init(&loop, port_or_path, message);
    client.start();

    // Run until both are done
    try loop.run(.until_done);

    // Verify results
    try std.testing.expectEqual(.done, server.state);
    try std.testing.expectEqual(.done, client.state);
    try std.testing.expectEqual(message.len, client.bytes_received);
    try std.testing.expectEqualStrings(message, client.recv_buf[0..client.bytes_received]);
}

test "Echo server and client - IPv4" {
    try testEcho(.ipv4, socket.sockaddr.in);
}

test "Echo server and client - IPv6" {
    try testEcho(.ipv6, socket.sockaddr.in6);
}

test "Echo server and client - Unix" {
    try testEcho(.unix, socket.sockaddr.un);
}
