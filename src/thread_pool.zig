const std = @import("std");
const Queue = @import("queue.zig").Queue;
const Completion = @import("completion.zig").Completion;
const Work = @import("completion.zig").Work;

pub const ThreadPool = struct {
    allocator: std.mem.Allocator,
    threads: std.ArrayList(std.Thread) = .empty,
    mutex: std.Thread.Mutex = .{},
    not_empty: std.Thread.Condition = .{},
    shutdown: bool = false,
    queue: Queue(Completion) = .{},

    pub const Options = struct {
        num_threads: ?usize = null,
    };

    pub fn init(self: *ThreadPool, allocator: std.mem.Allocator, options: Options) !void {
        self.* = .{
            .allocator = allocator,
        };
        defer self.deinit();

        const num_threads = options.num_threads orelse std.Thread.cpuCount();
        try self.threads.ensureTotalCapacity(allocator, num_threads);

        for (0..num_threads) |_| {
            const thread = try std.Thread.spawn(.{}, run, .{self});
            self.threads.appendAssumeCapacity(thread);
        }
    }

    pub fn deinit(self: *ThreadPool) void {
        self.stop();

        while (self.threads.pop()) |thread| {
            thread.join();
        }

        self.threads.deinit(self.allocator);
    }

    pub fn stop(self: *ThreadPool) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.shutdown = true;
        self.not_empty.broadcast();
    }

    pub fn submit(self: *ThreadPool, work: *Work) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.queue.push(&work.c);
        self.not_empty.signal();
    }

    pub fn cancel(self: *ThreadPool, work: *Work) bool {
        // Try to transition from pending to canceled atomically
        if (work.state.cmpxchgStrong(.pending, .canceled, .acq_rel, .acquire)) |_| {
            // Already in different state (running or completed)
            return false;
        }

        // Successfully marked as canceled, now safe to remove from queue
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.queue.remove(&work.c);
    }

    pub fn run(self: *ThreadPool) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (!self.shutdown) {
            const c = self.queue.pop() orelse {
                self.not_empty.wait(&self.mutex);
                continue;
            };

            self.mutex.unlock();
            defer self.mutex.lock();

            const work = c.cast(Work);

            // Try to claim the work by transitioning from pending to running
            if (work.state.cmpxchgStrong(.pending, .running, .acq_rel, .acquire)) |state| {
                // Work was canceled before we could start it
                std.debug.assert(state == .canceled);
                work.result = error.Canceled;
            } else {
                // We successfully claimed it, execute the work
                work.func(work.userdata, c);
                work.result = {};
                work.state.store(.completed, .release);
            }

            if (work.loop) |loop| {
                loop.state.work_completions.push(c);
                loop.wake();
            }
        }
    }
};
