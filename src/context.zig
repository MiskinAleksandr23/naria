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
    prgn: std.Random.DefaultPrng,

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
            .prgn = .init(42),
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
    fn chance(random: std.Random, p: f64) bool {
        return random.float(f64) < std.math.clamp(p, 0.0, 1.0);
    }
    pub fn pauseWithProbability(self: *Self, p: f64) void {
        if (chance(self.prgn.random(), p)) {
            self.pause();
        }
    }
};

pub fn pause() void {
    if (Context.getContext()) |ctx| {
        ctx.pause();
    }
}

pub fn pauseWithProbability(p: f64) void {
    if (Context.getContext()) |ctx| {
        ctx.pauseWithProbability(p);
    }
}
