const std = @import("std");
const builtin = @import("builtin");
const backend = @import("../backend.zig").backend;
const Loop = @import("../loop.zig").Loop;
const FileOpen = @import("../completion.zig").FileOpen;
const FileClose = @import("../completion.zig").FileClose;

test "File: open/close" {
    if (backend != .io_uring) return error.SkipZigTest;

    var loop: Loop = undefined;
    try loop.init(.{});
    defer loop.deinit();

    const cwd = std.fs.cwd();

    var file_open = FileOpen.init(cwd.fd, "test-file", 0o664, .{ .create = true, .truncate = true });
    loop.add(&file_open.c);

    try loop.run(.until_done);

    const fd = try file_open.getResult();
    try std.testing.expect(fd > 0);

    var file_close = FileClose.init(fd);
    loop.add(&file_close.c);

    try loop.run(.until_done);

    try file_close.getResult();
}
