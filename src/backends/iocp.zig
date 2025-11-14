const std = @import("std");
const windows = std.os.windows;
const net = @import("../os/net.zig");
const common = @import("common.zig");
const LoopState = @import("../loop.zig").LoopState;
const Completion = @import("../completion.zig").Completion;
const Op = @import("../completion.zig").Op;
const NetOpen = @import("../completion.zig").NetOpen;
const NetBind = @import("../completion.zig").NetBind;
const NetListen = @import("../completion.zig").NetListen;
const NetConnect = @import("../completion.zig").NetConnect;
const NetAccept = @import("../completion.zig").NetAccept;
const NetClose = @import("../completion.zig").NetClose;
const NetShutdown = @import("../completion.zig").NetShutdown;

// Winsock extension function GUIDs
const WSAID_ACCEPTEX = windows.GUID{
    .Data1 = 0xb5367df1,
    .Data2 = 0xcbac,
    .Data3 = 0x11cf,
    .Data4 = .{ 0x95, 0xca, 0x00, 0x80, 0x5f, 0x48, 0xa1, 0x92 },
};

const WSAID_CONNECTEX = windows.GUID{
    .Data1 = 0x25a207b9,
    .Data2 = 0xddf3,
    .Data3 = 0x4660,
    .Data4 = .{ 0x8e, 0xe9, 0x76, 0xe5, 0x8c, 0x74, 0x06, 0x3e },
};

// Winsock extension function types
const LPFN_ACCEPTEX = *const fn (
    sListenSocket: windows.ws2_32.SOCKET,
    sAcceptSocket: windows.ws2_32.SOCKET,
    lpOutputBuffer: *anyopaque,
    dwReceiveDataLength: windows.DWORD,
    dwLocalAddressLength: windows.DWORD,
    dwRemoteAddressLength: windows.DWORD,
    lpdwBytesReceived: *windows.DWORD,
    lpOverlapped: *windows.OVERLAPPED,
) callconv(.winapi) windows.BOOL;

const LPFN_CONNECTEX = *const fn (
    s: windows.ws2_32.SOCKET,
    name: *const windows.ws2_32.sockaddr,
    namelen: c_int,
    lpSendBuffer: ?*const anyopaque,
    dwSendDataLength: windows.DWORD,
    lpdwBytesSent: ?*windows.DWORD,
    lpOverlapped: *windows.OVERLAPPED,
) callconv(.winapi) windows.BOOL;

fn loadWinsockExtension(comptime T: type, sock: windows.ws2_32.SOCKET, guid: windows.GUID) !T {
    var func_ptr: T = undefined;
    var bytes: windows.DWORD = 0;

    const rc = windows.ws2_32.WSAIoctl(
        sock,
        windows.ws2_32.SIO_GET_EXTENSION_FUNCTION_POINTER,
        @constCast(&guid),
        @sizeOf(windows.GUID),
        @ptrCast(&func_ptr),
        @sizeOf(T),
        &bytes,
        null,
        null,
    );

    if (rc != 0) {
        return error.Unexpected;
    }

    return func_ptr;
}

pub const NetHandle = net.fd_t;

pub const supports_file_ops = true;

// Backend-specific data stored in Completion.internal
pub const CompletionData = struct {
    overlapped: windows.OVERLAPPED = std.mem.zeroes(windows.OVERLAPPED),
};

// AcceptEx needs an extra buffer for address data
pub const NetAcceptData = struct {
    // AcceptEx requires a buffer for address data (local + remote addresses)
    // Buffer size: sizeof(sockaddr_in6) + 16 for each address
    addr_buffer: [128]u8 = undefined,
};

const ExtensionFunctions = struct {
    acceptex: LPFN_ACCEPTEX,
    connectex: LPFN_CONNECTEX,
};

