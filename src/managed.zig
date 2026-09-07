const std = @import("std");
const Context = @import("context.zig").Context;
const State = @import("context.zig").State;
const Spsc = @import("spsc.zig").Spsc;

pub fn ManagedHandle(T: type) type {
    return struct {
        const Self = @This();
        const funcType = *const fn (*T) void;

        ctx: *Context,
        inner: std.Thread,
        allocator: std.mem.Allocator,
        sender: *Spsc(funcType),

        pub fn init(ctx: *Context, sender: *Spsc(funcType), inner: std.Thread, allocator: std.mem.Allocator) Self {
            return Self{
                .ctx = ctx,
                .inner = inner,
                .allocator = allocator,
                .sender = sender,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.destroy(self.ctx);
            self.sender.deinit();
        }

        pub fn isPaused(self: *Self) bool {
            self.ctx.mx.lockUncancelable(self.ctx.io);
            defer self.ctx.mx.unlock(self.ctx.io);

            return self.ctx.state == .Paused;
        }

        pub fn unpause(self: *Self) void {
            self.ctx.mx.lockUncancelable(self.ctx.io);
            defer self.ctx.mx.unlock(self.ctx.io);

            std.debug.assert(self.ctx.state == .Paused);
            self.ctx.state = .Running;

            self.ctx.cv.signal(self.ctx.io);

            while (self.ctx.state == .Running) {
                self.ctx.cv.waitUncancelable(self.ctx.io, &self.ctx.mx);
            }
        }

        pub fn join(self: *Self) void {
            while (self.isPaused()) {
                self.unpause();
            }
            self.sender.close();
            self.inner.join();
        }

        pub fn submit(self: *Self, func: *const fn (*T) void) !void {
            self.ctx.mx.lockUncancelable(self.ctx.io);
            defer self.ctx.mx.unlock(self.ctx.io);

            std.debug.assert(self.ctx.state == .Ready);

            self.ctx.state = .Running;

            std.debug.assert(!self.sender.isClosed());
            try self.sender.push(func);

            while (self.ctx.state == .Running) {
                self.ctx.cv.waitUncancelable(self.ctx.io, &self.ctx.mx);
            }
        }
    };
}

fn threadWork(comptime T: type, ctx: *Context, receiver: *Spsc(*const fn (*T) void), internalState: *T, id: usize) !void {
    Context.setContext(ctx);
    Context.setThreadId(id);
    while (true) {
        if (receiver.pop()) |func| {
            func(internalState);
            ctx.mx.lockUncancelable(ctx.io);
            defer ctx.mx.unlock(ctx.io);

            std.debug.assert(ctx.state == .Running);
            ctx.state = .Ready;

            ctx.cv.signal(ctx.io);
        } else |err| {
            switch (err) {
                error.Empty => continue,
                error.Closed => break,
            }
        }
    }
}

pub fn spawn(comptime T: type, io: std.Io, allocator: std.mem.Allocator, state: *T, id: usize) !ManagedHandle(T) {
    const ctx = try allocator.create(Context);
    ctx.* = .init(io);

    const sender = try Spsc(*const fn (*T) void).init(allocator);
    const receiver = sender;

    const inner = try std.Thread.spawn(.{}, threadWork, .{ T, ctx, receiver, state, id });

    return ManagedHandle(T){
        .ctx = ctx,
        .inner = inner,
        .allocator = allocator,
        .sender = sender,
    };
}
