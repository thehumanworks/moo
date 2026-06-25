//! Session naming and socket directory resolution.

const std = @import("std");

pub const max_name_len = 64;

pub const NameError = error{InvalidSessionName};

/// Session names become file names, so restrict them to a safe set.
pub fn validateName(name: []const u8) NameError!void {
    if (name.len == 0 or name.len > max_name_len) return error.InvalidSessionName;
    for (name) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '.', '_', '-' => {},
        else => return error.InvalidSessionName,
    };
    // Avoid names that look like path traversal or hidden files.
    if (name[0] == '.' or name[0] == '-') return error.InvalidSessionName;
}

/// Resolve the runtime directory that holds session sockets:
/// $MOO_DIR, else $XDG_RUNTIME_DIR/moo, else /tmp/moo-<uid>.
/// The directory is created with mode 0700.
pub fn socketDir(alloc: std.mem.Allocator) ![]u8 {
    return socketDirFrom(
        alloc,
        std.posix.getenv("MOO_DIR"),
        std.posix.getenv("XDG_RUNTIME_DIR"),
    );
}

/// The XDG runtime directory is created by the login session, never by
/// applications. When $XDG_RUNTIME_DIR names a directory that does not
/// exist (common on macOS, where dotfiles shared with Linux export a
/// /run/user/<uid> path), creating it would mean writing to system
/// directories: mkdir /run on the sealed macOS system volume fails with
/// error.ReadOnlyFileSystem. Honor the variable only when the directory
/// exists and the moo subdirectory is creatable inside it; otherwise
/// fall back to /tmp/moo-<uid>. $MOO_DIR is an explicit override, so
/// errors there stay fatal rather than being silently redirected.
fn socketDirFrom(
    alloc: std.mem.Allocator,
    boo_dir: ?[]const u8,
    runtime_dir: ?[]const u8,
) ![]u8 {
    if (boo_dir) |d| {
        if (d.len > 0) {
            const dir = try alloc.dupe(u8, d);
            errdefer alloc.free(dir);
            try ensureDir(dir);
            return dir;
        }
    }
    if (runtime_dir) |d| usable: {
        if (d.len == 0) break :usable;
        var parent = std.fs.cwd().openDir(d, .{}) catch break :usable;
        parent.close();
        const dir = try std.fs.path.join(alloc, &.{ d, "moo" });
        ensureDir(dir) catch {
            alloc.free(dir);
            break :usable;
        };
        return dir;
    }
    const dir = try std.fmt.allocPrint(alloc, "/tmp/moo-{d}", .{std.c.getuid()});
    errdefer alloc.free(dir);
    try ensureDir(dir);
    return dir;
}

/// Resolve the active workspace from the `-w/--workspace` flag and the
/// `MOO_WORKSPACE` environment value. The flag wins; otherwise the env value is
/// used unless it is empty, which (like an exported-but-blank variable) means no
/// workspace. Validation of the resulting name is left to socketDirFor.
pub fn resolveWorkspace(flag: ?[]const u8, env: ?[]const u8) ?[]const u8 {
    if (flag) |f| return f;
    if (env) |e| {
        if (e.len == 0) return null;
        return e;
    }
    return null;
}

/// Like socketDir, but namespaces sessions under "<base>/ws/<workspace>" when a
/// workspace is active. With no workspace the result is the plain base dir.
pub fn socketDirFor(alloc: std.mem.Allocator, workspace: ?[]const u8) ![]u8 {
    return socketDirFromFor(
        alloc,
        std.posix.getenv("MOO_DIR"),
        std.posix.getenv("XDG_RUNTIME_DIR"),
        workspace,
    );
}

fn socketDirFromFor(
    alloc: std.mem.Allocator,
    boo_dir: ?[]const u8,
    runtime_dir: ?[]const u8,
    workspace: ?[]const u8,
) ![]u8 {
    const ws = workspace orelse return socketDirFrom(alloc, boo_dir, runtime_dir);
    // Validate before resolving so a bad name creates nothing, not even ws/.
    try validateName(ws);

    const base = try socketDirFrom(alloc, boo_dir, runtime_dir);
    defer alloc.free(base);

    const dir = try std.fs.path.join(alloc, &.{ base, "ws", ws });
    errdefer alloc.free(dir);
    try ensureDir(dir);
    return dir;
}