pub const SharedState = struct {
    mutex: std.Thread.Mutex = .{},
    refcount: usize = 0,
    iocp: windows.HANDLE = windows.INVALID_HANDLE_VALUE,

    // Cache of extension function pointers per address family
    // Key: address family (AF_INET, AF_INET6), Value: ExtensionFunctions
    // AcceptEx/ConnectEx are STREAM-only, so family is sufficient
    extension_cache: std.AutoHashMapUnmanaged(u16, ExtensionFunctions) = .{},

    pub fn acquire(self: *SharedState) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.refcount == 0) {
            // First loop - create IOCP handle
            self.iocp = try windows.CreateIoCompletionPort(
                windows.INVALID_HANDLE_VALUE,
                null,
                0,
                0, // Use default number of concurrent threads
            );
        }
        self.refcount += 1;
    }

    pub fn release(self: *SharedState, allocator: std.mem.Allocator) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        std.debug.assert(self.refcount > 0);
        self.refcount -= 1;

        if (self.refcount == 0) {
            // Last loop - close IOCP handle
            if (self.iocp != windows.INVALID_HANDLE_VALUE) {
                windows.CloseHandle(self.iocp);
                self.iocp = windows.INVALID_HANDLE_VALUE;
            }

            // Clear extension function cache
            self.extension_cache.deinit(allocator);
            self.extension_cache = .{};
        }
    }

    /// Get extension functions for a given address family, loading on-demand if needed
    pub fn getExtensions(self: *SharedState, allocator: std.mem.Allocator, family: u16) !*const ExtensionFunctions {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Check if already cached
        if (self.extension_cache.get(family)) |funcs| {
            return &funcs;
        }

        // Not cached - load extension functions
        const funcs = try self.loadExtensionFunctions(family);

        // Cache for future use
        try self.extension_cache.put(allocator, family, funcs);

        return self.extension_cache.getPtr(family).?;
    }

    fn loadExtensionFunctions(self: *SharedState, family: u16) !ExtensionFunctions {
        _ = self;

        // Create a temporary socket for the specified family
        const sock = try net.socket(@enumFromInt(family), .stream, .{});
        defer net.close(sock);

        // Load AcceptEx
        const acceptex = try loadWinsockExtension(LPFN_ACCEPTEX, sock, WSAID_ACCEPTEX);

        // Load ConnectEx
        const connectex = try loadWinsockExtension(LPFN_CONNECTEX, sock, WSAID_CONNECTEX);

        return .{
            .acceptex = acceptex,
            .connectex = connectex,
        };
    }
};

pub const NetOpenError = error{
    Unexpected,
};

pub const NetShutdownHow = net.ShutdownHow;
pub const NetShutdownError = error{
    Unexpected,
};


const Self = @This();

const log = std.log.scoped(.aio_iocp);

allocator: std.mem.Allocator,
shared_state: *SharedState,
entries: []windows.OVERLAPPED_ENTRY,
queue_size: u16,

pub fn init(self: *Self, allocator: std.mem.Allocator, queue_size: u16, shared_state: *SharedState) !void {
    // Acquire reference to shared state (creates IOCP handle if first loop)
    try shared_state.acquire();
    errdefer shared_state.release(allocator);

    const entries = try allocator.alloc(windows.OVERLAPPED_ENTRY, queue_size);
    errdefer allocator.free(entries);

    self.* = .{
        .allocator = allocator,
        .shared_state = shared_state,
        .entries = entries,
        .queue_size = queue_size,
    };
}

pub fn deinit(self: *Self) void {
    self.allocator.free(self.entries);
    // Release reference to shared state (closes IOCP handle if last loop)
    self.shared_state.release(self.allocator);
}

pub fn wake(self: *Self) void {
    _ = self;
    @panic("TODO: wake()");
}

pub fn wakeFromAnywhere(self: *Self) void {
    _ = self;
    @panic("TODO: wakeFromAnywhere()");
}

pub fn submit(self: *Self, state: *LoopState, c: *Completion) void {
    c.state = .running;
    state.active += 1;

    switch (c.op) {
        .timer, .async, .work => unreachable, // Managed by the loop
        .cancel => unreachable, // Handled separately via cancel() method

        // Synchronous operations - complete immediately
        .net_open => {
            const data = c.cast(NetOpen);
            if (net.socket(data.domain, data.socket_type, data.flags)) |handle| {
                // Associate socket with IOCP
                const iocp_result = windows.CreateIoCompletionPort(
                    @ptrCast(handle),
                    self.shared_state.iocp,
                    0, // CompletionKey (we use OVERLAPPED pointer to find completion)
                    0, // NumberOfConcurrentThreads (0 = use default)
                ) catch {
                    // Failed to associate - close socket and fail
                    net.close(handle);
                    c.setError(error.Unexpected);
                    state.markCompleted(c);
                    return;
                };

                // Verify we got the same IOCP handle back
                if (iocp_result == self.shared_state.iocp) {
                    c.setResult(.net_open, handle);
                } else {
                    // Failed to associate - close socket and fail
                    net.close(handle);
                    c.setError(error.Unexpected);
                }
            } else |err| {
                c.setError(err);
            }
            state.markCompleted(c);
        },
        .net_bind => {
            common.handleNetBind(c);
            state.markCompleted(c);
        },
        .net_listen => {
            common.handleNetListen(c);
            state.markCompleted(c);
        },
        .net_close => {
            common.handleNetClose(c);
            state.markCompleted(c);
        },
        .net_shutdown => {
            common.handleNetShutdown(c);
            state.markCompleted(c);
        },

        .net_connect => {
            const data = c.cast(NetConnect);
            self.submitConnect(state, data) catch |err| {
                c.setError(err);
                state.markCompleted(c);
            };
        },

        .net_accept => {
            const data = c.cast(NetAccept);
            self.submitAccept(state, data) catch |err| {
                c.setError(err);
                state.markCompleted(c);
            };
        },

        .net_recv,
        .net_send,
        .net_recvfrom,
        .net_sendto,
        .file_open,
        .file_create,
        .file_close,
        .file_read,
        .file_write,
        .file_sync,
        .file_rename,
        .file_delete,
        => {
            c.setError(error.Unexpected);
            state.markCompleted(c);
        },
    }
}

