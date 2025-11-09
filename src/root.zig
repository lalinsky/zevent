const std = @import("std");

pub const backend = @import("backend.zig").backend;

pub const Loop = @import("loop.zig").Loop;
pub const RunMode = @import("loop.zig").RunMode;
pub const Completion = @import("completion.zig").Completion;

/// Low level system APIs
pub const system = @import("system.zig");

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(system.time);
    std.testing.refAllDecls(system.socket);
    std.testing.refAllDecls(system.posix);
}
