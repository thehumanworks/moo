//! Prefix-key (C-a) input processing, GNU screen style.
//!
//! Raw client input is scanned for the escape byte. Bytes that are not
//! part of a command pass through to the active window unchanged.

const std = @import("std");

pub const escape_byte: u8 = 0x01; // C-a

pub const Command = union(enum) {
    /// Bytes to forward to the active window.
    forward: []const u8,
    new_window,
    next_window,
    prev_window,
    other_window,
    select_window: u4,
    detach,
    kill_window,
    list_windows,
    redraw,
    unknown: u8,
};

pub const Parser = struct {
    /// Whether the previous byte ended inside a prefix sequence.
    pending: bool = false,

    /// Process a chunk of input. Calls handler.command(cmd) for every
    /// command, including .forward runs of passthrough bytes. The handler
    /// must consume forwarded slices immediately (they alias `input`).
    pub fn feed(self: *Parser, input: []const u8, handler: anytype) !void {
        var start: usize = 0;
        var i: usize = 0;
        while (i < input.len) {
            if (self.pending) {
                self.pending = false;
                const byte = input[i];
                i += 1;
                start = i;
                switch (byte) {
                    'c' => try handler.command(.new_window),
                    'n', ' ' => try handler.command(.next_window),
                    'p' => try handler.command(.prev_window),
                    escape_byte => try handler.command(.other_window),
                    '0'...'9' => try handler.command(.{ .select_window = @intCast(byte - '0') }),
                    'd' => try handler.command(.detach),
                    'k' => try handler.command(.kill_window),
                    'w' => try handler.command(.list_windows),
                    'l' => try handler.command(.redraw),
                    'a' => try handler.command(.{ .forward = &.{escape_byte} }),
                    else => try handler.command(.{ .unknown = byte }),
                }
                continue;
            }

            if (input[i] == escape_byte) {
                if (i > start) try handler.command(.{ .forward = input[start..i] });
                self.pending = true;
                i += 1;
                start = i;
                continue;
            }

            i += 1;
        }

        if (i > start and !self.pending) {
            try handler.command(.{ .forward = input[start..i] });
        }
    }
};

const TestHandler = struct {
    alloc: std.mem.Allocator,
    cmds: std.ArrayList(Command) = .empty,
    forwarded: std.ArrayList(u8) = .empty,

    fn deinit(self: *TestHandler) void {
        self.cmds.deinit(self.alloc);
        self.forwarded.deinit(self.alloc);
    }

    fn command(self: *TestHandler, cmd: Command) !void {
        switch (cmd) {
            .forward => |bytes| try self.forwarded.appendSlice(self.alloc, bytes),
            else => try self.cmds.append(self.alloc, cmd),
        }
    }
};

test "plain bytes pass through" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: Parser = .{};
    try p.feed("hello world", &h);
    try std.testing.expectEqualStrings("hello world", h.forwarded.items);
    try std.testing.expectEqual(@as(usize, 0), h.cmds.items.len);
}

test "prefix commands" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: Parser = .{};
    try p.feed("ab\x01cde\x013f", &h);
    try std.testing.expectEqualStrings("abdef", h.forwarded.items);
    try std.testing.expectEqual(@as(usize, 2), h.cmds.items.len);
    try std.testing.expectEqual(Command.new_window, h.cmds.items[0]);
    try std.testing.expectEqual(Command{ .select_window = 3 }, h.cmds.items[1]);
}

test "literal escape via C-a a and C-a C-a toggles" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: Parser = .{};
    try p.feed("\x01a\x01\x01", &h);
    try std.testing.expectEqualStrings("\x01", h.forwarded.items);
    try std.testing.expectEqual(@as(usize, 1), h.cmds.items.len);
    try std.testing.expectEqual(Command.other_window, h.cmds.items[0]);
}

test "prefix split across feeds" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: Parser = .{};
    try p.feed("xy\x01", &h);
    try std.testing.expectEqualStrings("xy", h.forwarded.items);
    try std.testing.expectEqual(@as(usize, 0), h.cmds.items.len);
    try p.feed("d", &h);
    try std.testing.expectEqual(@as(usize, 1), h.cmds.items.len);
    try std.testing.expectEqual(Command.detach, h.cmds.items[0]);
}

test "unknown command reported" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: Parser = .{};
    try p.feed("\x01z", &h);
    try std.testing.expectEqual(Command{ .unknown = 'z' }, h.cmds.items[0]);
}