fn ensureDir(dir: []const u8) !void {
    std.fs.cwd().makePath(dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    // Best effort: sockets must not be reachable by other users.
    std.posix.fchmodat(std.posix.AT.FDCWD, dir, 0o700, 0) catch {};
}

pub fn socketPath(alloc: std.mem.Allocator, dir: []const u8, name: []const u8) ![]u8 {
    const file = try std.fmt.allocPrint(alloc, "{s}.sock", .{name});
    defer alloc.free(file);
    return std.fs.path.join(alloc, &.{ dir, file });
}

/// Per-workspace persistent UI manager socket. The basename is an invalid
/// session name (leading dot), so listSessions naturally ignores it.
pub fn uiManagerSocketPath(alloc: std.mem.Allocator, dir: []const u8) ![]u8 {
    return std.fs.path.join(alloc, &.{ dir, ".moo-ui.sock" });
}

/// Per-workspace persistent UI manager identity sidecar. Tests use this to
/// prove reconnect hit the same manager instead of a fresh auto-selected UI.
pub fn uiManagerIdPath(alloc: std.mem.Allocator, dir: []const u8) ![]u8 {
    return std.fs.path.join(alloc, &.{ dir, ".moo-ui.id" });
}

/// Per-session agent sidecar: "<dir>/<name>.agent" (a JSON file recording the
/// harness, session id, and transcript store). Lives beside the socket but is
/// invisible to listSessions, which only matches "*.sock".
pub fn sidecarPath(alloc: std.mem.Allocator, dir: []const u8, name: []const u8) ![]u8 {
    const file = try std.fmt.allocPrint(alloc, "{s}.agent", .{name});
    defer alloc.free(file);
    return std.fs.path.join(alloc, &.{ dir, file });
}

/// Per-session launch metadata for all sessions: "<dir>/<name>.session".
/// Records cheap, non-agent-specific context such as launch cwd and start time.
pub fn sessionMetaPath(alloc: std.mem.Allocator, dir: []const u8, name: []const u8) ![]u8 {
    const file = try std.fmt.allocPrint(alloc, "{s}.session", .{name});
    defer alloc.free(file);
    return std.fs.path.join(alloc, &.{ dir, file });
}

/// Append-only per-session agent run history: "<dir>/<name>.agents.jsonl".
pub fn runHistoryPath(alloc: std.mem.Allocator, dir: []const u8, name: []const u8) ![]u8 {
    const file = try std.fmt.allocPrint(alloc, "{s}.agents.jsonl", .{name});
    defer alloc.free(file);
    return std.fs.path.join(alloc, &.{ dir, file });
}

/// Per-session send ledger for draft text moo injected without Enter (Codex etc.).
pub fn sendLedgerPath(alloc: std.mem.Allocator, dir: []const u8, name: []const u8) ![]u8 {
    const file = try std.fmt.allocPrint(alloc, "{s}.send-ledger", .{name});
    defer alloc.free(file);
    return std.fs.path.join(alloc, &.{ dir, file });
}

/// Per-session transcript store: "<dir>/<name>.store" (an isolated directory for
/// agents that need one, e.g. codex's CODEX_HOME or pi's --session-dir).
pub fn storeDir(alloc: std.mem.Allocator, dir: []const u8, name: []const u8) ![]u8 {
    const sub = try std.fmt.allocPrint(alloc, "{s}.store", .{name});
    defer alloc.free(sub);
    return std.fs.path.join(alloc, &.{ dir, sub });
}

pub const WorkspaceConfigError = error{
    InvalidWorkspaceCwd,
};

pub const WorkspaceConfig = struct {
    cwd: ?[]u8 = null,

    pub fn deinit(self: *WorkspaceConfig, alloc: std.mem.Allocator) void {
        if (self.cwd) |c| alloc.free(c);
        self.cwd = null;
    }
};

/// Per-workspace metadata: "<dir>/.workspace.json" (optional cwd and future fields).
pub fn workspaceConfigPath(alloc: std.mem.Allocator, dir: []const u8) ![]u8 {
    return std.fs.path.join(alloc, &.{ dir, ".workspace.json" });
}

/// Resolve and validate a workspace cwd: must exist, be a directory, and is stored
/// as an absolute path via realpath.
pub fn validateWorkspaceCwd(alloc: std.mem.Allocator, path: []const u8) WorkspaceConfigError![]u8 {
    var dir = std.fs.cwd().openDir(path, .{}) catch return error.InvalidWorkspaceCwd;
    defer dir.close();
    return dir.realpathAlloc(alloc, ".") catch return error.InvalidWorkspaceCwd;
}

pub fn readWorkspaceConfig(alloc: std.mem.Allocator, dir: []const u8) !WorkspaceConfig {
    const path = try workspaceConfigPath(alloc, dir);
    defer alloc.free(path);
    const data = std.fs.cwd().readFileAlloc(alloc, path, 4096) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer alloc.free(data);

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, data, .{}) catch return .{};
    defer parsed.deinit();
    if (parsed.value != .object) return .{};
    const cwd_val = parsed.value.object.get("cwd") orelse return .{};
    const cwd_raw = switch (cwd_val) {
        .string => |s| s,
        else => return .{},
    };
    if (cwd_raw.len == 0) return .{};
    const cwd = validateWorkspaceCwd(alloc, cwd_raw) catch return .{};
    return .{ .cwd = cwd };
}

