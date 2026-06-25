//! Permissive pending-input detection for agent harness sessions.
//!
//! Returns null (pass through) unless high-confidence draft text is found.
//! See docs/pending-input-detection-prd.md.

const std = @import("std");
const harness = @import("harness.zig");
const paths = @import("paths.zig");

pub const Peek = struct {
    rows: u32,
    cols: u32,
    cursor_row: u32,
    cursor_col: u32,
    title: []const u8,
    screen: []const u8,
};

pub const PendingInput = struct {
    preview: []u8,
    reason: []const u8,

    pub fn deinit(self: PendingInput, alloc: std.mem.Allocator) void {
        alloc.free(self.preview);
    }
};

pub const GateOpts = struct {
    append_enter: bool = false,
    force: bool = false,
};

pub const SendLedgerUpdate = struct {
    text_without_enter: bool = false,
    sent_text: ?[]const u8 = null,
    sent_enter: bool = false,
};

/// Wire format: rows \t cols \t cur_row \t cur_col \t title on the first line, then screen.
pub fn parsePeek(payload: []const u8) ?Peek {
    const nl = std.mem.indexOfScalar(u8, payload, '\n') orelse return null;
    var rest = payload[0..nl];
    const rows = cutTab(&rest) orelse return null;
    const cols = cutTab(&rest) orelse return null;
    const cur_row = cutTab(&rest) orelse return null;
    const cur_col = cutTab(&rest) orelse return null;
    return .{
        .rows = std.fmt.parseInt(u32, rows, 10) catch return null,
        .cols = std.fmt.parseInt(u32, cols, 10) catch return null,
        .cursor_row = std.fmt.parseInt(u32, cur_row, 10) catch return null,
        .cursor_col = std.fmt.parseInt(u32, cur_col, 10) catch return null,
        .title = rest,
        .screen = payload[nl + 1 ..],
    };
}

fn cutTab(rest: *[]const u8) ?[]const u8 {
    const idx = std.mem.indexOfScalar(u8, rest.*, '\t') orelse return null;
    const field = rest.*[0..idx];
    rest.* = rest.*[idx + 1 ..];
    return field;
}

/// null = permissive pass (no warning).
pub fn detect(
    alloc: std.mem.Allocator,
    agent: harness.Agent,
    peek: ?Peek,
    ledger_draft: ?[]const u8,
) !?PendingInput {
    if (ledger_draft) |draft| {
        if (draft.len > 0) {
            return .{
                .preview = try truncatePreview(alloc, draft),
                .reason = "codex_send_ledger",
            };
        }
    }
    const p = peek orelse return null;
    return switch (agent) {
        .claude => detectClaude(alloc, p),
        .pi => detectPi(alloc, p),
        .codex => null,
        .raw, .bash, .zsh => null,
    };
}

/// Returns owned PendingInput when send should be blocked; null to proceed.
pub fn gate(
    alloc: std.mem.Allocator,
    agent: ?harness.Agent,
    peek: ?Peek,
    ledger_draft: ?[]const u8,
    opts: GateOpts,
) !?PendingInput {
    if (opts.force or !opts.append_enter) return null;
    const a = agent orelse return null;
    if (!a.hasTranscript()) return null;
    return detect(alloc, a, peek, ledger_draft);
}

// --- Send ledger (Codex and cross-check) ------------------------------------

pub fn loadLedgerDraft(alloc: std.mem.Allocator, dir: []const u8, name: []const u8) !?[]u8 {
    const path = try paths.sendLedgerPath(alloc, dir, name);
    defer alloc.free(path);
    const data = std.fs.cwd().readFileAlloc(alloc, path, 4096) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer alloc.free(data);
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, data, .{}) catch return null;
    defer parsed.deinit();
    const draft = jsonStr(parsed.value, "draft") orelse return null;
    if (draft.len == 0) return null;
    return try alloc.dupe(u8, draft);
}

