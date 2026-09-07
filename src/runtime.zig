const std = @import("std");
const Context = @import("context.zig").Context;

pub const ThreadId = usize;
pub const TraceEvent = struct {
    tid: ThreadId,
    action: enum { start, unpause },
};

const Task = struct {
    argument: *anyopaque,
    call: *const fn (*anyopaque) void,
    destroy: *const fn (*anyopaque, std.mem.Allocator) void,
};

const ThreadRecord = struct {
    thread: std.Thread,
    ctx: *Context,
    task: Task,
};

pub const Runtime = struct {
    const Self = @This();

    threads: std.ArrayList(ThreadRecord) = .empty,
    trace: std.ArrayList(TraceEvent) = .empty,
    runnable_buffer: std.ArrayList(ThreadId) = .empty,
    allocator: std.mem.Allocator,
    io: std.Io,
    started: bool = false,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Self {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn deinit(self: *Self) void {
        if (self.started) {
            while (self.hasWork()) {
                for (self.threads.items) |record| {
                    const ctx = record.ctx;
                    ctx.mx.lockUncancelable(self.io);
                    if (ctx.state == .Ready or ctx.state == .Paused) advance(ctx);
                    ctx.mx.unlock(self.io);
                }
            }
        }
        for (self.threads.items) |record| {
            const ctx = record.ctx;
            ctx.mx.lockUncancelable(self.io);
            if (ctx.state == .Ready) {
                ctx.state = .Finished;
                ctx.cv.signal(self.io);
            }
            std.debug.assert(ctx.state == .Finished);
            ctx.mx.unlock(self.io);

            record.thread.join();
            record.task.destroy(record.task.argument, self.allocator);
            self.allocator.destroy(ctx);
        }
        self.threads.deinit(self.allocator);
        self.trace.deinit(self.allocator);
        self.runnable_buffer.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn spawn(self: *Self, comptime function: anytype, args: anytype) !ThreadId {
        if (self.started) return error.AlreadyStarted;

        const Payload = struct {
            args: @TypeOf(args),

            fn call(argument: *anyopaque) void {
                const payload: *@This() = @ptrCast(@alignCast(argument));
                @call(.auto, function, payload.args);
            }

            fn destroy(argument: *anyopaque, allocator: std.mem.Allocator) void {
                const payload: *@This() = @ptrCast(@alignCast(argument));
                allocator.destroy(payload);
            }
        };

        try self.threads.ensureUnusedCapacity(self.allocator, 1);
        try self.runnable_buffer.ensureTotalCapacity(self.allocator, self.threads.items.len + 1);

        const ctx = try self.allocator.create(Context);
        errdefer self.allocator.destroy(ctx);
        ctx.* = .init(self.io);

        const payload = try self.allocator.create(Payload);
        errdefer self.allocator.destroy(payload);
        payload.* = .{ .args = args };

        const task: Task = .{
            .argument = payload,
            .call = Payload.call,
            .destroy = Payload.destroy,
        };
        const tid = self.threads.items.len;
        const thread = try std.Thread.spawn(.{}, threadWork, .{ ctx, task });
        self.threads.appendAssumeCapacity(.{ .thread = thread, .ctx = ctx, .task = task });
        return tid;
    }

    pub fn hasWork(self: *Self) bool {
        for (self.threads.items) |record| {
            record.ctx.mx.lockUncancelable(self.io);
            const finished = record.ctx.state == .Finished;
            record.ctx.mx.unlock(self.io);
            if (!finished) return true;
        }
        return false;
    }

    pub fn runnable(self: *Self) []const ThreadId {
        self.runnable_buffer.clearRetainingCapacity();
        for (self.threads.items, 0..) |record, tid| {
            record.ctx.mx.lockUncancelable(self.io);
            const state = record.ctx.state;
            record.ctx.mx.unlock(self.io);
            if (state == .Ready or state == .Paused) {
                self.runnable_buffer.appendAssumeCapacity(tid);
            }
        }
        return self.runnable_buffer.items;
    }

    pub fn step(self: *Self, tid: ThreadId) !void {
        if (tid >= self.threads.items.len) return error.InvalidThreadId;
        const ctx = self.threads.items[tid].ctx;
        ctx.mx.lockUncancelable(self.io);
        defer ctx.mx.unlock(self.io);

        if (ctx.state != .Ready and ctx.state != .Paused) return error.ThreadNotRunnable;
        try self.trace.append(self.allocator, .{
            .tid = tid,
            .action = if (ctx.state == .Ready) .start else .unpause,
        });
        self.started = true;
        advance(ctx);
    }

    pub fn run(self: *Self, scheduler: anytype) !void {
        while (self.hasWork()) {
            const available = self.runnable();
            if (available.len == 0) return error.Deadlock;
            const tid = try scheduler.choose(available);
            try self.step(tid);
        }
        if (@hasDecl(@TypeOf(scheduler.*), "finish")) {
            try scheduler.finish();
        }
    }

    pub fn recordedChoices(self: *const Self, allocator: std.mem.Allocator) ![]ThreadId {
        const choices = try allocator.alloc(ThreadId, self.trace.items.len);
        for (self.trace.items, choices) |event, *tid| tid.* = event.tid;
        return choices;
    }

    pub fn printTrace(self: *const Self) void {
        std.debug.print("begin trace\n", .{});
        for (self.trace.items) |event| {
            std.debug.print("{d}: {s}\n", .{ event.tid, @tagName(event.action) });
        }
    }
};

fn advance(ctx: *Context) void {
    ctx.state = .Running;
    ctx.cv.signal(ctx.io);
    while (ctx.state == .Running) {
        ctx.cv.waitUncancelable(ctx.io, &ctx.mx);
    }
}

fn threadWork(ctx: *Context, task: Task) void {
    Context.setContext(ctx);

    ctx.mx.lockUncancelable(ctx.io);
    while (ctx.state == .Ready) {
        ctx.cv.waitUncancelable(ctx.io, &ctx.mx);
    }
    if (ctx.state == .Finished) {
        ctx.mx.unlock(ctx.io);
        return;
    }
    std.debug.assert(ctx.state == .Running);
    ctx.mx.unlock(ctx.io);

    task.call(task.argument);

    ctx.mx.lockUncancelable(ctx.io);
    defer ctx.mx.unlock(ctx.io);
    std.debug.assert(ctx.state == .Running);
    ctx.state = .Finished;
    ctx.cv.signal(ctx.io);
}