pub fn writeWorkspaceConfig(alloc: std.mem.Allocator, dir: []const u8, cwd: []const u8) !void {
    const abs = try validateWorkspaceCwd(alloc, cwd);
    defer alloc.free(abs);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"cwd\":");
    try appendJsonString(alloc, &out, abs);
    try out.appendSlice(alloc, "}\n");

    const path = try workspaceConfigPath(alloc, dir);
    defer alloc.free(path);
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = out.items });
}

fn appendJsonString(alloc: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    try out.append(alloc, '"');
    for (s) |c| switch (c) {
        '"', '\\' => {
            try out.append(alloc, '\\');
            try out.append(alloc, c);
        },
        '\n' => try out.appendSlice(alloc, "\\n"),
        '\r' => try out.appendSlice(alloc, "\\r"),
        '\t' => try out.appendSlice(alloc, "\\t"),
        else => try out.append(alloc, c),
    };
    try out.append(alloc, '"');
}

/// Cwd for new sessions in a workspace: configured workspace cwd when set,
/// otherwise the creating process's current directory.
pub fn resolveSessionCwd(alloc: std.mem.Allocator, workspace_dir: []const u8) ![]u8 {
    var config = readWorkspaceConfig(alloc, workspace_dir) catch return try processCwd(alloc);
    defer config.deinit(alloc);
    if (config.cwd) |cwd| return try alloc.dupe(u8, cwd);
    return try processCwd(alloc);
}

fn processCwd(alloc: std.mem.Allocator) ![]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = std.posix.getcwd(&buf) catch return try alloc.dupe(u8, ".");
    return try alloc.dupe(u8, cwd);
}

/// Best-effort removal of a session's agent sidecar and transcript store. The
/// socket itself is owned by the daemon and removed on quit, so it is left
/// alone here.
pub fn removeAgentFiles(alloc: std.mem.Allocator, dir: []const u8, name: []const u8) void {
    if (sidecarPath(alloc, dir, name)) |sc| {
        defer alloc.free(sc);
        std.fs.cwd().deleteFile(sc) catch {};
    } else |_| {}
    if (sessionMetaPath(alloc, dir, name)) |meta| {
        defer alloc.free(meta);
        std.fs.cwd().deleteFile(meta) catch {};
    } else |_| {}
    if (runHistoryPath(alloc, dir, name)) |hist| {
        defer alloc.free(hist);
        std.fs.cwd().deleteFile(hist) catch {};
    } else |_| {}
    if (storeDir(alloc, dir, name)) |store| {
        defer alloc.free(store);
        std.fs.cwd().deleteTree(store) catch {};
    } else |_| {}
    if (sendLedgerPath(alloc, dir, name)) |ledger| {
        defer alloc.free(ledger);
        std.fs.cwd().deleteFile(ledger) catch {};
    } else |_| {}
}

/// Map an arbitrary string onto the session-name character set: bytes
/// outside the allowed set become '-' and overlong input is truncated.
/// Returns null when the result still fails validation, e.g. empty input
/// or a leading '.' or '-'.
fn sanitizeName(buf: []u8, base: []const u8) ?[]const u8 {
    const len = @min(base.len, @min(buf.len, max_name_len));
    if (len == 0) return null;
    for (base[0..len], buf[0..len]) |c, *out| {
        out.* = switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '.', '_', '-' => c,
            else => '-',
        };
    }
    const name = buf[0..len];
    validateName(name) catch return null;
    return name;
}