fn submitAccept(self: *Self, state: *LoopState, data: *NetAccept) !void {
    // Get socket address to determine address family
    var addr_buf align(@alignOf(windows.ws2_32.sockaddr.in6)) = [_]u8{0} ** 128;
    var addr_len: i32 = addr_buf.len;
    if (windows.ws2_32.getsockname(
        data.handle,
        @ptrCast(&addr_buf),
        &addr_len,
    ) != 0) {
        return error.Unexpected;
    }

    const family: u16 = @as(*const windows.ws2_32.sockaddr, @ptrCast(&addr_buf)).family;

    // Load AcceptEx extension function for this address family
    const exts = try self.shared_state.getExtensions(self.allocator, family);

    // Create new socket for the accepted connection (same family as listening socket)
    const accept_socket = try net.socket(@enumFromInt(family), .stream, data.flags);
    errdefer net.close(accept_socket);

    // Associate the accept socket with IOCP
    const iocp_result = try windows.CreateIoCompletionPort(
        @ptrCast(accept_socket),
        self.shared_state.iocp,
        0,
        0,
    );

    if (iocp_result != self.shared_state.iocp) {
        net.close(accept_socket);
        return error.Unexpected;
    }

    // Initialize OVERLAPPED
    data.c.internal.overlapped = std.mem.zeroes(windows.OVERLAPPED);

    // Call AcceptEx
    var bytes_received: windows.DWORD = 0;
    const addr_size: windows.DWORD = @sizeOf(windows.ws2_32.sockaddr.in6) + 16;

    const result = exts.acceptex(
        data.handle, // listening socket
        accept_socket, // accept socket
        &data.internal.addr_buffer,
        0, // dwReceiveDataLength - we don't want any data, just connection
        addr_size, // local address length
        addr_size, // remote address length
        &bytes_received,
        &data.c.internal.overlapped,
    );

    if (result == windows.TRUE) {
        // Accepted immediately (unlikely but possible)
        data.c.setResult(.net_accept, accept_socket);
        state.markCompleted(&data.c);
    } else {
        const err = windows.ws2_32.WSAGetLastError();
        if (err == .WSA_IO_PENDING) {
            // Async operation started - will complete via IOCP
            // Store accept_socket so we can retrieve it in processCompletion
            data.result_private_do_not_touch = accept_socket;
            return;
        } else {
            // Immediate error
            net.close(accept_socket);
            log.err("AcceptEx failed: {}", .{err});
            return error.Unexpected;
        }
    }
}

fn submitConnect(self: *Self, state: *LoopState, data: *NetConnect) !void {
    // Get address family from the target address
    const family: u16 = @as(*const windows.ws2_32.sockaddr, @ptrCast(@alignCast(data.addr))).family;

    // Load ConnectEx extension function for this address family
    const exts = try self.shared_state.getExtensions(self.allocator, family);

    // ConnectEx requires the socket to be bound first (even to wildcard address)
    // Create a wildcard bind address
    var bind_addr_buf align(@alignOf(windows.ws2_32.sockaddr.in6)) = [_]u8{0} ** 128;
    var bind_addr_len: net.socklen_t = 0;

    if (family == windows.ws2_32.AF.INET) {
        const addr: *windows.ws2_32.sockaddr.in = @ptrCast(&bind_addr_buf);
        addr.family = windows.ws2_32.AF.INET;
        addr.port = 0; // Let OS choose port
        addr.addr = 0; // INADDR_ANY
        bind_addr_len = @sizeOf(windows.ws2_32.sockaddr.in);
    } else if (family == windows.ws2_32.AF.INET6) {
        const addr: *windows.ws2_32.sockaddr.in6 = @ptrCast(&bind_addr_buf);
        addr.family = windows.ws2_32.AF.INET6;
        addr.port = 0;
        addr.addr = [_]u8{0} ** 16; // IN6ADDR_ANY
        bind_addr_len = @sizeOf(windows.ws2_32.sockaddr.in6);
    } else {
        return error.Unexpected;
    }

    // Bind to wildcard address
    _ = net.bind(data.handle, @ptrCast(&bind_addr_buf), bind_addr_len) catch |err| {
        // If already bound, that's OK (user may have called bind explicitly)
        if (err != error.AddressInUse) return err;
    };

    // Initialize OVERLAPPED
    data.c.internal.overlapped = std.mem.zeroes(windows.OVERLAPPED);

    // Call ConnectEx
    const result = exts.connectex(
        data.handle,
        data.addr,
        @intCast(data.addr_len),
        null, // No send data
        0,
        null,
        &data.c.internal.overlapped,
    );

    if (result == windows.TRUE) {
        // Connected immediately (unlikely but possible)
        data.c.setResult(.net_connect, {});
        state.markCompleted(&data.c);
    } else {
        const err = windows.ws2_32.WSAGetLastError();
        if (err == .WSA_IO_PENDING) {
            // Async operation started - will complete via IOCP
            // Completion will be processed in poll()
            return;
        } else {
            // Immediate error
            log.err("ConnectEx failed: {}", .{err});
            return error.Unexpected;
        }
    }
}