pub fn updateLedger(
    alloc: std.mem.Allocator,
    dir: []const u8,
    name: []const u8,
    update: SendLedgerUpdate,
) void {
    const path = paths.sendLedgerPath(alloc, dir, name) catch return;
    defer alloc.free(path);

    if (update.sent_enter) {
        std.fs.cwd().deleteFile(path) catch {};
        return;
    }
    if (update.text_without_enter) {
        const text = update.sent_text orelse return;
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(alloc);
        out.appendSlice(alloc, "{\"draft\":") catch return;
        appendJsonStr(alloc, &out, text) catch return;
        out.appendSlice(alloc, "}\n") catch return;
        std.fs.cwd().writeFile(.{ .sub_path = path, .data = out.items }) catch {};
    }
}

fn jsonStr(root: std.json.Value, key: []const u8) ?[]const u8 {
    if (root != .object) return null;
    const v = root.object.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn appendJsonStr(alloc: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    try out.append(alloc, '"');
    for (s) |c| switch (c) {
        '"' => try out.appendSlice(alloc, "\\\""),
        '\\' => try out.appendSlice(alloc, "\\\\"),
        '\n' => try out.appendSlice(alloc, "\\n"),
        '\r' => try out.appendSlice(alloc, "\\r"),
        '\t' => try out.appendSlice(alloc, "\\t"),
        else => try out.append(alloc, c),
    };
    try out.append(alloc, '"');
}

fn truncatePreview(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    const max_len = 120;
    if (text.len <= max_len) return try alloc.dupe(u8, text);
    return try std.fmt.allocPrint(alloc, "{s}…", .{text[0..max_len]});
}

// --- Layout helpers ---------------------------------------------------------

fn screenLines(alloc: std.mem.Allocator, screen: []const u8) ![]const []const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    errdefer lines.deinit(alloc);
    var it = std.mem.splitScalar(u8, screen, '\n');
    while (it.next()) |line| try lines.append(alloc, line);
    return try lines.toOwnedSlice(alloc);
}

fn isSeparatorLineStrict(line: []const u8) bool {
    if (line.len < 4) return false;
    var box: usize = 0;
    var i: usize = 0;
    while (i < line.len) {
        const c = line[i];
        if (c == ' ' or c == '\t') {
            i += 1;
            continue;
        }
        if (c == 0xe2 and i + 2 < line.len) {
            const b = line[i + 1];
            const d = line[i + 2];
            if (b == 0x94 and d == 0x80) box += 1; // ─
            if (b == 0x94 and d == 0x81) box += 1; // ━
            if (b == 0x95 and d == 0x90) box += 1; // ═
            if (b == 0x94 and d == 0x8c) box += 1; // ┌
            if (b == 0x94 and d == 0x90) box += 1; // ┐
            if (b == 0x94 and d == 0x98) box += 1; // └
            if (b == 0x94 and d == 0x9c) box += 1; // ├
            if (b == 0x94 and d == 0xa4) box += 1; // ┤
            i += 3;
            continue;
        }
        if (c == '-' or c == '=' or c == '_') {
            box += 1;
            i += 1;
            continue;
        }
        return false;
    }
    return box >= 4;
}

fn trimPromptSpaces(text: []const u8) []const u8 {
    var start: usize = 0;
    var end = text.len;
    while (start < end) {
        const c = text[start];
        if (c == ' ' or c == '\t' or c == 0xc2) {
            if (c == 0xc2 and start + 1 < end and text[start + 1] == 0xa0) {
                start += 2;
                continue;
            }
            if (c == ' ' or c == '\t') {
                start += 1;
                continue;
            }
        }
        break;
    }
    while (end > start) {
        const c = text[end - 1];
        if (c == ' ' or c == '\t') {
            end -= 1;
            continue;
        }
        if (end >= start + 2 and text[end - 2] == 0xc2 and text[end - 1] == 0xa0) {
            end -= 2;
            continue;
        }
        break;
    }
    return text[start..end];
}

// --- Claude -----------------------------------------------------------------

const claude_prompt_prefix = "\u{276F}";

