const std = @import("std");
const Runtime = @import("runtime.zig").Runtime;
const ThreadId = @import("runtime.zig").ThreadId;
const RandomScheduler = @import("scheduler.zig").RandomScheduler;
const ReplayScheduler = @import("scheduler.zig").ReplayScheduler;
const pause = @import("context.zig").pause;
const pauseWithProbability = @import("context.zig").pauseWithProbability;
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

    fn probabilisticSteps(progress: *usize) void {
        for (0..128) |checkpoint| {
            progress.* = checkpoint;
            pauseWithProbability(0.5);
        }
        progress.* = 128;
    }
};

const ProbabilisticCounter = struct {
    const Event = struct {
        tid: ThreadId,
        operation: enum { load, store },
        value: usize,
    };

    counter: Counter = .init(0),
    events: [64]Event = undefined,
    event_count: usize = 0,

    fn increment(self: *@This(), tid: ThreadId) void {
        for (0..16) |_| {
            pauseWithProbability(0.5);
            const value = self.counter.load(.seq_cst);
            self.record(.{ .tid = tid, .operation = .load, .value = value });
            pauseWithProbability(if (value % 2 == 0) 0.67 else 0.25);
            self.counter.store(value + 1, .seq_cst);
            self.record(.{ .tid = tid, .operation = .store, .value = value + 1 });
            pauseWithProbability(0.42);
        }
    }

    fn record(self: *@This(), event: Event) void {
        self.events[self.event_count] = event;
        self.event_count += 1;
    }
};

test "registration waits for the scheduler and completed threads are excluded" {
    var counter = Counter.init(0);
    var runtime = Runtime.init(std.testing.allocator, std.testing.io, 42);
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
    var runtime = Runtime.init(std.testing.allocator, std.testing.io, 42);
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
    var first = Runtime.init(std.testing.allocator, std.testing.io, 42);
    defer first.deinit();
    _ = try first.spawn(Tasks.brokenIncrement, .{&counter});
    _ = try first.spawn(Tasks.brokenIncrement, .{&counter});
    var original = ReplayScheduler.init(&.{ 0, 1, 0, 1, 0, 1 });
    try first.run(&original);
    try std.testing.expectEqual(@as(usize, 1), counter.load(.seq_cst));

    const choices = try first.recordedChoices(std.testing.allocator);
    defer std.testing.allocator.free(choices);
    counter.store(0, .seq_cst);
    var second = Runtime.init(std.testing.allocator, std.testing.io, first.seed);
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
    var first = Runtime.init(std.testing.allocator, std.testing.io, 42);
    defer first.deinit();
    _ = try first.spawn(Tasks.repeat, .{ &first_counter, @as(usize, 20) });
    _ = try first.spawn(Tasks.repeat, .{ &first_counter, @as(usize, 20) });
    var first_scheduler = RandomScheduler.init(1234);
    try first.run(&first_scheduler);

    var second_counter = Counter.init(0);
    var second = Runtime.init(std.testing.allocator, std.testing.io, first.seed);
    defer second.deinit();
    _ = try second.spawn(Tasks.repeat, .{ &second_counter, @as(usize, 20) });
    _ = try second.spawn(Tasks.repeat, .{ &second_counter, @as(usize, 20) });
    var second_scheduler = RandomScheduler.init(1234);
    try second.run(&second_scheduler);

    try std.testing.expectEqual(first_counter.load(.seq_cst), second_counter.load(.seq_cst));
    try std.testing.expectEqualDeep(first.trace.items, second.trace.items);
}