pub fn cancel(self: *Self, state: *LoopState, target: *Completion) void {
    _ = self;
    _ = state;
    _ = target;
    @panic("TODO: cancel()");
}

fn processCompletion(self: *Self, state: *LoopState, entry: *const windows.OVERLAPPED_ENTRY) void {
    _ = self;

    // Get the OVERLAPPED pointer from the entry
    const overlapped = entry.lpOverlapped;

    // Use @fieldParentPtr to get from OVERLAPPED to CompletionData
    const completion_data: *CompletionData = @fieldParentPtr("overlapped", overlapped);

    // Use @fieldParentPtr again to get from CompletionData to Completion
    const c: *Completion = @fieldParentPtr("internal", completion_data);

    // Process based on operation type
    switch (c.op) {
        .net_connect => {
            const data = c.cast(NetConnect);

            // Check for errors
            if (entry.dwNumberOfBytesTransferred == 0 and entry.Internal != 0) {
                // Error occurred
                log.err("ConnectEx failed with status: {}", .{entry.Internal});
                c.setError(error.Unexpected);
            } else {
                // Success - need to call setsockopt to update socket context
                const SO_UPDATE_CONNECT_CONTEXT = 0x7010;
                _ = windows.ws2_32.setsockopt(
                    data.handle,
                    windows.ws2_32.SOL.SOCKET,
                    SO_UPDATE_CONNECT_CONTEXT,
                    null,
                    0,
                );
                c.setResult(.net_connect, {});
            }

            state.markCompleted(c);
        },

        .net_accept => {
            const data = c.cast(NetAccept);

            // Check for errors
            if (entry.Internal != 0) {
                // Error occurred - close the accept socket
                net.close(data.result_private_do_not_touch);
                log.err("AcceptEx failed with status: {}", .{entry.Internal});
                c.setError(error.Unexpected);
            } else {
                // Success - need to call setsockopt to update socket context
                const SO_UPDATE_ACCEPT_CONTEXT = 0x700B;
                _ = windows.ws2_32.setsockopt(
                    data.result_private_do_not_touch,
                    windows.ws2_32.SOL.SOCKET,
                    SO_UPDATE_ACCEPT_CONTEXT,
                    @ptrCast(&data.handle),
                    @sizeOf(@TypeOf(data.handle)),
                );
                c.setResult(.net_accept, data.result_private_do_not_touch);
            }

            state.markCompleted(c);
        },

        else => {
            log.err("Unexpected completion for operation: {}", .{c.op});
            c.setError(error.Unexpected);
            state.markCompleted(c);
        },
    }
}

pub fn poll(self: *Self, state: *LoopState, timeout_ms: u64) !bool {
    const timeout: u32 = std.math.cast(u32, timeout_ms) orelse std.math.maxInt(u32);

    var num_entries: u32 = 0;
    const result = windows.kernel32.GetQueuedCompletionStatusEx(
        self.shared_state.iocp, // Safe to access without mutex - we hold a reference
        self.entries.ptr,
        @intCast(self.entries.len),
        &num_entries,
        timeout,
        windows.FALSE, // Not alertable
    );

    if (result == windows.FALSE) {
        const err = windows.kernel32.GetLastError();
        switch (err) {
            .WAIT_TIMEOUT => return true, // Timed out
            else => {
                log.err("GetQueuedCompletionStatusEx failed: {}", .{err});
                return error.Unexpected;
            },
        }
    }

    // Process completions
    for (self.entries[0..num_entries]) |entry| {
        self.processCompletion(state, &entry);
    }

    return false; // Did not timeout
}
