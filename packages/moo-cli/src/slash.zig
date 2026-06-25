//! Shared slash-command composition for agent harness commands.
//!
//! These lines are typed into an agent session exactly as a human would
//! enter them at the prompt, followed by Enter.

const std = @import("std");

pub const Command = enum {
    compact,
    clear,
    goal,

    pub fn parse(name: []const u8) ?Command {
        if (std.mem.eql(u8, name, "compact")) return .compact;
        if (std.mem.eql(u8, name, "clear")) return .clear;
        if (std.mem.eql(u8, name, "goal")) return .goal;
        return null;
    }

    pub fn asStr(self: Command) []const u8 {
        return switch (self) {
            .compact => "compact",
            .clear => "clear",
            .goal => "goal",
        };
    }
};

pub const Options = struct {
    prompt: ?[]const u8 = null,
    clear: bool = false,
};

pub const ComposeError = error{
    PromptRequired,
    PromptNotAllowed,
    ClearNotAllowed,
    InvalidGoal,
};

/// Build the slash line without a trailing newline. Callers append Enter.
pub fn compose(
    alloc: std.mem.Allocator,
    command: Command,
    opts: Options,
) (ComposeError || error{OutOfMemory})![]u8 {
    return switch (command) {
        .compact => blk: {
            if (opts.clear) return ComposeError.ClearNotAllowed;
            if (opts.prompt) |prompt| {
                break :blk try std.fmt.allocPrint(alloc, "/compact {s}", .{prompt});
            }
            break :blk try alloc.dupe(u8, "/compact");
        },
        .clear => blk: {
            if (opts.clear) return ComposeError.ClearNotAllowed;
            if (opts.prompt != null) return ComposeError.PromptNotAllowed;
            break :blk try alloc.dupe(u8, "/clear");
        },
        .goal => blk: {
            if (opts.clear) {
                if (opts.prompt != null) return ComposeError.InvalidGoal;
                break :blk try alloc.dupe(u8, "/goal clear");
            }
            const prompt = opts.prompt orelse return ComposeError.PromptRequired;
            break :blk try std.fmt.allocPrint(alloc, "/goal {s}", .{prompt});
        },
    };
}

test "compose compact" {
    const alloc = std.testing.allocator;
    const bare = try compose(alloc, .compact, .{});
    defer alloc.free(bare);
    try std.testing.expectEqualStrings("/compact", bare);

    const focused = try compose(alloc, .compact, .{ .prompt = "focus on tests" });
    defer alloc.free(focused);
    try std.testing.expectEqualStrings("/compact focus on tests", focused);
}

test "compose clear" {
    const alloc = std.testing.allocator;
    const line = try compose(alloc, .clear, .{});
    defer alloc.free(line);
    try std.testing.expectEqualStrings("/clear", line);
}

test "compose goal" {
    const alloc = std.testing.allocator;
    const set = try compose(alloc, .goal, .{ .prompt = "ship slash commands" });
    defer alloc.free(set);
    try std.testing.expectEqualStrings("/goal ship slash commands", set);

    const cleared = try compose(alloc, .goal, .{ .clear = true });
    defer alloc.free(cleared);
    try std.testing.expectEqualStrings("/goal clear", cleared);
}

test "compose validation" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(ComposeError.ClearNotAllowed, compose(alloc, .clear, .{ .clear = true }));
    try std.testing.expectError(ComposeError.PromptNotAllowed, compose(alloc, .clear, .{ .prompt = "nope" }));
    try std.testing.expectError(ComposeError.PromptRequired, compose(alloc, .goal, .{}));
    try std.testing.expectError(ComposeError.InvalidGoal, compose(alloc, .goal, .{ .prompt = "x", .clear = true }));
}

test "parse command names" {
    try std.testing.expectEqual(Command.compact, Command.parse("compact").?);
    try std.testing.expectEqual(Command.goal, Command.parse("goal").?);
    try std.testing.expect(Command.parse("unknown") == null);
}