fn detectClaude(alloc: std.mem.Allocator, peek: Peek) !?PendingInput {
    const lines = try screenLines(alloc, peek.screen);
    defer alloc.free(lines);
    if (lines.len == 0) return null;

    var lower_sep_idx: ?usize = null;
    var i: usize = lines.len;
    while (i > 0) {
        i -= 1;
        if (isSeparatorLineStrict(lines[i])) {
            lower_sep_idx = i;
            break;
        }
    }
    const lower = lower_sep_idx orelse return null;
    if (lower == 0) return null;

    var upper_sep_idx: ?usize = null;
    var j = lower;
    while (j > 0) {
        j -= 1;
        if (isSeparatorLineStrict(lines[j])) {
            upper_sep_idx = j;
            break;
        }
    }
    const upper = upper_sep_idx orelse return null;

    const zone_start = upper + 1;
    const zone_end = lower;
    if (zone_start >= zone_end) return null;

    const first = lines[zone_start];
    if (!startsWithClaudePrompt(first)) return null;

    var draft = std.ArrayList(u8).empty;
    defer draft.deinit(alloc);

    for (lines[zone_start..zone_end]) |line| {
        if (startsWithClaudePrompt(line)) {
            const rest = claudePromptRest(line);
            if (rest.len > 0) try draft.appendSlice(alloc, rest);
        } else if (line.len >= 2 and line[0] == ' ' and line[1] == ' ') {
            const cont = trimPromptSpaces(line[2..]);
            if (cont.len > 0) {
                if (draft.items.len > 0) try draft.append(alloc, ' ');
                try draft.appendSlice(alloc, cont);
            }
        } else if (trimPromptSpaces(line).len > 0) {
            return null;
        }
    }

    const trimmed = trimPromptSpaces(draft.items);
    if (trimmed.len == 0) return null;
    return .{
        .preview = try truncatePreview(alloc, trimmed),
        .reason = "claude_prompt_zone_nonempty",
    };
}

fn startsWithClaudePrompt(line: []const u8) bool {
    if (line.len < claude_prompt_prefix.len) return false;
    if (!std.mem.startsWith(u8, line, claude_prompt_prefix)) return false;
    return true;
}

fn claudePromptRest(line: []const u8) []const u8 {
    var rest = line[claude_prompt_prefix.len..];
    rest = trimPromptSpaces(rest);
    return rest;
}

// --- Pi ---------------------------------------------------------------------

fn detectPi(alloc: std.mem.Allocator, peek: Peek) !?PendingInput {
    const lines = try screenLines(alloc, peek.screen);
    defer alloc.free(lines);
    if (lines.len < 4) return null;

    // Slash autocomplete overlay — not the editor.
    for (lines) |line| {
        if (std.mem.indexOf(u8, line, "\xE2\x86\x92") != null) return null;
    }

    var cwd_idx: ?usize = null;
    var k: usize = lines.len;
    while (k > 0) {
        k -= 1;
        const line = lines[k];
        if (line.len >= 2 and (line[0] == '~' or std.mem.startsWith(u8, line, "~/"))) {
            cwd_idx = k;
            break;
        }
    }
    const cwd_line = cwd_idx orelse return null;
    if (cwd_line == 0) return null;

    // Walk up from cwd: optional stats line, bottom border, content, top border.
    var bottom_border: ?usize = null;
    var idx = cwd_line;
    while (idx > 0) {
        idx -= 1;
        if (isSeparatorLineStrict(lines[idx])) {
            bottom_border = idx;
            break;
        }
    }
    const bottom = bottom_border orelse return null;
    if (bottom == 0) return null;

    var top_border: ?usize = null;
    var t = bottom;
    while (t > 0) {
        t -= 1;
        if (isSeparatorLineStrict(lines[t])) {
            top_border = t;
            break;
        }
    }
    const top = top_border orelse return null;
    if (top + 1 >= bottom) return null;

    var draft = std.ArrayList(u8).empty;
    defer draft.deinit(alloc);
    for (lines[top + 1 .. bottom]) |line| {
        const content = trimPromptSpaces(line);
        if (content.len > 0) {
            if (draft.items.len > 0) try draft.append(alloc, ' ');
            try draft.appendSlice(alloc, content);
        }
    }
    if (draft.items.len == 0) return null;
    return .{
        .preview = try truncatePreview(alloc, draft.items),
        .reason = "pi_editor_zone_nonempty",
    };
}