test "runtime seed reproduces probabilistic pauses with replay and random scheduling" {
    for ([_]u64{ 0, 1, 42, std.math.maxInt(u64) }) |seed| {
        var first_state: ProbabilisticCounter = .{};
        var first = Runtime.init(std.testing.allocator, std.testing.io, seed);
        defer first.deinit();
        _ = try first.spawn(ProbabilisticCounter.increment, .{ &first_state, @as(ThreadId, 0) });
        _ = try first.spawn(ProbabilisticCounter.increment, .{ &first_state, @as(ThreadId, 1) });
        var scheduler = RandomScheduler.init(1234);
        try first.run(&scheduler);
        try std.testing.expectEqual(seed, first.seed);
        try std.testing.expectEqual(first_state.events.len, first_state.event_count);

        const choices = try first.recordedChoices(std.testing.allocator);
        defer std.testing.allocator.free(choices);

        var replay_state: ProbabilisticCounter = .{};
        var second = Runtime.init(std.testing.allocator, std.testing.io, first.seed);
        defer second.deinit();
        _ = try second.spawn(ProbabilisticCounter.increment, .{ &replay_state, @as(ThreadId, 0) });
        _ = try second.spawn(ProbabilisticCounter.increment, .{ &replay_state, @as(ThreadId, 1) });
        var replay = ReplayScheduler.init(choices);
        try second.run(&replay);

        try std.testing.expectEqual(replay_state.events.len, replay_state.event_count);
        try std.testing.expectEqual(first_state.counter.load(.seq_cst), replay_state.counter.load(.seq_cst));
        try std.testing.expectEqualDeep(first_state.events, replay_state.events);
        try std.testing.expectEqualDeep(first.trace.items, second.trace.items);

        var repeated_state: ProbabilisticCounter = .{};
        var repeated = Runtime.init(std.testing.allocator, std.testing.io, first.seed);
        defer repeated.deinit();
        _ = try repeated.spawn(ProbabilisticCounter.increment, .{ &repeated_state, @as(ThreadId, 0) });
        _ = try repeated.spawn(ProbabilisticCounter.increment, .{ &repeated_state, @as(ThreadId, 1) });
        var repeated_scheduler = RandomScheduler.init(1234);
        try repeated.run(&repeated_scheduler);

        try std.testing.expectEqual(repeated_state.events.len, repeated_state.event_count);
        try std.testing.expectEqual(first_state.counter.load(.seq_cst), repeated_state.counter.load(.seq_cst));
        try std.testing.expectEqualDeep(first_state.events, repeated_state.events);
        try std.testing.expectEqualDeep(first.trace.items, repeated.trace.items);
    }
}

test "runtime seed and thread ID vary the actual probabilistic pause locations" {
    var locations: [2][2][129]usize = undefined;
    var counts = [2][2]usize{ .{ 0, 0 }, .{ 0, 0 } };
    for ([_]u64{ 0, std.math.maxInt(u64) }, 0..) |seed, run_index| {
        var progress = [2]usize{ 0, 0 };
        var runtime = Runtime.init(std.testing.allocator, std.testing.io, seed);
        defer runtime.deinit();
        for (&progress) |*checkpoint| {
            _ = try runtime.spawn(Tasks.probabilisticSteps, .{checkpoint});
        }

        while (runtime.hasWork()) {
            for (runtime.runnable()) |tid| {
                try runtime.step(tid);
                locations[run_index][tid][counts[run_index][tid]] = progress[tid];
                counts[run_index][tid] += 1;
            }
        }
    }

    const first_thread = locations[0][0][0..counts[0][0]];
    const second_thread = locations[0][1][0..counts[0][1]];
    const other_seed = locations[1][0][0..counts[1][0]];
    try std.testing.expect(!std.mem.eql(usize, first_thread, second_thread));
    try std.testing.expect(!std.mem.eql(usize, first_thread, other_seed));
}

test "contexts remain valid when thread storage grows" {
    var counter = Counter.init(0);
    var runtime = Runtime.init(std.testing.allocator, std.testing.io, 42);
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
        var runtime = Runtime.init(std.testing.allocator, std.testing.io, 42);
        defer runtime.deinit();
        _ = try runtime.spawn(Tasks.add, .{ &counter, @as(usize, 100) });
    }
    try std.testing.expectEqual(@as(usize, 0), counter.load(.seq_cst));
    {
        var runtime = Runtime.init(std.testing.allocator, std.testing.io, 42);
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
        var runtime = Runtime.init(std.testing.allocator, std.testing.io, 42);
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
        var runtime = Runtime.init(std.testing.allocator, std.testing.io, 42);
        defer runtime.deinit();
        _ = try runtime.spawn(Tasks.repeat, .{ &counter, @as(usize, 1) });
        var replay = ReplayScheduler.init(&.{0});
        try std.testing.expectError(error.ReplayExhausted, runtime.run(&replay));
    }
    {
        var runtime = Runtime.init(std.testing.allocator, std.testing.io, 42);
        defer runtime.deinit();
        _ = try runtime.spawn(Tasks.add, .{ &counter, @as(usize, 1) });
        var replay = ReplayScheduler.init(&.{ 0, 0 });
        try std.testing.expectError(error.UnusedReplayChoices, runtime.run(&replay));
    }
}

test "empty runtime completes without requesting a scheduling decision" {
    var runtime = Runtime.init(std.testing.allocator, std.testing.io, 42);
    defer runtime.deinit();
    var replay = ReplayScheduler.init(&.{});
    try runtime.run(&replay);
    try std.testing.expect(!runtime.hasWork());
    try std.testing.expectEqual(@as(usize, 0), runtime.trace.items.len);
}

fn allocationScenario(allocator: std.mem.Allocator) !void {
    var counter = Counter.init(0);
    var runtime = Runtime.init(allocator, std.testing.io, 42);
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