/// Default session name for sessions created without a name: the basename
/// of the current directory when it is usable and no session socket with
/// that name exists in dir, otherwise the creating process id (like GNU
/// screen's pid prefix).
pub fn defaultName(buf: []u8, dir: []const u8) []const u8 {
    cwd: {
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd = std.posix.getcwd(&cwd_buf) catch break :cwd;
        const name = sanitizeName(buf, std.fs.path.basename(cwd)) orelse break :cwd;
        var sock_buf: [std.fs.max_path_bytes]u8 = undefined;
        const sock = std.fmt.bufPrint(
            &sock_buf,
            "{s}/{s}.sock",
            .{ dir, name },
        ) catch break :cwd;
        // An existing socket means the name is taken; fall back to the pid.
        std.fs.cwd().access(sock, .{}) catch return name;
        break :cwd;
    }
    return std.fmt.bufPrint(buf, "{d}", .{std.c.getpid()}) catch unreachable;
}

/// Iterate sessions in dir: every "*.sock" file. Returns names without
/// the extension; caller frees each name and the list.
pub fn listSessions(alloc: std.mem.Allocator, dir_path: []const u8) ![][]u8 {
    var names: std.ArrayList([]u8) = .empty;
    errdefer {
        for (names.items) |n| alloc.free(n);
        names.deinit(alloc);
    }

    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return names.toOwnedSlice(alloc),
        else => return err,
    };
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".sock")) continue;
        const name = entry.name[0 .. entry.name.len - ".sock".len];
        validateName(name) catch continue;
        try names.append(alloc, try alloc.dupe(u8, name));
    }

    return names.toOwnedSlice(alloc);
}

test "validateWorkspaceCwd resolves an existing directory to an absolute path" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const rel = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(rel);

    const got = try validateWorkspaceCwd(alloc, rel);
    defer alloc.free(got);
    try std.testing.expect(std.fs.path.isAbsolute(got));
    try std.testing.expectEqualStrings(rel, got);
}

test "validateWorkspaceCwd rejects missing paths and files" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(base);

    const missing = try std.fs.path.join(alloc, &.{ base, "missing" });
    defer alloc.free(missing);
    try std.testing.expectError(error.InvalidWorkspaceCwd, validateWorkspaceCwd(alloc, missing));

    try tmp.dir.writeFile(.{ .sub_path = "file.txt", .data = "" });
    const file_path = try std.fs.path.join(alloc, &.{ base, "file.txt" });
    defer alloc.free(file_path);
    try std.testing.expectError(error.InvalidWorkspaceCwd, validateWorkspaceCwd(alloc, file_path));
}

test "workspace config round trip stores absolute cwd" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir);

    const sub = try std.fs.path.join(alloc, &.{ dir, "proj" });
    defer alloc.free(sub);
    try std.fs.cwd().makePath(sub);

    try writeWorkspaceConfig(alloc, dir, sub);
    var config = try readWorkspaceConfig(alloc, dir);
    defer config.deinit(alloc);
    try std.testing.expect(config.cwd != null);
    try std.testing.expectEqualStrings(sub, config.cwd.?);
}

test "resolveSessionCwd prefers workspace config over process cwd" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir);

    const ws_cwd = try std.fs.path.join(alloc, &.{ dir, "work" });
    defer alloc.free(ws_cwd);
    try std.fs.cwd().makePath(ws_cwd);
    try writeWorkspaceConfig(alloc, dir, ws_cwd);

    const got = try resolveSessionCwd(alloc, dir);
    defer alloc.free(got);
    try std.testing.expectEqualStrings(ws_cwd, got);
}

test "validateName" {
    try validateName("work");
    try validateName("a-b_c.d2");
    try std.testing.expectError(error.InvalidSessionName, validateName(""));
    try std.testing.expectError(error.InvalidSessionName, validateName("a/b"));
    try std.testing.expectError(error.InvalidSessionName, validateName(".hidden"));
    try std.testing.expectError(error.InvalidSessionName, validateName("-flag"));
    try std.testing.expectError(error.InvalidSessionName, validateName("a" ** 65));
    try std.testing.expectError(error.InvalidSessionName, validateName("sp ace"));
}

