const std = @import("std");
const ThreadId = @import("runtime.zig").ThreadId;

pub const RandomScheduler = struct {
    const Self = @This();
    rng: std.Random.DefaultPrng,

    pub fn init(seed: u64) Self {
        return .{ .rng = .init(seed) };
    }

    pub fn choose(self: *Self, runnable: []const ThreadId) !ThreadId {
        if (runnable.len == 0) return error.NoRunnableThreads;
        return runnable[self.rng.random().uintLessThan(usize, runnable.len)];
    }
};

pub const ReplayScheduler = struct {
    const Self = @This();
    choices: []const ThreadId,
    position: usize = 0,

    pub fn init(choices: []const ThreadId) Self {
        return .{ .choices = choices };
    }

    pub fn choose(self: *Self, runnable: []const ThreadId) !ThreadId {
        if (runnable.len == 0) return error.NoRunnableThreads;
        if (self.position == self.choices.len) return error.ReplayExhausted;
        const tid = self.choices[self.position];
        for (runnable) |available| {
            if (available == tid) {
                self.position += 1;
                return tid;
            }
        }
        return error.ThreadNotRunnable;
    }

    pub fn finish(self: *const Self) !void {
        if (self.position != self.choices.len) return error.UnusedReplayChoices;
    }
};
