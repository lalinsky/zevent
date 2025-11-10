const std = @import("std");
const Loop = @import("../loop.zig").Loop;
const Completion = @import("../completion.zig").Completion;
const Work = @import("../completion.zig").Work;
const NetOpen = @import("../completion.zig").NetOpen;
const NetBind = @import("../completion.zig").NetBind;
const NetListen = @import("../completion.zig").NetListen;
const NetShutdown = @import("../completion.zig").NetShutdown;
const NetClose = @import("../completion.zig").NetClose;
const FileOpen = @import("../completion.zig").FileOpen;
const FileClose = @import("../completion.zig").FileClose;
const FileRead = @import("../completion.zig").FileRead;
const FileWrite = @import("../completion.zig").FileWrite;
const NetGetAddrInfo = @import("../completion.zig").NetGetAddrInfo;
const NetGetNameInfo = @import("../completion.zig").NetGetNameInfo;
const net = @import("../os/net.zig");
const fs = @import("../os/fs.zig");
const dns = @import("../os/dns.zig");

/// Helper to handle socket open operation
pub fn handleNetOpen(c: *Completion) void {
    const data = c.cast(NetOpen);
    if (net.socket(data.domain, data.socket_type, data.protocol, data.flags)) |handle| {
        c.setResult(.net_open, handle);
    } else |err| {
        c.setError(err);
    }
}

/// Helper to handle bind operation with automatic getsockname call
pub fn handleNetBind(c: *Completion) void {
    const data = c.cast(NetBind);
    if (net.bind(data.handle, data.addr, data.addr_len.*)) |_| {
        // Update the address with the actual bound address
        if (net.getsockname(data.handle, data.addr, data.addr_len)) |_| {
            c.setResult(.net_bind, {});
        } else |err| {
            c.setError(err);
        }
    } else |err| {
        c.setError(err);
    }
}

/// Helper to handle listen operation
pub fn handleNetListen(c: *Completion) void {
    const data = c.cast(NetListen);
    if (net.listen(data.handle, data.backlog)) |_| {
        c.setResult(.net_listen, {});
    } else |err| {
        c.setError(err);
    }
}

/// Helper to handle shutdown operation
pub fn handleNetShutdown(c: *Completion) void {
    const data = c.cast(NetShutdown);
    if (net.shutdown(data.handle, data.how)) |_| {
        c.setResult(.net_shutdown, {});
    } else |err| {
        c.setError(err);
    }
}

/// Helper to handle close operation
pub fn handleNetClose(c: *Completion) void {
    const data = c.cast(NetClose);
    net.close(data.handle);
    c.setResult(.net_close, {});
}

/// Helper to handle file open operation
pub fn handleFileOpen(c: *Completion, allocator: std.mem.Allocator) void {
    const data = c.cast(FileOpen);
    if (fs.openat(allocator, data.dir, data.path, data.mode, data.flags)) |fd| {
        c.setResult(.file_open, fd);
    } else |err| {
        c.setError(err);
    }
}

/// Helper to handle file close operation
pub fn handleFileClose(c: *Completion) void {
    const data = c.cast(FileClose);
    if (fs.close(data.handle)) |_| {
        c.setResult(.file_close, {});
    } else |err| {
        c.setError(err);
    }
}

/// Helper to handle file read operation
pub fn handleFileRead(c: *Completion) void {
    const data = c.cast(FileRead);
    if (fs.preadv(data.handle, data.buffers, data.offset)) |bytes_read| {
        c.setResult(.file_read, bytes_read);
    } else |err| {
        c.setError(err);
    }
}

/// Helper to handle file write operation
pub fn handleFileWrite(c: *Completion) void {
    const data = c.cast(FileWrite);
    if (fs.pwritev(data.handle, data.buffers, data.offset)) |bytes_written| {
        c.setResult(.file_write, bytes_written);
    } else |err| {
        c.setError(err);
    }
}

/// Work function for FileOpen - performs blocking openat() syscall
pub fn fileOpenWork(loop: *Loop, work: *Work) void {
    _ = loop;
    const internal: *@FieldType(FileOpen, "internal") = @fieldParentPtr("work", work);
    const file_open: *FileOpen = @fieldParentPtr("internal", internal);
    handleFileOpen(&file_open.c, file_open.internal.allocator);
}

/// Work function for FileClose - performs blocking close() syscall
pub fn fileCloseWork(loop: *Loop, work: *Work) void {
    _ = loop;
    const internal: *@FieldType(FileClose, "internal") = @fieldParentPtr("work", work);
    const file_close: *FileClose = @fieldParentPtr("internal", internal);
    handleFileClose(&file_close.c);
}

/// Work function for FileRead - performs blocking preadv() syscall
pub fn fileReadWork(loop: *Loop, work: *Work) void {
    _ = loop;
    const internal: *@FieldType(FileRead, "internal") = @fieldParentPtr("work", work);
    const file_read: *FileRead = @fieldParentPtr("internal", internal);
    handleFileRead(&file_read.c);
}

/// Work function for FileWrite - performs blocking pwritev() syscall
pub fn fileWriteWork(loop: *Loop, work: *Work) void {
    _ = loop;
    const internal: *@FieldType(FileWrite, "internal") = @fieldParentPtr("work", work);
    const file_write: *FileWrite = @fieldParentPtr("internal", internal);
    handleFileWrite(&file_write.c);
}

/// Work function for NetGetAddrInfo - performs blocking getaddrinfo() syscall
pub fn getAddrInfoWork(loop: *Loop, work: *Work) void {
    _ = loop;
    const internal: *@FieldType(NetGetAddrInfo, "internal") = @fieldParentPtr("work", work);
    const get_addr_info: *NetGetAddrInfo = @fieldParentPtr("internal", internal);

    if (dns.getaddrinfo(
        get_addr_info.node,
        get_addr_info.service,
        get_addr_info.hints,
        get_addr_info.domain,
        get_addr_info.socktype,
        get_addr_info.protocol,
        get_addr_info.results,
    )) |count| {
        get_addr_info.c.setResult(.net_getaddrinfo, count);
    } else |err| {
        get_addr_info.c.setError(err);
    }
}

/// Work function for NetGetNameInfo - performs blocking getnameinfo() syscall
pub fn getNameInfoWork(loop: *Loop, work: *Work) void {
    _ = loop;
    const internal: *@FieldType(NetGetNameInfo, "internal") = @fieldParentPtr("work", work);
    const get_name_info: *NetGetNameInfo = @fieldParentPtr("internal", internal);

    if (dns.getnameinfo(
        get_name_info.addr,
        get_name_info.addr_len,
        get_name_info.host,
        get_name_info.service,
        get_name_info.flags,
    )) |result| {
        get_name_info.c.setResult(.net_getnameinfo, result);
    } else |err| {
        get_name_info.c.setError(err);
    }
}
