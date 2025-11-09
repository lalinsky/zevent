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
