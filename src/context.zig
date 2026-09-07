const std = @import("std");
const Io = std.Io;

pub const State = enum {
    Ready,
    Running,
    Paused,
    Finished,
};

threadlocal var localContext: ?*Context = null;

pub const Context = struct {
    const Self = @This();
    io: Io,

    mx: Io.Mutex,
    cv: Io.Condition,

    state: State,

    pub fn setContext(ctx: *Context) void {
        std.debug.assert(localContext == null);
        localContext = ctx;
    }
    pub fn getContext() ?*Context {
        return localContext;
    }

    pub fn init(io: Io) Self {
        return Self{
            .mx = .init,
            .cv = .init,
            .state = .Ready,
            .io = io,
        };
    }

    pub fn pause(self: *Self) void {
        self.mx.lockUncancelable(self.io);
        defer self.mx.unlock(self.io);

        std.debug.assert(self.state == .Running);
        self.state = .Paused;

        self.cv.signal(self.io);

        while (self.state != .Running) {
            self.cv.waitUncancelable(self.io, &self.mx);
        }
    }
};

pub fn pause() void {
    if (Context.getContext()) |ctx| {
        ctx.pause();
    }
}