// --- Tests ------------------------------------------------------------------

test "parse peek wire format" {
    const payload = "24\t80\t10\t3\tmy title\nline one\nline two\n";
    const peek = parsePeek(payload).?;
    try std.testing.expectEqual(@as(u32, 24), peek.rows);
    try std.testing.expectEqual(@as(u32, 80), peek.cols);
    try std.testing.expectEqual(@as(u32, 10), peek.cursor_row);
    try std.testing.expectEqual(@as(u32, 3), peek.cursor_col);
    try std.testing.expectEqualStrings("my title", peek.title);
    try std.testing.expect(std.mem.indexOf(u8, peek.screen, "line one") != null);
}

test "claude empty prompt passes" {
    const screen = @embedFile("testdata/peek/claude-idle-empty.txt");
    const peek = Peek{ .rows = 52, .cols = 94, .cursor_row = 49, .cursor_col = 3, .title = "", .screen = screen };
    const alloc = std.testing.allocator;
    const pending = try detectClaude(alloc, peek);
    try std.testing.expect(pending == null);
}

test "claude draft blocks" {
    const screen = @embedFile("testdata/peek/claude-pending-draft.txt");
    const peek = Peek{ .rows = 52, .cols = 94, .cursor_row = 49, .cursor_col = 41, .title = "", .screen = screen };
    const alloc = std.testing.allocator;
    const pending = try detectClaude(alloc, peek);
    try std.testing.expect(pending != null);
    defer pending.?.deinit(alloc);
    try std.testing.expect(std.mem.indexOf(u8, pending.?.preview, "draft probe") != null);
}

test "claude without prompt box passes" {
    const screen = "just some output\nno prompt sandwich\n";
    const peek = Peek{ .rows = 3, .cols = 40, .cursor_row = 2, .cursor_col = 1, .title = "", .screen = screen };
    const pending = try detectClaude(std.testing.allocator, peek);
    try std.testing.expect(pending == null);
}

test "pi empty editor passes" {
    const screen = @embedFile("testdata/peek/pi-idle-empty.txt");
    const peek = Peek{ .rows = 6, .cols = 80, .cursor_row = 3, .cursor_col = 1, .title = "", .screen = screen };
    const pending = try detectPi(std.testing.allocator, peek);
    try std.testing.expect(pending == null);
}

test "pi draft blocks" {
    const screen = @embedFile("testdata/peek/pi-pending-draft.txt");
    const peek = Peek{ .rows = 6, .cols = 80, .cursor_row = 3, .cursor_col = 34, .title = "", .screen = screen };
    const alloc = std.testing.allocator;
    const pending = try detectPi(alloc, peek);
    try std.testing.expect(pending != null);
    defer pending.?.deinit(alloc);
    try std.testing.expect(std.mem.indexOf(u8, pending.?.preview, "draft probe") != null);
}

test "codex ledger blocks" {
    const alloc = std.testing.allocator;
    const pending = try detect(alloc, .codex, null, "hello from ledger");
    try std.testing.expect(pending != null);
    defer pending.?.deinit(alloc);
    try std.testing.expectEqualStrings("codex_send_ledger", pending.?.reason);
}

test "gate respects force and append_enter" {
    const alloc = std.testing.allocator;
    const screen = @embedFile("testdata/peek/claude-pending-draft.txt");
    const peek = Peek{ .rows = 52, .cols = 94, .cursor_row = 49, .cursor_col = 41, .title = "", .screen = screen };
    const blocked = try gate(alloc, .claude, peek, null, .{ .append_enter = true, .force = false });
    try std.testing.expect(blocked != null);
    if (blocked) |pending| pending.deinit(alloc);
    try std.testing.expect(try gate(alloc, .claude, peek, null, .{ .append_enter = true, .force = true }) == null);
    try std.testing.expect(try gate(alloc, .claude, peek, null, .{ .append_enter = false, .force = false }) == null);
}
