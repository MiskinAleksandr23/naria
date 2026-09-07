const std = @import("std");

pub fn Spsc(comptime T: type) type {
    return struct {
        const Self = @This();
        const Node = struct {
            value: T = undefined,
            next: std.atomic.Value(?*Node) = .init(null),
        };

        allocator: std.mem.Allocator,
        head: *Node,
        tail: *Node,
        closed: std.atomic.Value(bool) = .init(false),

        pub fn init(allocator: std.mem.Allocator) std.mem.Allocator.Error!*Self {
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);
            const dummy = try allocator.create(Node);
            dummy.* = .{};
            self.* = .{ .allocator = allocator, .head = dummy, .tail = dummy };
            return self;
        }

        pub fn deinit(self: *Self) void {
            var node: ?*Node = self.head;
            while (node) |current| {
                node = current.next.load(.seq_cst);
                self.allocator.destroy(current);
            }
            self.allocator.destroy(self);
        }

        pub fn push(self: *Self, value: T) error{ OutOfMemory, Closed }!void {
            if (self.isClosed()) return error.Closed;

            const node = try self.allocator.create(Node);
            node.* = .{ .value = value };
            self.tail.next.store(node, .seq_cst);
            self.tail = node;
        }

        pub fn pop(self: *Self) error{ Empty, Closed }!T {
            const closed = self.isClosed();
            const head = self.head;
            const next = head.next.load(.seq_cst) orelse {
                return if (closed) error.Closed else error.Empty;
            };

            const value = next.value;
            self.head = next;
            self.allocator.destroy(head);
            return value;
        }

        pub fn close(self: *Self) void {
            self.closed.store(true, .seq_cst);
        }

        pub fn isClosed(self: *const Self) bool {
            return self.closed.load(.seq_cst);
        }
    };
}
