const std = @import("std");
const builtin = @import("builtin");
const Loop = @import("loop.zig").Loop;
const Work = @import("completion.zig").Work;
const FileOpen = @import("completion.zig").FileOpen;
const FileClose = @import("completion.zig").FileClose;
const FileRead = @import("completion.zig").FileRead;
const FileWrite = @import("completion.zig").FileWrite;
const fs = @import("os/fs.zig");

/// Work function for FileOpen - performs blocking openat() syscall
pub fn fileOpenWork(loop: *Loop, work: *Work) void {
    _ = loop;
    const internal: *@FieldType(FileOpen, "internal") = @fieldParentPtr("work", work);
    const file_open: *FileOpen = @fieldParentPtr("internal", internal);

    // Platform-specific file open
    if (builtin.os.tag == .windows) {
        // TODO: Windows implementation using CreateFile
        file_open.c.setError(error.Unexpected);
    } else {
        // POSIX implementation
        const result = fs.openat(
            file_open.internal.allocator,
            file_open.dir,
            file_open.path,
            file_open.mode,
            file_open.flags,
        );

        if (result) |fd| {
            file_open.c.setResult(.file_open, fd);
        } else |err| {
            file_open.c.setError(err);
        }
    }
}

/// Work function for FileClose - performs blocking close() syscall
pub fn fileCloseWork(loop: *Loop, work: *Work) void {
    _ = loop;
    const internal: *@FieldType(FileClose, "internal") = @fieldParentPtr("work", work);
    const file_close: *FileClose = @fieldParentPtr("internal", internal);

    // Platform-specific file close
    if (builtin.os.tag == .windows) {
        // TODO: Windows implementation using CloseHandle
        file_close.c.setError(error.Unexpected);
    } else {
        // POSIX implementation
        const result = fs.close(file_close.handle);

        if (result) {
            file_close.c.setResult(.file_close, {});
        } else |err| {
            file_close.c.setError(err);
        }
    }
}

/// Work function for FileRead - performs blocking preadv() syscall
pub fn fileReadWork(loop: *Loop, work: *Work) void {
    _ = loop;
    const internal: *@FieldType(FileRead, "internal") = @fieldParentPtr("work", work);
    const file_read: *FileRead = @fieldParentPtr("internal", internal);

    // Platform-specific file read
    if (builtin.os.tag == .windows) {
        // TODO: Windows implementation using ReadFile
        file_read.c.setError(error.Unexpected);
    } else {
        // POSIX implementation using positional read
        const result = fs.preadv(
            file_read.handle,
            file_read.buffers,
            file_read.offset,
        );

        if (result) |bytes_read| {
            file_read.c.setResult(.file_read, bytes_read);
        } else |err| {
            file_read.c.setError(err);
        }
    }
}

/// Work function for FileWrite - performs blocking pwritev() syscall
pub fn fileWriteWork(loop: *Loop, work: *Work) void {
    _ = loop;
    const internal: *@FieldType(FileWrite, "internal") = @fieldParentPtr("work", work);
    const file_write: *FileWrite = @fieldParentPtr("internal", internal);

    // Platform-specific file write
    if (builtin.os.tag == .windows) {
        // TODO: Windows implementation using WriteFile
        file_write.c.setError(error.Unexpected);
    } else {
        // POSIX implementation using positional write
        const result = fs.pwritev(
            file_write.handle,
            file_write.buffers,
            file_write.offset,
        );

        if (result) |bytes_written| {
            file_write.c.setResult(.file_write, bytes_written);
        } else |err| {
            file_write.c.setError(err);
        }
    }
}