test "sanitizeName" {
    var buf: [max_name_len]u8 = undefined;
    try std.testing.expectEqualStrings("my-proj", sanitizeName(&buf, "my proj").?);
    try std.testing.expectEqualStrings("a.b_c-1", sanitizeName(&buf, "a.b_c-1").?);
    try std.testing.expectEqualStrings("h--llo", sanitizeName(&buf, "héllo").?);
    try std.testing.expect(sanitizeName(&buf, "") == null);
    try std.testing.expect(sanitizeName(&buf, ".hidden") == null);
    try std.testing.expect(sanitizeName(&buf, "-flag") == null);
    try std.testing.expectEqualStrings(
        "x" ** max_name_len,
        sanitizeName(&buf, "x" ** 100).?,
    );
}

test "socketPath" {
    const alloc = std.testing.allocator;
    const p = try socketPath(alloc, "/run/gs", "work");
    defer alloc.free(p);
    try std.testing.expectEqualStrings("/run/gs/work.sock", p);
}

test "sidecarPath and storeDir" {
    const alloc = std.testing.allocator;
    const sc = try sidecarPath(alloc, "/run/gs", "work");
    defer alloc.free(sc);
    try std.testing.expectEqualStrings("/run/gs/work.agent", sc);
    const store = try storeDir(alloc, "/run/gs", "work");
    defer alloc.free(store);
    try std.testing.expectEqualStrings("/run/gs/work.store", store);
}

test "removeAgentFiles deletes sidecar and store, ignores absence" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir);

    // Absent files: must not error.
    removeAgentFiles(alloc, dir, "ghost");

    try tmp.dir.writeFile(.{ .sub_path = "work.agent", .data = "{}" });
    try tmp.dir.makePath("work.store/sessions");
    try tmp.dir.writeFile(.{ .sub_path = "work.store/sessions/x", .data = "y" });

    removeAgentFiles(alloc, dir, "work");
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("work.agent", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("work.store", .{}));
    // The .sock that listSessions keys on is untouched by this helper.
}

test "socketDirFrom prefers MOO_DIR and creates it" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(base);

    const want = try std.fs.path.join(alloc, &.{ base, "override", "moo" });
    defer alloc.free(want);

    const dir = try socketDirFrom(alloc, want, null);
    defer alloc.free(dir);
    try std.testing.expectEqualStrings(want, dir);
    var d = try std.fs.cwd().openDir(dir, .{});
    d.close();
}

test "socketDirFrom uses an existing runtime dir" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const runtime = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(runtime);

    const dir = try socketDirFrom(alloc, null, runtime);
    defer alloc.free(dir);

    const want = try std.fs.path.join(alloc, &.{ runtime, "moo" });
    defer alloc.free(want);
    try std.testing.expectEqualStrings(want, dir);
    var d = try std.fs.cwd().openDir(dir, .{});
    d.close();
}

test "socketDirFrom falls back when the runtime dir is unusable" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(base);

    const fallback = try std.fmt.allocPrint(alloc, "/tmp/moo-{d}", .{std.c.getuid()});
    defer alloc.free(fallback);

    // Missing directory, like /run/user/<uid> on macOS. The fallback
    // must not attempt to create the runtime dir or its parents.
    const missing = try std.fs.path.join(alloc, &.{ base, "run", "user", "501" });
    defer alloc.free(missing);
    {
        const dir = try socketDirFrom(alloc, null, missing);
        defer alloc.free(dir);
        try std.testing.expectEqualStrings(fallback, dir);
        try std.testing.expectError(
            error.FileNotFound,
            std.fs.cwd().access(missing, .{}),
        );
    }

    // A runtime dir that is not a directory at all.
    try tmp.dir.writeFile(.{ .sub_path = "not-a-dir", .data = "" });
    const file_path = try std.fs.path.join(alloc, &.{ base, "not-a-dir" });
    defer alloc.free(file_path);
    {
        const dir = try socketDirFrom(alloc, null, file_path);
        defer alloc.free(dir);
        try std.testing.expectEqualStrings(fallback, dir);
    }
}

// Mode bits of an existing directory, masked to the permission bits.
fn dirMode(path: []const u8) !u32 {
    const st = try std.posix.fstatat(std.posix.AT.FDCWD, path, 0);
    return @as(u32, @intCast(st.mode)) & 0o777;
}

test "socketDirFromFor without a workspace is byte-for-byte the no-workspace path" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(base);

    const moo_dir = try std.fs.path.join(alloc, &.{ base, "override", "moo" });
    defer alloc.free(moo_dir);

    const want = try socketDirFrom(alloc, moo_dir, null);
    defer alloc.free(want);

    const got = try socketDirFromFor(alloc, moo_dir, null, null);
    defer alloc.free(got);

    try std.testing.expectEqualStrings(want, got);
    // No ws/ suffix and no ws/ directory was created under the base.
    try std.testing.expect(std.mem.indexOf(u8, got, "/ws/") == null);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("override/moo/ws", .{}));
}

