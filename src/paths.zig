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

/// Per-session agent sidecar: "<dir>/<name>.agent" (a JSON file recording the
/// harness, session id, and transcript store). Lives beside the socket but is
/// invisible to listSessions, which only matches "*.sock".
pub fn sidecarPath(alloc: std.mem.Allocator, dir: []const u8, name: []const u8) ![]u8 {
    const file = try std.fmt.allocPrint(alloc, "{s}.agent", .{name});
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

/// Best-effort removal of a session's agent sidecar and transcript store. The
/// socket itself is owned by the daemon and removed on quit, so it is left
/// alone here.
pub fn removeAgentFiles(alloc: std.mem.Allocator, dir: []const u8, name: []const u8) void {
    if (sidecarPath(alloc, dir, name)) |sc| {
        defer alloc.free(sc);
        std.fs.cwd().deleteFile(sc) catch {};
    } else |_| {}
    if (storeDir(alloc, dir, name)) |store| {
        defer alloc.free(store);
        std.fs.cwd().deleteTree(store) catch {};
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
