const std = @import("std");
const Runtime = @import("runtime.zig").Runtime;
const ThreadId = @import("runtime.zig").ThreadId;
const RandomScheduler = @import("scheduler.zig").RandomScheduler;
const ReplayScheduler = @import("scheduler.zig").ReplayScheduler;
const pause = @import("context.zig").pause;
const Counter = std.atomic.Value(usize);

const Tasks = struct {
    fn add(counter: *Counter, amount: usize) void {
        _ = counter.fetchAdd(amount, .seq_cst);
    }

    fn repeat(counter: *Counter, count: usize) void {
        for (0..count) |_| {
            pause();
            _ = counter.fetchAdd(1, .seq_cst);
            pause();
        }
    }

    fn brokenIncrement(counter: *Counter) void {
        pause();
        const value = counter.load(.seq_cst);
        pause();
        counter.store(value + 1, .seq_cst);
    }
};

test "registration waits for the scheduler and completed threads are excluded" {
    var counter = Counter.init(0);
    var runtime = Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();

    const first = try runtime.spawn(Tasks.add, .{ &counter, @as(usize, 1) });
    const second = try runtime.spawn(Tasks.add, .{ &counter, @as(usize, 10) });
    try std.testing.expectEqual(@as(usize, 0), counter.load(.seq_cst));
    try std.testing.expect(runtime.hasWork());
    try std.testing.expectEqualSlices(ThreadId, &.{ first, second }, runtime.runnable());

    try runtime.step(second);
    try std.testing.expectEqual(@as(usize, 10), counter.load(.seq_cst));
    try std.testing.expectEqualSlices(ThreadId, &.{first}, runtime.runnable());
    try std.testing.expectError(error.ThreadNotRunnable, runtime.step(second));
    try std.testing.expectError(error.InvalidThreadId, runtime.step(99));
    try std.testing.expectError(error.AlreadyStarted, runtime.spawn(Tasks.add, .{ &counter, @as(usize, 1) }));
    try std.testing.expectEqual(@as(usize, 1), runtime.trace.items.len);

    try runtime.step(first);
    try std.testing.expectEqual(@as(usize, 11), counter.load(.seq_cst));
    try std.testing.expect(!runtime.hasWork());
    try std.testing.expectEqual(@as(usize, 0), runtime.runnable().len);
}

test "a long task is scheduled through every pause including its final resume" {
    var counter = Counter.init(0);
    var runtime = Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    _ = try runtime.spawn(Tasks.repeat, .{ &counter, @as(usize, 64) });
    _ = try runtime.spawn(Tasks.repeat, .{ &counter, @as(usize, 64) });
    var scheduler = RandomScheduler.init(42);
    try runtime.run(&scheduler);

    try std.testing.expectEqual(@as(usize, 128), counter.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 258), runtime.trace.items.len);
    var starts: usize = 0;
    for (runtime.trace.items) |event| {
        if (event.action == .start) starts += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), starts);
    try std.testing.expect(!runtime.hasWork());
}

test "recorded choices reproduce a lost update and the complete trace" {
    var counter = Counter.init(0);
    var first = Runtime.init(std.testing.allocator, std.testing.io);
    defer first.deinit();
    _ = try first.spawn(Tasks.brokenIncrement, .{&counter});
    _ = try first.spawn(Tasks.brokenIncrement, .{&counter});
    var original = ReplayScheduler.init(&.{ 0, 1, 0, 1, 0, 1 });
    try first.run(&original);
    try std.testing.expectEqual(@as(usize, 1), counter.load(.seq_cst));

    const choices = try first.recordedChoices(std.testing.allocator);
    defer std.testing.allocator.free(choices);
    counter.store(0, .seq_cst);
    var second = Runtime.init(std.testing.allocator, std.testing.io);
    defer second.deinit();
    _ = try second.spawn(Tasks.brokenIncrement, .{&counter});
    _ = try second.spawn(Tasks.brokenIncrement, .{&counter});
    var replay = ReplayScheduler.init(choices);
    try second.run(&replay);
    try std.testing.expectEqual(@as(usize, 1), counter.load(.seq_cst));
    try std.testing.expectEqualDeep(first.trace.items, second.trace.items);
}

test "same seed reproduces the execution independently of native thread startup" {
    var first_counter = Counter.init(0);
    var first = Runtime.init(std.testing.allocator, std.testing.io);
    defer first.deinit();
    _ = try first.spawn(Tasks.repeat, .{ &first_counter, @as(usize, 20) });
    _ = try first.spawn(Tasks.repeat, .{ &first_counter, @as(usize, 20) });
    var first_scheduler = RandomScheduler.init(1234);
    try first.run(&first_scheduler);

    var second_counter = Counter.init(0);
    var second = Runtime.init(std.testing.allocator, std.testing.io);
    defer second.deinit();
    _ = try second.spawn(Tasks.repeat, .{ &second_counter, @as(usize, 20) });
    _ = try second.spawn(Tasks.repeat, .{ &second_counter, @as(usize, 20) });
    var second_scheduler = RandomScheduler.init(1234);
    try second.run(&second_scheduler);

    try std.testing.expectEqual(first_counter.load(.seq_cst), second_counter.load(.seq_cst));
    try std.testing.expectEqualDeep(first.trace.items, second.trace.items);
}

