const std = @import("std");
const builtin = @import("builtin");
const posix = @import("posix.zig");

pub const fd_t = switch (builtin.os.tag) {
    .windows => std.os.windows.HANDLE,
    else => posix.system.fd_t,
};

pub const iovec = @import("base.zig").iovec;
pub const iovec_const = @import("base.zig").iovec_const;

pub const mode_t = std.posix.mode_t;

pub const FileOpenFlags = struct {
    create: bool = false,
    truncate: bool = false,
    append: bool = false,
    exclusive: bool = false,
};

pub const FileOpenError = error{
    AccessDenied,
    PermissionDenied,
    SymLinkLoop,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    NoDevice,
    FileNotFound,
    NameTooLong,
    SystemResources,
    FileTooBig,
    IsDir,
    NoSpaceLeft,
    NotDir,
    PathAlreadyExists,
    DeviceBusy,
    FileLocksNotSupported,
    BadPathName,
    InvalidUtf8,
    InvalidWtf8,
    NetworkNotFound,
    ProcessNotFound,
    FileBusy,
    Unexpected,
};

pub const FileReadError = error{
    AccessDenied,
    WouldBlock,
    ConnectionResetByPeer,
    ConnectionTimedOut,
    InputOutput,
    IsDir,
    OperationAborted,
    BrokenPipe,
    SystemResources,
    SocketNotConnected,
    NotOpenForReading,
    Unexpected,
};

pub const FileWriteError = error{
    AccessDenied,
    WouldBlock,
    ConnectionResetByPeer,
    ConnectionTimedOut,
    InputOutput,
    NoSpaceLeft,
    OperationAborted,
    BrokenPipe,
    SystemResources,
    SocketNotConnected,
    NotOpenForWriting,
    DiskQuota,
    FileTooBig,
    LockViolation,
    Unexpected,
};

/// Open a file using openat() syscall
pub fn openat(allocator: std.mem.Allocator, dir: fd_t, path: []const u8, mode: mode_t, flags: FileOpenFlags) FileOpenError!fd_t {
    if (builtin.os.tag == .windows) {
        // TODO: Windows implementation
        return error.Unexpected;
    }

    var open_flags: posix.system.O = .{
        .ACCMODE = .RDWR,
        .CLOEXEC = true,
    };
    if (flags.create) open_flags.CREAT = true;
    if (flags.truncate) open_flags.TRUNC = true;
    if (flags.append) open_flags.APPEND = true;
    if (flags.exclusive) open_flags.EXCL = true;

    const path_z = allocator.dupeZ(u8, path) catch return error.SystemResources;
    defer allocator.free(path_z);

    const rc = posix.system.openat(dir, path_z.ptr, open_flags, mode);
    return switch (posix.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .ACCES => error.AccessDenied,
        .PERM => error.PermissionDenied,
        .LOOP => error.SymLinkLoop,
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        .NODEV => error.NoDevice,
        .NOENT => error.FileNotFound,
        .NAMETOOLONG => error.NameTooLong,
        .NOMEM => error.SystemResources,
        .FBIG => error.FileTooBig,
        .ISDIR => error.IsDir,
        .NOSPC => error.NoSpaceLeft,
        .NOTDIR => error.NotDir,
        .EXIST => error.PathAlreadyExists,
        .BUSY => error.DeviceBusy,
        .TXTBSY => error.FileBusy,
        else => |e| posix.unexpectedErrno(e) catch error.Unexpected,
    };
}

/// Close a file descriptor
pub fn close(fd: fd_t) error{}!void {
    if (builtin.os.tag == .windows) {
        // TODO: Windows implementation
        return;
    }

    // close() errors are generally ignored in async contexts
    // because the fd is invalid after close regardless of error
    _ = posix.system.close(fd);
}

/// Read from file at offset using preadv()
pub fn preadv(fd: fd_t, buffers: []iovec, offset: u64) FileReadError!usize {
    if (builtin.os.tag == .windows) {
        // TODO: Windows implementation
        return error.Unexpected;
    }

    const rc = posix.system.preadv(fd, buffers.ptr, buffers.len, @intCast(offset));
    return switch (posix.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .ACCES => error.AccessDenied,
        .AGAIN => error.WouldBlock,
        .CONNRESET => error.ConnectionResetByPeer,
        .TIMEDOUT => error.ConnectionTimedOut,
        .IO => error.InputOutput,
        .ISDIR => error.IsDir,
        .CANCELED => error.OperationAborted,
        .PIPE => error.BrokenPipe,
        .NOMEM => error.SystemResources,
        .NOTCONN => error.SocketNotConnected,
        .BADF => error.NotOpenForReading,
        else => |e| posix.unexpectedErrno(e) catch error.Unexpected,
    };
}

/// Write to file at offset using pwritev()
pub fn pwritev(fd: fd_t, buffers: []const iovec_const, offset: u64) FileWriteError!usize {
    if (builtin.os.tag == .windows) {
        // TODO: Windows implementation
        return error.Unexpected;
    }

    const rc = posix.system.pwritev(fd, buffers.ptr, buffers.len, @intCast(offset));
    return switch (posix.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .ACCES => error.AccessDenied,
        .AGAIN => error.WouldBlock,
        .CONNRESET => error.ConnectionResetByPeer,
        .TIMEDOUT => error.ConnectionTimedOut,
        .IO => error.InputOutput,
        .NOSPC => error.NoSpaceLeft,
        .CANCELED => error.OperationAborted,
        .PIPE => error.BrokenPipe,
        .NOMEM => error.SystemResources,
        .NOTCONN => error.SocketNotConnected,
        .BADF => error.NotOpenForWriting,
        .DQUOT => error.DiskQuota,
        .FBIG => error.FileTooBig,
        else => |e| posix.unexpectedErrno(e) catch error.Unexpected,
    };
}