test "socketDirFromFor with a workspace resolves <base>/ws/<name> at mode 0700" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(base);

    const moo_dir = try std.fs.path.join(alloc, &.{ base, "moo" });
    defer alloc.free(moo_dir);

    const dir = try socketDirFromFor(alloc, moo_dir, null, "proj");
    defer alloc.free(dir);

    const want = try std.fs.path.join(alloc, &.{ moo_dir, "ws", "proj" });
    defer alloc.free(want);
    try std.testing.expectEqualStrings(want, dir);

    // The directory exists and is private to the user.
    var d = try std.fs.cwd().openDir(dir, .{});
    d.close();
    try std.testing.expectEqual(@as(u32, 0o700), try dirMode(dir));
}

test "socketDirFromFor rejects invalid workspace names and creates nothing" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(base);

    const moo_dir = try std.fs.path.join(alloc, &.{ base, "moo" });
    defer alloc.free(moo_dir);

    for ([_][]const u8{ "../x", "", "-flag" }) |bad| {
        try std.testing.expectError(
            error.InvalidSessionName,
            socketDirFromFor(alloc, moo_dir, null, bad),
        );
    }

    // No ws/<name> directory was created for any rejected name. The ws/
    // parent itself must not be left behind either.
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("moo/ws", .{}));
}

test "listSessions ignores the ws/ subdirectory" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(base);

    // A normal session socket in the base, plus a workspace holding its own
    // session. listSessions(base) must see only the base-level session.
    try tmp.dir.writeFile(.{ .sub_path = "foo.sock", .data = "" });
    const ws = try socketDirFromFor(alloc, base, null, "proj");
    defer alloc.free(ws);
    {
        const inner = try socketPath(alloc, ws, "inner");
        defer alloc.free(inner);
        try std.fs.cwd().writeFile(.{ .sub_path = inner, .data = "" });
    }

    const names = try listSessions(alloc, base);
    defer {
        for (names) |n| alloc.free(n);
        alloc.free(names);
    }
    try std.testing.expectEqual(@as(usize, 1), names.len);
    try std.testing.expectEqualStrings("foo", names[0]);
    for (names) |n| try std.testing.expect(!std.mem.eql(u8, n, "ws"));
}

test "resolveWorkspace precedence: flag over env, empty env means none" {
    // Flag wins over env when both are present.
    try std.testing.expectEqualStrings("a", resolveWorkspace("a", "b").?);
    // No flag: the env value is used.
    try std.testing.expectEqualStrings("b", resolveWorkspace(null, "b").?);
    // Neither: no workspace.
    try std.testing.expect(resolveWorkspace(null, null) == null);
    // An exported-but-empty MOO_WORKSPACE means default, not a "" workspace.
    try std.testing.expect(resolveWorkspace(null, "") == null);
    // Flag alone, env absent.
    try std.testing.expectEqualStrings("a", resolveWorkspace("a", null).?);
}

test "the same session name lives independently in two workspaces" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(base);

    const a = try socketDirFromFor(alloc, base, null, "a");
    defer alloc.free(a);
    const b = try socketDirFromFor(alloc, base, null, "b");
    defer alloc.free(b);

    // Distinct directories that do not collide.
    try std.testing.expect(!std.mem.eql(u8, a, b));

    {
        const sa = try socketPath(alloc, a, "work");
        defer alloc.free(sa);
        try std.fs.cwd().writeFile(.{ .sub_path = sa, .data = "" });
    }
    {
        const sb = try socketPath(alloc, b, "work");
        defer alloc.free(sb);
        try std.fs.cwd().writeFile(.{ .sub_path = sb, .data = "" });
    }

    const na = try listSessions(alloc, a);
    defer {
        for (na) |n| alloc.free(n);
        alloc.free(na);
    }
    const nb = try listSessions(alloc, b);
    defer {
        for (nb) |n| alloc.free(n);
        alloc.free(nb);
    }
    try std.testing.expectEqual(@as(usize, 1), na.len);
    try std.testing.expectEqualStrings("work", na[0]);
    try std.testing.expectEqual(@as(usize, 1), nb.len);
    try std.testing.expectEqualStrings("work", nb[0]);
}