test "contexts remain valid when thread storage grows" {
    var counter = Counter.init(0);
    var runtime = Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    for (0..12) |_| {
        _ = try runtime.spawn(Tasks.repeat, .{ &counter, @as(usize, 2) });
    }
    try std.testing.expectEqual(@as(usize, 0), counter.load(.seq_cst));
    var scheduler = RandomScheduler.init(7);
    try runtime.run(&scheduler);
    try std.testing.expectEqual(@as(usize, 24), counter.load(.seq_cst));
}

test "deinit cancels an unstarted scenario and drains a started scenario" {
    var counter = Counter.init(0);
    {
        var runtime = Runtime.init(std.testing.allocator, std.testing.io);
        defer runtime.deinit();
        _ = try runtime.spawn(Tasks.add, .{ &counter, @as(usize, 100) });
    }
    try std.testing.expectEqual(@as(usize, 0), counter.load(.seq_cst));
    {
        var runtime = Runtime.init(std.testing.allocator, std.testing.io);
        defer runtime.deinit();
        const tid = try runtime.spawn(Tasks.repeat, .{ &counter, @as(usize, 3) });
        _ = try runtime.spawn(Tasks.add, .{ &counter, @as(usize, 100) });
        try runtime.step(tid);
        try std.testing.expectEqual(@as(usize, 0), counter.load(.seq_cst));
    }
    try std.testing.expectEqual(@as(usize, 103), counter.load(.seq_cst));
}

test "failure cleanup also schedules the task a paused worker is waiting for" {
    const Handoff = struct {
        ready: std.atomic.Value(bool) = .init(false),
        received: bool = false,

        fn receive(self: *@This()) void {
            while (!self.ready.load(.seq_cst)) pause();
            self.received = true;
        }

        fn send(self: *@This()) void {
            self.ready.store(true, .seq_cst);
        }
    };
    var state: Handoff = .{};
    {
        var runtime = Runtime.init(std.testing.allocator, std.testing.io);
        defer runtime.deinit();
        const receiver = try runtime.spawn(Handoff.receive, .{&state});
        _ = try runtime.spawn(Handoff.send, .{&state});
        try runtime.step(receiver);
    }
    try std.testing.expect(state.received);
}

test "random scheduler rejects empty input and only chooses available IDs" {
    var scheduler = RandomScheduler.init(42);
    try std.testing.expectError(error.NoRunnableThreads, scheduler.choose(&.{}));
    for (0..100) |_| {
        const tid = try scheduler.choose(&.{ 2, 5 });
        try std.testing.expect(tid == 2 or tid == 5);
    }
}

test "replay rejects unavailable IDs, exhaustion and unused choices" {
    var replay = ReplayScheduler.init(&.{ 1, 0 });
    try std.testing.expectError(error.NoRunnableThreads, replay.choose(&.{}));
    try std.testing.expectError(error.ThreadNotRunnable, replay.choose(&.{0}));
    try std.testing.expectEqual(@as(usize, 0), replay.position);
    try std.testing.expectEqual(@as(ThreadId, 1), try replay.choose(&.{ 0, 1 }));
    try std.testing.expectError(error.UnusedReplayChoices, replay.finish());
    try std.testing.expectEqual(@as(ThreadId, 0), try replay.choose(&.{0}));
    try replay.finish();
    try std.testing.expectError(error.ReplayExhausted, replay.choose(&.{0}));
}

test "runtime rejects truncated and overlong replays" {
    var counter = Counter.init(0);
    {
        var runtime = Runtime.init(std.testing.allocator, std.testing.io);
        defer runtime.deinit();
        _ = try runtime.spawn(Tasks.repeat, .{ &counter, @as(usize, 1) });
        var replay = ReplayScheduler.init(&.{0});
        try std.testing.expectError(error.ReplayExhausted, runtime.run(&replay));
    }
    {
        var runtime = Runtime.init(std.testing.allocator, std.testing.io);
        defer runtime.deinit();
        _ = try runtime.spawn(Tasks.add, .{ &counter, @as(usize, 1) });
        var replay = ReplayScheduler.init(&.{ 0, 0 });
        try std.testing.expectError(error.UnusedReplayChoices, runtime.run(&replay));
    }
}

test "empty runtime completes without requesting a scheduling decision" {
    var runtime = Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    var replay = ReplayScheduler.init(&.{});
    try runtime.run(&replay);
    try std.testing.expect(!runtime.hasWork());
    try std.testing.expectEqual(@as(usize, 0), runtime.trace.items.len);
}

fn allocationScenario(allocator: std.mem.Allocator) !void {
    var counter = Counter.init(0);
    var runtime = Runtime.init(allocator, std.testing.io);
    defer runtime.deinit();
    _ = try runtime.spawn(Tasks.repeat, .{ &counter, @as(usize, 20) });
    _ = try runtime.spawn(Tasks.repeat, .{ &counter, @as(usize, 20) });
    var scheduler = RandomScheduler.init(17);
    try runtime.run(&scheduler);
    const choices = try runtime.recordedChoices(allocator);
    defer allocator.free(choices);
    try std.testing.expectEqual(@as(usize, 40), counter.load(.seq_cst));
}

test "all allocation failures clean up registered and partially executed tasks" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationScenario, .{});
}
