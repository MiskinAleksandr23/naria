const std = @import("std");
const naria = @import("naria");

pub const AtomicUsize = struct {
    const Self = @This();
    inner: std.atomic.Value(usize),

    pub fn load(self: *Self, comptime order: std.builtin.AtomicOrder) usize {
        naria.pauseWithProbability(0.5);
        const result = self.inner.load(order);
        naria.pause();
        return result;
    }

    pub fn store(self: *Self, value: usize, comptime order: std.builtin.AtomicOrder) void {
        naria.pause();
        self.inner.store(value, order);
        naria.pauseWithProbability(0.67);
    }
};

threadlocal var lc: usize = 0;

fn flappingCas(ptr: *AtomicUsize) void {
    if (lc % 10 == 9) {
        const v = ptr.load(.seq_cst);
        ptr.store(v + 1, .seq_cst);
    } else {
        naria.pause();
        _ = ptr.inner.fetchAdd(1, .seq_cst);
        naria.pauseWithProbability(0.42);
    }
    lc += 1;
}

const increments_per_thread = 20;

fn worker(ptr: *AtomicUsize) void {
    for (0..increments_per_thread) |_| flappingCas(ptr);
}

pub fn main(init: std.process.Init) !void {
    var iter: usize = 0;
    while (true) : (iter += 1) {
        var seed: u64 = undefined;
        init.io.random(std.mem.asBytes(&seed));
        var scheduler = naria.RandomScheduler.init(seed);
        var counter = AtomicUsize{ .inner = .init(0) };
        var runtime = naria.Runtime.init(init.gpa, init.io);
        defer runtime.deinit();
        errdefer {
            std.debug.print("---- iteration {d} (seed {d}) ----\n", .{ iter, seed });
            runtime.printTrace();
        }

        _ = try runtime.spawn(worker, .{&counter});
        _ = try runtime.spawn(worker, .{&counter});
        try runtime.run(&scheduler);

        const actual = counter.inner.load(.seq_cst);
        const expected = 2 * increments_per_thread;
        if (expected != actual) {
            std.debug.print("---- iteration {d} (seed {d}) ----\n", .{ iter, seed });
            runtime.printTrace();
            std.debug.print("Incorrect: expected {}, got {}\n", .{ expected, actual });
            break;
        }
    }
}
