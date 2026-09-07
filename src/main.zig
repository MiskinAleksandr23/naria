const std = @import("std");
const Io = std.Io;
const Managed = @import("managed.zig");
const Context = @import("context.zig");

pub const AtomicUsize = struct {
    const Self = @This();
    inner: std.atomic.Value(usize),

    pub fn load(self: *Self, comptime order: std.builtin.AtomicOrder) usize {
        Context.pause();
        const result = self.inner.load(order);
        Context.pause();
        return result;
    }

    pub fn store(self: *Self, value: usize, comptime order: std.builtin.AtomicOrder) void {
        Context.pause();
        self.inner.store(value, order);
        Context.pause();
    }
};

pub fn randomBool(io: Io) bool {
    var byte: [1]u8 = undefined;
    io.random(&byte);
    return byte[0] & 1 != 0;
}

threadlocal var lc: usize = 0;

fn flappingCas(ptr: *AtomicUsize) void {
    if (lc % 100 == 99) {
        const v = ptr.load(.seq_cst);
        ptr.store(v + 1, .seq_cst);
    } else {
        _ = ptr.inner.fetchAdd(1, .seq_cst);
    }
    lc += 1;
}

pub fn main(init: std.process.Init) !void {
    var trace: std.ArrayList(struct {
        tid: usize,
        action: enum { increment, unpause },
    }) = .empty;
    defer trace.deinit(init.gpa);

    var iter: usize = 0;
    while (true) : (iter += 1) {
        trace.clearRetainingCapacity();

        var counter = AtomicUsize{ .inner = .init(0) };
        var t1 = try Managed.spawn(AtomicUsize, init.io, init.gpa, &counter, 0);
        defer t1.deinit();
        errdefer t1.join();

        var t2 = try Managed.spawn(AtomicUsize, init.io, init.gpa, &counter, 1);
        defer t2.deinit();
        errdefer t2.join();

        const threads: [2]*Managed.ManagedHandle(AtomicUsize) = .{ &t1, &t2 };

        var increments: usize = 0;

        for (0..151) |_| {
            for (0..2) |tid| {
                if (randomBool(init.io)) {
                    const paused = threads[tid].isPaused();
                    try trace.append(init.gpa, .{
                        .tid = tid,
                        .action = if (paused) .unpause else .increment,
                    });

                    if (paused) {
                        threads[tid].unpause();
                    } else {
                        try threads[tid].submit(flappingCas);
                        increments += 1;
                    }
                }
            }
        }
        for (0..2) |tid| {
            threads[tid].join();
        }

        const actual = counter.inner.load(.seq_cst);
        if (increments != actual) {
            std.debug.print("---- iteration {d} ----\nbegin trace\n", .{iter});
            for (trace.items) |entry| {
                std.debug.print("{}: {s}\n", .{ entry.tid, @tagName(entry.action) });
            }
            std.debug.print("Incorrect: expected {}, got {}\n", .{ increments, actual });
            break;
        }
    }
}
