//! moo: sessions that haunt your terminal. A GNU screen style
//! terminal multiplexer built on libghostty (ghostty-vt).

const std = @import("std");
const posix = std.posix;

const client = @import("client.zig");
const daemonpkg = @import("daemon.zig");
const harness = @import("harness.zig");
const help = @import("help.zig");
const paths = @import("paths.zig");
const protocol = @import("protocol.zig");
const ui = @import("ui.zig");

pub const version = "0.5.20";

var session_child_close_fd: posix.fd_t = -1;

/// Route std.log through a filter. libghostty's VT stream parser logs
/// unimplemented sequences at info level under the `stream` scope (e.g.
/// "OSC 1 (change icon) received and ignored"). In `moo ui` the parser runs
/// in-process with stderr still attached to the user's terminal (unlike the
/// daemon, which redirects stderr in startDaemon), so those lines paint over
/// the rendered viewport and corrupt it. Drop info-and-below from `stream`;
/// every other scope logs as before.
pub const std_options: std.Options = .{
    .logFn = filteredLog,
};

fn filteredLog(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    if (scope == .stream and @intFromEnum(level) >= @intFromEnum(std.log.Level.info)) return;
    std.log.defaultLog(level, scope, format, args);
}

/// Exit codes, documented in `moo help`.
const exit_runtime: u8 = 1;
const exit_usage: u8 = 2;
const exit_no_session: u8 = 3;
const exit_timeout: u8 = 4;

fn fail(code: u8, comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("moo: " ++ fmt ++ "\n", args);
    posix.exit(code);
}

/// Usage errors point at the relevant help page.
fn usageFail(comptime cmd: []const u8, comptime fmt: []const u8, args: anytype) noreturn {
    const hint = if (cmd.len == 0) "moo help" else "moo help " ++ cmd;
    std.debug.print("moo: " ++ fmt ++ " (run '" ++ hint ++ "')\n", args);
    posix.exit(exit_usage);
}

fn stdoutWrite(bytes: []const u8) !void {
    try protocol.writeAll(posix.STDOUT_FILENO, bytes);
}

fn stdoutPrint(alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const text = try std.fmt.allocPrint(alloc, fmt, args);
    defer alloc.free(text);
    try stdoutWrite(text);
}

pub fn main() !void {
    // Note: not DebugAllocator. The session daemon is forked from this
    // process, and DebugAllocator's stack-trace capture reads process
    // memory through a pid cached before fork(), which blows up in the
    // child once the parent exits. Unit tests still run against
    // std.testing.allocator for leak checking.
    const alloc = std.heap.c_allocator;

    const argv = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, argv);
    const args: []const [:0]const u8 = @ptrCast(argv[1..]);

    if (args.len == 0) return stdoutWrite(help.overview);

    const cmd = args[0];
    const rest = args[1..];
    const eql = struct {
        fn f(a: []const u8, b: []const u8) bool {
            return std.mem.eql(u8, a, b);
        }
    }.f;

    if (eql(cmd, "new")) return cmdNew(alloc, rest);
    if (eql(cmd, "attach") or eql(cmd, "at") or eql(cmd, "a")) return cmdAttach(alloc, rest);
    if (eql(cmd, "ui") or eql(cmd, "i")) return cmdUi(alloc, rest);
    if (eql(cmd, "ls") or eql(cmd, "list")) return cmdLs(alloc, rest);
    if (eql(cmd, "ws")) return cmdWs(alloc, rest);
    if (eql(cmd, "send")) return cmdSend(alloc, rest);
    if (eql(cmd, "peek")) return cmdPeek(alloc, rest);
    if (eql(cmd, "read")) return cmdRead(alloc, rest);
    if (eql(cmd, "wait")) return cmdWait(alloc, rest);
    if (eql(cmd, "kill")) return cmdKill(alloc, rest);
    if (eql(cmd, "rename")) return cmdRename(alloc, rest);
    if (eql(cmd, "serve")) return cmdServe(alloc, rest);
    if (eql(cmd, "version") or eql(cmd, "-V") or eql(cmd, "--version")) return cmdVersion(alloc);
    if (eql(cmd, "help") or eql(cmd, "-h") or eql(cmd, "--help")) return cmdHelp(alloc, rest);
    fail(exit_usage, "unknown command '{s}' (run 'moo help')", .{cmd});
}

fn isHelpFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help");
}

/// Match a flag that carries a value, in both spellings: `--flag value`
/// (consuming the next argument) and `--flag=value`. Returns null when
/// `args[i]` is some other argument.
fn flagValue(
    comptime cmd: []const u8,
    comptime flag: []const u8,
    args: []const [:0]const u8,
    i: *usize,
) ?[]const u8 {
    const arg = args[i.*];
    if (std.mem.eql(u8, arg, flag)) {
        i.* += 1;
        if (i.* >= args.len) usageFail(cmd, flag ++ " requires a value", .{});
        return args[i.*];
    }
    if (std.mem.startsWith(u8, arg, flag ++ "=")) {
        return arg[flag.len + 1 ..];
    }
    return null;
}

/// The active workspace for a command: the `-w/--workspace` flag wins, else
/// $MOO_WORKSPACE. The result is borrowed (argv or env) and never freed.
fn activeWorkspace(flag: ?[]const u8) ?[]const u8 {
    return paths.resolveWorkspace(flag, posix.getenv("MOO_WORKSPACE"));
}

/// Resolve the socket dir for a command, turning an invalid workspace name
/// (from -w or $MOO_WORKSPACE) into a clean usage error rather than letting
/// error.InvalidSessionName propagate raw to main.
fn workspaceDir(comptime cmd: []const u8, alloc: std.mem.Allocator, ws_flag: ?[]const u8) ![]u8 {
    const ws = activeWorkspace(ws_flag);
    return workspaceDirForActive(cmd, alloc, ws);
}

fn workspaceDirForActive(comptime cmd: []const u8, alloc: std.mem.Allocator, ws: ?[]const u8) ![]u8 {
    return paths.socketDirFor(alloc, ws) catch |err| switch (err) {
        error.InvalidSessionName => usageFail(cmd, "invalid workspace name '{s}'", .{ws.?}),
        else => return err,
    };
}

fn printHelpPage(name: []const u8) !void {
    const entry = help.find(name) orelse unreachable;
    try stdoutWrite(entry.body);
}

// -- Session resolution ---------------------------------------------------

fn joinNames(alloc: std.mem.Allocator, names: []const []u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (names, 0..) |name, i| {
        if (i > 0) out.appendSlice(alloc, ", ") catch break;
        out.appendSlice(alloc, name) catch break;
    }
    return out.items;
}

/// Resolve a session name to an owned, existing session name.
/// Accepts unique prefixes. Exits with code 3 when nothing matches.
fn resolveSession(
    alloc: std.mem.Allocator,
    dir: []const u8,
    want: []const u8,
) ![]u8 {
    return resolveSessionResult(alloc, dir, want) catch |err| switch (err) {
        error.AmbiguousSession => {
            const sessions = try paths.listSessions(alloc, dir);
            fail(exit_no_session, "ambiguous session '{s}': matches {s}", .{
                want, joinNames(alloc, sessions),
            });
        },
        error.NoSession => fail(exit_no_session, "no session matching '{s}' (run 'moo ls')", .{want}),
        else => return err,
    };
}

fn resolveSessionResult(
    alloc: std.mem.Allocator,
    dir: []const u8,
    want: []const u8,
) ![]u8 {
    const sessions = try paths.listSessions(alloc, dir);
    defer {
        for (sessions) |s| alloc.free(s);
        alloc.free(sessions);
    }

    for (sessions) |s| {
        if (std.mem.eql(u8, s, want)) return alloc.dupe(u8, s);
    }
    var match: ?[]const u8 = null;
    var count: usize = 0;
    for (sessions) |s| {
        if (std.mem.startsWith(u8, s, want)) {
            match = s;
            count += 1;
        }
    }
    if (count == 1) return alloc.dupe(u8, match.?);
    if (count > 1) return error.AmbiguousSession;
    return error.NoSession;
}

pub const SessionInfo = struct {
    /// Full info payload:
    /// name \t Attached|Detached \t idle_ms \t out_idle_ms \t title.
    text: []u8,
    attached: bool,
    idle_ms: i64,
    /// Time since the window last produced output; drives wait --idle.
    out_idle_ms: i64,
    /// Window title; slices into `text`.
    title: []const u8,
};

/// Query a session daemon, deleting the socket when the daemon is gone.
pub fn sessionInfo(alloc: std.mem.Allocator, dir: []const u8, name: []const u8) !?SessionInfo {
    const sock = try paths.socketPath(alloc, dir, name);
    defer alloc.free(sock);
    const result = client.control(alloc, sock, &.{"info"}) catch {
        // Stale socket: the daemon is gone.
        std.fs.cwd().deleteFile(sock) catch {};
        return null;
    };
    errdefer alloc.free(result.text);
    if (!result.ok) return error.BadResponse;

    var it = std.mem.splitScalar(u8, result.text, '\t');
    _ = it.next() orelse return error.BadResponse; // name
    const attached = std.mem.eql(u8, it.next() orelse return error.BadResponse, "Attached");
    const idle_ms = std.fmt.parseInt(i64, it.next() orelse return error.BadResponse, 10) catch
        return error.BadResponse;
    const out_idle_ms = std.fmt.parseInt(i64, it.next() orelse return error.BadResponse, 10) catch
        return error.BadResponse;
    const title = it.rest();
    return .{
        .text = result.text,
        .attached = attached,
        .idle_ms = idle_ms,
        .out_idle_ms = out_idle_ms,
        .title = title,
    };
}

/// Run a control command against a session, mapping a missing or
/// mid-teardown daemon to the documented exit code. An EOF on the
/// control connection means the daemon died before replying, so it is
/// reported the same as a daemon that is already gone.
fn mustControl(
    alloc: std.mem.Allocator,
    dir: []const u8,
    name: []const u8,
    argv: []const []const u8,
) !client.ControlResult {
    return controlSession(alloc, dir, name, argv) catch |err| switch (err) {
        error.NoSession => fail(
            exit_no_session,
            "no session named {s}",
            .{name},
        ),
        else => return err,
    };
}

fn controlSession(
    alloc: std.mem.Allocator,
    dir: []const u8,
    name: []const u8,
    argv: []const []const u8,
) !client.ControlResult {
    const sock = try paths.socketPath(alloc, dir, name);
    defer alloc.free(sock);
    return client.control(alloc, sock, argv) catch |err| switch (err) {
        error.FileNotFound, error.ConnectionRefused, error.ConnectionLost => error.NoSession,
        else => return err,
    };
}

// -- Commands -------------------------------------------------------------

fn cmdNew(alloc: std.mem.Allocator, args: []const [:0]const u8) !void {
    var name: ?[]const u8 = null;
    var detached = false;
    var agent: ?harness.Agent = null;
    var ws_flag: ?[]const u8 = null;
    var cmd_argv: []const [:0]const u8 = &.{};

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) {
            cmd_argv = args[i + 1 ..];
            break;
        } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--detached")) {
            detached = true;
        } else if (isHelpFlag(arg)) {
            return printHelpPage("new");
        } else if (flagValue("new", "--agent", args, &i)) |v| {
            agent = harness.Agent.fromId(v) orelse
                usageFail("new", "unknown agent '{s}' (claude, codex, pi, raw, bash, zsh)", .{v});
        } else if (flagValue("new", "--workspace", args, &i)) |v| {
            ws_flag = v;
        } else if (flagValue("new", "-w", args, &i)) |v| {
            ws_flag = v;
        } else if (arg.len > 0 and arg[0] == '-') {
            usageFail("new", "unknown flag '{s}'", .{arg});
        } else if (name == null) {
            name = arg;
        } else {
            usageFail("new", "unexpected argument '{s}'; put -- before the command", .{arg});
        }
    }

    const ws = activeWorkspace(ws_flag);
    const dir = try workspaceDirForActive("new", alloc, ws);
    defer alloc.free(dir);
    var name_buf: [paths.max_name_len]u8 = undefined;
    const session_name = name orelse paths.defaultName(&name_buf, dir);
    startSessionNamed(alloc, dir, session_name, agent, ws, @ptrCast(cmd_argv), 24, 80) catch |err| switch (err) {
        error.InvalidSessionName => usageFail("new", "invalid session name '{s}'", .{session_name}),
        error.SessionExists => fail(
            exit_runtime,
            "session {s} already exists (run 'moo attach {s}')",
            .{ session_name, session_name },
        ),
        else => return err,
    };
    if (detached) {
        // The name on stdout so scripts can capture it.
        try stdoutPrint(alloc, "{s}\n", .{session_name});
        return;
    }
    try attachLoop(alloc, dir, session_name);
}

fn startSessionNamed(
    alloc: std.mem.Allocator,
    dir: []const u8,
    name: []const u8,
    agent: ?harness.Agent,
    workspace: ?[]const u8,
    cmd_argv: []const []const u8,
    rows: u16,
    cols: u16,
) !void {
    try paths.validateName(name);

    const sock = try paths.socketPath(alloc, dir, name);
    defer alloc.free(sock);

    // Claim the socket before any agent setup, so a name clash can't clobber the
    // existing session's sidecar or transcript store.
    const listen_fd = try bindListen(alloc, sock);

    // An agent harness augments the launch command (pinning a session id),
    // supplies per-session env (e.g. CODEX_HOME), and records a sidecar so the
    // transcript can be found by `moo read`. Allocations here live until the
    // forked child execs; the short-lived parent never frees them.
    var argv = cmd_argv;
    var env_overrides: []const [2][]const u8 = &.{};
    if (agent) |ag| {
        const launch = prepareAgent(alloc, dir, name, ag, cmd_argv);
        argv = launch.argv;
        env_overrides = launch.env;
    }

    // A workspace session exports MOO_WORKSPACE so processes inside it inherit
    // the scope; null (a default session) leaves env_overrides untouched, so no
    // empty value leaks in. Appended after the agent branch to keep its env.
    if (workspace) |wsname| {
        const combined = try alloc.alloc([2][]const u8, env_overrides.len + 1);
        @memcpy(combined[0..env_overrides.len], env_overrides);
        combined[env_overrides.len] = .{ "MOO_WORKSPACE", wsname };
        env_overrides = combined;
    }

    // Fork the session daemon. The listening socket already exists, so
    // there is no race between daemon startup and the first attach.
    // MOO_FOREGROUND=1 keeps the daemon in the foreground, which is
    // useful for debugging.
    if (posix.getenv("MOO_FOREGROUND") != null) {
        try daemonpkg.Daemon.run(alloc, .{
            .name = name,
            .socket_path = sock,
            .listen_fd = listen_fd,
            .argv = argv,
            .env_overrides = env_overrides,
            .rows = rows,
            .cols = cols,
        });
        return;
    }
    const pid = try posix.fork();
    if (pid == 0) {
        if (session_child_close_fd >= 0) posix.close(session_child_close_fd);
        runDaemon(alloc, name, sock, listen_fd, argv, env_overrides, rows, cols);
    }
    posix.close(listen_fd);
}

const AgentLaunch = struct {
    argv: []const []const u8,
    env: []const [2][]const u8,
};

/// Prepare an agent-harness launch: augment argv, compute per-session launch
/// isolation, and persist a sidecar so `moo read` can locate the transcript.
/// Any failure falls back to the user's raw command — the session still starts,
/// it just won't be transcript-tracked.
fn prepareAgent(
    alloc: std.mem.Allocator,
    dir: []const u8,
    name: []const u8,
    agent: harness.Agent,
    cmd_argv: []const []const u8,
) AgentLaunch {
    const fallback: AgentLaunch = .{ .argv = cmd_argv, .env = &.{} };
    const store = paths.storeDir(alloc, dir, name) catch return fallback;
    // Clear any store left by a prior same-named session, so transcript lookup
    // (e.g. codex's newest-rollout glob) can only ever see this session's data.
    std.fs.cwd().deleteTree(store) catch {};
    const prepared = agent.prepare(alloc, cmd_argv, store) catch return fallback;

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = posix.getcwd(&cwd_buf) catch ".";
    const overrides = agent.launchOverrides(alloc, prepared.session_id, cwd, store) catch
        harness.LaunchOverrides{};

    writeSidecar(alloc, dir, name, .{
        .agent = agent,
        .session_id = prepared.session_id,
        .session_store = overrides.session_store,
        .cwd = cwd,
    });
    return .{ .argv = prepared.argv, .env = overrides.env };
}

fn writeSidecar(
    alloc: std.mem.Allocator,
    dir: []const u8,
    name: []const u8,
    sc: harness.Sidecar,
) void {
    const json = sc.toJson(alloc) catch return;
    defer alloc.free(json);
    const path = paths.sidecarPath(alloc, dir, name) catch return;
    defer alloc.free(path);
    std.fs.cwd().writeFile(.{ .sub_path = path, .data = json }) catch {};
}

/// Tear down a session's agent files: the transcript store recorded in its
/// sidecar (authoritative — it survives a rename, where the store keeps the old
/// name), plus the default-name store and the sidecar file. Best-effort; a
/// non-agent session simply has none of these.
fn removeAgentSession(alloc: std.mem.Allocator, dir: []const u8, name: []const u8) void {
    if (paths.sidecarPath(alloc, dir, name)) |sc_path| {
        defer alloc.free(sc_path);
        if (readTranscript(alloc, sc_path)) |sc_data| {
            defer alloc.free(sc_data);
            if (harness.Sidecar.fromJson(alloc, sc_data)) |sc| {
                defer sc.deinit(alloc);
                if (sc.session_store) |store| std.fs.cwd().deleteTree(store) catch {};
            } else |_| {}
        }
    } else |_| {}
    paths.removeAgentFiles(alloc, dir, name);
}

fn cmdAttach(alloc: std.mem.Allocator, args: []const [:0]const u8) !void {
    var name_arg: ?[]const u8 = null;
    var ws_flag: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (isHelpFlag(arg)) return printHelpPage("attach");
        if (flagValue("attach", "--workspace", args, &i)) |v| {
            ws_flag = v;
        } else if (flagValue("attach", "-w", args, &i)) |v| {
            ws_flag = v;
        } else if (arg.len > 0 and arg[0] == '-') {
            usageFail("attach", "unknown flag '{s}'", .{arg});
        } else if (name_arg != null) {
            usageFail("attach", "unexpected argument '{s}'", .{arg});
        } else {
            name_arg = arg;
        }
    }
    const want = name_arg orelse usageFail("attach", "a session name is required", .{});

    const dir = try workspaceDir("attach", alloc, ws_flag);
    defer alloc.free(dir);
    const name = try resolveSession(alloc, dir, want);
    defer alloc.free(name);
    try attachLoop(alloc, dir, name);
}

fn attachLoop(alloc: std.mem.Allocator, dir: []const u8, name: []const u8) !void {
    const sock = try paths.socketPath(alloc, dir, name);
    defer alloc.free(sock);
    const outcome = client.attach(alloc, sock) catch |err| switch (err) {
        error.FileNotFound, error.ConnectionRefused => fail(
            exit_no_session,
            "no session named {s}",
            .{name},
        ),
        error.NotATty => fail(exit_runtime, "attach requires a terminal", .{}),
        else => return err,
    };
    switch (outcome) {
        .detached => std.debug.print("[detached from {s}]\n", .{name}),
        .stolen => std.debug.print("[session {s} attached elsewhere]\n", .{name}),
        .ended => std.debug.print("[session {s} ended]\n", .{name}),
        .lost => {
            std.debug.print("[lost connection to {s}]\n", .{name});
            posix.exit(exit_runtime);
        },
    }
}

fn cmdUi(alloc: std.mem.Allocator, args: []const [:0]const u8) !void {
    var ws_flag: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (isHelpFlag(arg)) return printHelpPage("ui");
        if (flagValue("ui", "--workspace", args, &i)) |v| {
            ws_flag = v;
        } else if (flagValue("ui", "-w", args, &i)) |v| {
            ws_flag = v;
        } else {
            usageFail("ui", "unexpected argument '{s}'", .{arg});
        }
    }

    const ws = activeWorkspace(ws_flag);
    const dir = try workspaceDirForActive("ui", alloc, ws);
    defer alloc.free(dir);
    const outcome = ui.run(alloc, dir, ws) catch |err| switch (err) {
        error.NotATty => fail(exit_runtime, "ui requires a terminal", .{}),
        else => return err,
    };
    switch (outcome) {
        .closed => std.debug.print("[moo ui closed]\n", .{}),
        .stolen => std.debug.print("[moo ui attached elsewhere]\n", .{}),
        .lost => {
            std.debug.print("[lost connection to moo ui]\n", .{});
            posix.exit(exit_runtime);
        },
    }
}

fn cmdLs(alloc: std.mem.Allocator, args: []const [:0]const u8) !void {
    var json = false;
    var ws_flag: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (isHelpFlag(arg)) return printHelpPage("ls");
        if (std.mem.eql(u8, arg, "--json")) {
            json = true;
        } else if (flagValue("ls", "--workspace", args, &i)) |v| {
            ws_flag = v;
        } else if (flagValue("ls", "-w", args, &i)) |v| {
            ws_flag = v;
        } else {
            usageFail("ls", "unexpected argument '{s}'", .{arg});
        }
    }

    const dir = try workspaceDir("ls", alloc, ws_flag);
    defer alloc.free(dir);
    const sessions = try paths.listSessions(alloc, dir);
    defer {
        for (sessions) |s| alloc.free(s);
        alloc.free(sessions);
    }

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    var live: usize = 0;
    var name_width: usize = 4;
    var infos: std.ArrayList(struct { name: []const u8, info: SessionInfo }) = .empty;
    defer {
        for (infos.items) |entry| alloc.free(entry.info.text);
        infos.deinit(alloc);
    }
    for (sessions) |name| {
        const info = sessionInfo(alloc, dir, name) catch continue orelse continue;
        try infos.append(alloc, .{ .name = name, .info = info });
        name_width = @max(name_width, name.len);
        live += 1;
    }

    if (json) {
        try out.append(alloc, '[');
        for (infos.items, 0..) |entry, idx| {
            if (idx > 0) try out.append(alloc, ',');
            try out.appendSlice(alloc, "{\"name\":");
            try appendJsonString(alloc, &out, entry.name);
            const tail = try std.fmt.allocPrint(alloc, ",\"attached\":{},\"idle_ms\":{d},\"title\":", .{
                entry.info.attached,
                entry.info.idle_ms,
            });
            defer alloc.free(tail);
            try out.appendSlice(alloc, tail);
            try appendJsonString(alloc, &out, entry.info.title);
            try out.append(alloc, '}');
        }
        try out.appendSlice(alloc, "]\n");
        return stdoutWrite(out.items);
    }

    if (live == 0) {
        return stdoutPrint(alloc, "No sessions in {s}.\n", .{dir});
    }

    try appendPadded(alloc, &out, "NAME", name_width);
    try out.appendSlice(alloc, "  STATE     IDLE  TITLE\n");
    for (infos.items) |entry| {
        try appendPadded(alloc, &out, entry.name, name_width);
        var idle_buf: [32]u8 = undefined;
        const line = try std.fmt.allocPrint(alloc, "  {s: <8}  {s: <4}  {s}\n", .{
            if (entry.info.attached) "attached" else "detached",
            fmtIdle(&idle_buf, entry.info.idle_ms),
            entry.info.title,
        });
        defer alloc.free(line);
        try out.appendSlice(alloc, line);
    }
    try stdoutWrite(out.items);
}

fn countSessions(alloc: std.mem.Allocator, dir: []const u8) !usize {
    const sessions = try paths.listSessions(alloc, dir);
    defer {
        for (sessions) |s| alloc.free(s);
        alloc.free(sessions);
    }
    return sessions.len;
}

fn cmdWs(alloc: std.mem.Allocator, args: []const [:0]const u8) !void {
    var json = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (isHelpFlag(arg)) return printHelpPage("ws");
        if (std.mem.eql(u8, arg, "--json")) {
            json = true;
        } else {
            usageFail("ws", "unexpected argument '{s}'", .{arg});
        }
    }

    const base = try paths.socketDir(alloc);
    defer alloc.free(base);

    const default_count = try countSessions(alloc, base);

    // Collect workspace names first: entry.name borrows the iterator's buffer
    // and is invalidated by the next next(), so dup before counting (which
    // reopens and iterates a child directory).
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |n| alloc.free(n);
        names.deinit(alloc);
    }

    const ws_root = try std.fs.path.join(alloc, &.{ base, "ws" });
    defer alloc.free(ws_root);
    if (std.fs.cwd().openDir(ws_root, .{ .iterate = true })) |dir_const| {
        var dir = dir_const;
        defer dir.close();
        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .directory) continue;
            paths.validateName(entry.name) catch continue;
            try names.append(alloc, try alloc.dupe(u8, entry.name));
        }
    } else |err| switch (err) {
        error.FileNotFound => {}, // no named workspaces yet
        else => return err,
    }

    std.mem.sort([]u8, names.items, {}, struct {
        fn lessThan(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    if (json) {
        try out.append(alloc, '[');
        try appendWsJson(alloc, &out, "", default_count);
        for (names.items) |name| {
            try out.append(alloc, ',');
            const dir = try std.fs.path.join(alloc, &.{ ws_root, name });
            defer alloc.free(dir);
            try appendWsJson(alloc, &out, name, try countSessions(alloc, dir));
        }
        try out.appendSlice(alloc, "]\n");
        return stdoutWrite(out.items);
    }

    var name_width: usize = "(default)".len;
    for (names.items) |name| name_width = @max(name_width, name.len);

    try appendPadded(alloc, &out, "WORKSPACE", name_width);
    try out.appendSlice(alloc, "  SESSIONS\n");
    try appendWsRow(alloc, &out, "(default)", default_count, name_width);
    for (names.items) |name| {
        const dir = try std.fs.path.join(alloc, &.{ ws_root, name });
        defer alloc.free(dir);
        try appendWsRow(alloc, &out, name, try countSessions(alloc, dir), name_width);
    }
    try stdoutWrite(out.items);
}

fn appendWsJson(alloc: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8, count: usize) !void {
    try out.appendSlice(alloc, "{\"workspace\":");
    try appendJsonString(alloc, out, name);
    const tail = try std.fmt.allocPrint(alloc, ",\"sessions\":{d}}}", .{count});
    defer alloc.free(tail);
    try out.appendSlice(alloc, tail);
}

fn appendWsRow(alloc: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8, count: usize, width: usize) !void {
    try appendPadded(alloc, out, name, width);
    const line = try std.fmt.allocPrint(alloc, "  {d}\n", .{count});
    defer alloc.free(line);
    try out.appendSlice(alloc, line);
}

fn cutTab(rest: *[]const u8) ?[]const u8 {
    const idx = std.mem.indexOfScalar(u8, rest.*, '\t') orelse return null;
    const field = rest.*[0..idx];
    rest.* = rest.*[idx + 1 ..];
    return field;
}

fn cmdSend(alloc: std.mem.Allocator, args: []const [:0]const u8) !void {
    var name_arg: ?[]const u8 = null;
    var text: ?[]const u8 = null;
    var keys_arg: ?[]const u8 = null;
    var enter = false;
    var stdin = false;
    var ws_flag: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (isHelpFlag(arg)) return printHelpPage("send");
        if (std.mem.eql(u8, arg, "--enter")) {
            enter = true;
        } else if (std.mem.eql(u8, arg, "--stdin")) {
            stdin = true;
        } else if (flagValue("send", "--text", args, &i)) |v| {
            text = v;
        } else if (flagValue("send", "--key", args, &i)) |v| {
            keys_arg = v;
        } else if (flagValue("send", "--workspace", args, &i)) |v| {
            ws_flag = v;
        } else if (flagValue("send", "-w", args, &i)) |v| {
            ws_flag = v;
        } else if (arg.len > 0 and arg[0] == '-') {
            usageFail("send", "unknown flag '{s}'", .{arg});
        } else if (name_arg == null) {
            name_arg = arg;
        } else {
            usageFail("send", "unexpected argument '{s}'", .{arg});
        }
    }

    if (text != null and keys_arg != null) {
        usageFail("send", "--text and --key cannot be combined; use two calls", .{});
    }
    if (stdin and (text != null or keys_arg != null)) {
        usageFail("send", "--stdin cannot be combined with --text or --key", .{});
    }
    const want = name_arg orelse usageFail("send", "a session name is required", .{});

    // Resolve the session before potentially blocking on stdin.
    const dir = try workspaceDir("send", alloc, ws_flag);
    defer alloc.free(dir);
    const name = try resolveSession(alloc, dir, want);
    defer alloc.free(name);

    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(alloc);
    if (text) |t| {
        try payload.appendSlice(alloc, t);
    } else if (keys_arg) |list| {
        var it = std.mem.splitScalar(u8, list, ',');
        while (it.next()) |key_name| {
            if (key_name.len == 0) continue;
            if (!appendKey(alloc, &payload, key_name)) {
                usageFail("send", "unknown key '{s}'", .{key_name});
            }
        }
    } else {
        const data = try readAllStdin(alloc);
        defer alloc.free(data);
        try payload.appendSlice(alloc, data);
    }
    if (enter) try payload.append(alloc, '\r');

    if (payload.items.len == 0) usageFail("send", "nothing to send", .{});
    if (std.mem.indexOfScalar(u8, payload.items, 0) != null) {
        usageFail("send", "cannot send NUL bytes", .{});
    }

    const result = try mustControl(alloc, dir, name, &.{ "send", payload.items });
    defer alloc.free(result.text);
    if (!result.ok) fail(exit_runtime, "{s}", .{result.text});
}

/// Append the byte sequence for a named key. Returns false when the
/// name is not recognized.
fn appendKey(alloc: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8) bool {
    const eqli = std.ascii.eqlIgnoreCase;
    const bytes: []const u8 = if (eqli(name, "enter"))
        "\r"
    else if (eqli(name, "tab"))
        "\t"
    else if (eqli(name, "escape") or eqli(name, "esc"))
        "\x1b"
    else if (eqli(name, "space"))
        " "
    else if (eqli(name, "backspace") or eqli(name, "bs"))
        "\x7f"
    else if (eqli(name, "up"))
        "\x1b[A"
    else if (eqli(name, "down"))
        "\x1b[B"
    else if (eqli(name, "right"))
        "\x1b[C"
    else if (eqli(name, "left"))
        "\x1b[D"
    else if (eqli(name, "home"))
        "\x1b[H"
    else if (eqli(name, "end"))
        "\x1b[F"
    else if (name.len == 3 and (name[0] == 'C' or name[0] == 'c') and name[1] == '-' and
        std.ascii.isAlphabetic(name[2]))
    blk: {
        const byte = std.ascii.toLower(name[2]) - 'a' + 1;
        break :blk &[1]u8{byte};
    } else return false;

    out.appendSlice(alloc, bytes) catch return false;
    return true;
}

fn readAllStdin(alloc: std.mem.Allocator) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(alloc);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = try posix.read(posix.STDIN_FILENO, &buf);
        if (n == 0) break;
        try list.appendSlice(alloc, buf[0..n]);
        if (list.items.len > protocol.max_payload - 64) {
            fail(exit_runtime, "stdin too large to send (max ~1MB)", .{});
        }
    }
    return list.toOwnedSlice(alloc);
}

const Peek = struct {
    rows: u32,
    cols: u32,
    cursor_row: u32,
    cursor_col: u32,
    title: []const u8,
    screen: []const u8,
};

/// Wire format: rows \t cols \t cur_row \t cur_col \t title on the
/// first line, then the screen dump.
fn parsePeek(payload: []const u8) ?Peek {
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

fn cmdPeek(alloc: std.mem.Allocator, args: []const [:0]const u8) !void {
    var scrollback = false;
    var json = false;
    var name_arg: ?[]const u8 = null;
    var ws_flag: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (isHelpFlag(arg)) return printHelpPage("peek");
        if (std.mem.eql(u8, arg, "--scrollback")) {
            scrollback = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            json = true;
        } else if (flagValue("peek", "--workspace", args, &i)) |v| {
            ws_flag = v;
        } else if (flagValue("peek", "-w", args, &i)) |v| {
            ws_flag = v;
        } else if (arg.len > 0 and arg[0] == '-') {
            usageFail("peek", "unknown flag '{s}'", .{arg});
        } else if (name_arg == null) {
            name_arg = arg;
        } else {
            usageFail("peek", "unexpected argument '{s}'", .{arg});
        }
    }
    const want = name_arg orelse usageFail("peek", "a session name is required", .{});

    const dir = try workspaceDir("peek", alloc, ws_flag);
    defer alloc.free(dir);
    const name = try resolveSession(alloc, dir, want);
    defer alloc.free(name);

    const result = try mustControl(alloc, dir, name, &.{
        "peek", if (scrollback) "scrollback" else "screen",
    });
    defer alloc.free(result.text);
    if (!result.ok) fail(exit_runtime, "{s}", .{result.text});

    const peek = parsePeek(result.text) orelse
        fail(exit_runtime, "malformed peek response", .{});

    if (!json) {
        try stdoutWrite(peek.screen);
        if (peek.screen.len > 0 and peek.screen[peek.screen.len - 1] != '\n') {
            try stdoutWrite("\n");
        }
        return;
    }

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"session\":");
    try appendJsonString(alloc, &out, name);
    try out.appendSlice(alloc, ",\"title\":");
    try appendJsonString(alloc, &out, peek.title);
    const geo = try std.fmt.allocPrint(
        alloc,
        ",\"rows\":{d},\"cols\":{d},\"cursor\":{{\"row\":{d},\"col\":{d}}},\"screen\":",
        .{ peek.rows, peek.cols, peek.cursor_row, peek.cursor_col },
    );
    defer alloc.free(geo);
    try out.appendSlice(alloc, geo);
    try appendJsonString(alloc, &out, peek.screen);
    try out.appendSlice(alloc, "}\n");
    try stdoutWrite(out.items);
}

/// Cap on transcript size read into memory (agent sessions are JSONL logs).
const max_transcript_bytes: usize = 64 * 1024 * 1024;

/// `moo read <session>` de-noises a live agent session's transcript, classifying
/// what the agent is doing and printing the conversation. `moo read --agent
/// <kind> <file>` does the same for a saved transcript on disk.
fn cmdRead(alloc: std.mem.Allocator, args: []const [:0]const u8) !void {
    var json = false;
    var thinking = false;
    var agent_kind: ?[]const u8 = null;
    var file: ?[]const u8 = null;
    var positional: ?[]const u8 = null;
    var ws_flag: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (isHelpFlag(arg)) return printHelpPage("read");
        if (std.mem.eql(u8, arg, "--json")) {
            json = true;
        } else if (std.mem.eql(u8, arg, "--thinking")) {
            thinking = true;
        } else if (flagValue("read", "--agent", args, &i)) |v| {
            agent_kind = v;
        } else if (flagValue("read", "--file", args, &i)) |v| {
            file = v;
        } else if (flagValue("read", "--workspace", args, &i)) |v| {
            ws_flag = v;
        } else if (flagValue("read", "-w", args, &i)) |v| {
            ws_flag = v;
        } else if (arg.len > 0 and arg[0] == '-') {
            usageFail("read", "unknown flag '{s}'", .{arg});
        } else if (positional == null) {
            positional = arg;
        } else {
            usageFail("read", "unexpected argument '{s}'", .{arg});
        }
    }

    // File mode: dump any saved transcript by path, no session needed.
    if (agent_kind) |kind| {
        const agent = harness.Agent.fromId(kind) orelse
            usageFail("read", "unknown agent '{s}' (claude, codex, pi)", .{kind});
        if (!agent.hasTranscript())
            usageFail("read", "agent '{s}' has no transcript (claude, codex, pi)", .{kind});
        const path = file orelse positional orelse
            usageFail("read", "--agent needs a transcript file (a path, or --file)", .{});
        const data = readTranscript(alloc, path) orelse
            fail(exit_runtime, "cannot read transcript {s}", .{path});
        defer alloc.free(data);
        const dump = if (json)
            try agent.dumpJson(alloc, data, thinking)
        else
            try agent.dumpText(alloc, data, thinking);
        defer alloc.free(dump);
        try emitDump(dump, json);
        return;
    }

    // Session mode: resolve a live session, read its sidecar, locate transcript.
    const want = positional orelse usageFail("read", "a session name is required", .{});
    const dir = try workspaceDir("read", alloc, ws_flag);
    defer alloc.free(dir);
    const name = try resolveSession(alloc, dir, want);
    defer alloc.free(name);

    const sc_path = try paths.sidecarPath(alloc, dir, name);
    defer alloc.free(sc_path);
    const sc_data = readTranscript(alloc, sc_path) orelse fail(
        exit_runtime,
        "session {s} was not started with --agent (nothing to read)",
        .{name},
    );
    defer alloc.free(sc_data);
    const sc = harness.Sidecar.fromJson(alloc, sc_data) catch
        fail(exit_runtime, "corrupt agent sidecar for {s}", .{name});
    defer sc.deinit(alloc);

    // The transcript may not exist yet (e.g. pi's lazy file before the first
    // reply); treat that as empty, which classifies as not-idle.
    const t_path = sc.agent.transcriptPath(alloc, sc) catch null;
    defer if (t_path) |p| alloc.free(p);
    const data = if (t_path) |p| (readTranscript(alloc, p) orelse try alloc.dupe(u8, "")) else try alloc.dupe(u8, "");
    defer alloc.free(data);

    var report = try sc.agent.detect(alloc, data);
    defer report.deinit(alloc);

    if (json) {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(alloc);
        try out.appendSlice(alloc, "{\"session\":");
        try appendJsonString(alloc, &out, name);
        try out.appendSlice(alloc, ",\"agent\":");
        try appendJsonString(alloc, &out, sc.agent.id());
        try out.appendSlice(alloc, ",\"state\":");
        try appendJsonString(alloc, &out, report.state.asStr());
        if (report.stop_reason) |s| {
            try out.appendSlice(alloc, ",\"stop_reason\":");
            try appendJsonString(alloc, &out, s);
        }
        if (report.detail) |d| {
            try out.appendSlice(alloc, ",\"detail\":");
            try appendJsonString(alloc, &out, d);
        }
        const tail = try std.fmt.allocPrint(alloc, ",\"messages\":{d},\"transcript\":", .{report.messages});
        defer alloc.free(tail);
        try out.appendSlice(alloc, tail);
        const arr = try sc.agent.dumpJson(alloc, data, thinking);
        defer alloc.free(arr);
        try out.appendSlice(alloc, std.mem.trimRight(u8, arr, " \n"));
        try out.appendSlice(alloc, "}\n");
        return stdoutWrite(out.items);
    }

    // Human view: a one-line status header, then the conversation.
    var header: std.ArrayList(u8) = .empty;
    defer header.deinit(alloc);
    try header.print(alloc, "{s} · {s} · {s}", .{ name, sc.agent.id(), report.state.asStr() });
    if (report.stop_reason) |s| try header.print(alloc, " ({s})", .{s});
    if (report.detail) |d| try header.print(alloc, " \u{2014} {s}", .{d});
    try header.print(alloc, " · {d} message{s}\n\n", .{ report.messages, if (report.messages == 1) "" else "s" });
    try stdoutWrite(header.items);

    const text = try sc.agent.dumpText(alloc, data, thinking);
    defer alloc.free(text);
    try emitDump(text, false);
}

/// Read a transcript/sidecar file fully into memory; null on any error
/// (missing, unreadable). Caller frees.
fn readTranscript(alloc: std.mem.Allocator, path: []const u8) ?[]u8 {
    return std.fs.cwd().readFileAlloc(alloc, path, max_transcript_bytes) catch null;
}

/// Print a de-noised dump, ensuring a trailing newline for the human view.
fn emitDump(dump: []const u8, json: bool) !void {
    if (dump.len == 0) {
        if (!json) try stdoutWrite("(empty transcript)\n");
        return;
    }
    try stdoutWrite(dump);
    if (dump[dump.len - 1] != '\n') try stdoutWrite("\n");
}

/// How long output must stay quiet for `wait --idle` to fire.
const idle_settle_ms: i64 = 2000;

fn cmdWait(alloc: std.mem.Allocator, args: []const [:0]const u8) !void {
    var name_arg: ?[]const u8 = null;
    var text: ?[]const u8 = null;
    var idle = false;
    var timeout_str: []const u8 = "30s";
    var ws_flag: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (isHelpFlag(arg)) return printHelpPage("wait");
        if (std.mem.eql(u8, arg, "--idle")) {
            idle = true;
        } else if (flagValue("wait", "--text", args, &i)) |v| {
            text = v;
        } else if (flagValue("wait", "--timeout", args, &i)) |v| {
            timeout_str = v;
        } else if (flagValue("wait", "--workspace", args, &i)) |v| {
            ws_flag = v;
        } else if (flagValue("wait", "-w", args, &i)) |v| {
            ws_flag = v;
        } else if (arg.len > 0 and arg[0] == '-') {
            usageFail("wait", "unknown flag '{s}'", .{arg});
        } else if (name_arg == null) {
            name_arg = arg;
        } else {
            usageFail("wait", "unexpected argument '{s}'", .{arg});
        }
    }

    if ((text != null) == idle) {
        usageFail("wait", "exactly one of --text or --idle is required", .{});
    }
    const want = name_arg orelse usageFail("wait", "a session name is required", .{});
    const timeout_ms = parseDurationMs(timeout_str) orelse
        usageFail("wait", "bad duration '{s}' (use 500ms, 2s, 1m, 4h, 1d)", .{timeout_str});

    const dir = try workspaceDir("wait", alloc, ws_flag);
    defer alloc.free(dir);
    const name = try resolveSession(alloc, dir, want);
    defer alloc.free(name);

    const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
    while (true) {
        if (text) |needle| {
            const result = try mustControl(alloc, dir, name, &.{ "peek", "screen" });
            defer alloc.free(result.text);
            if (!result.ok) fail(exit_runtime, "{s}", .{result.text});
            const peek = parsePeek(result.text) orelse
                fail(exit_runtime, "malformed peek response", .{});
            if (std.mem.indexOf(u8, peek.screen, needle) != null) return;
        } else {
            const info = try sessionInfo(alloc, dir, name) orelse
                fail(exit_no_session, "no session named {s}", .{name});
            defer alloc.free(info.text);
            if (info.out_idle_ms >= idle_settle_ms) return;
        }
        if (std.time.milliTimestamp() >= deadline) {
            fail(exit_timeout, "wait: timed out after {s}", .{timeout_str});
        }
        std.Thread.sleep(50 * std.time.ns_per_ms);
    }
}

fn cmdKill(alloc: std.mem.Allocator, args: []const [:0]const u8) !void {
    var all = false;
    var name_arg: ?[]const u8 = null;
    var ws_flag: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (isHelpFlag(arg)) return printHelpPage("kill");
        if (std.mem.eql(u8, arg, "--all")) {
            all = true;
        } else if (flagValue("kill", "--workspace", args, &i)) |v| {
            ws_flag = v;
        } else if (flagValue("kill", "-w", args, &i)) |v| {
            ws_flag = v;
        } else if (arg.len > 0 and arg[0] == '-') {
            usageFail("kill", "unknown flag '{s}'", .{arg});
        } else if (name_arg == null) {
            name_arg = arg;
        } else {
            usageFail("kill", "unexpected argument '{s}'", .{arg});
        }
    }
    if (all and name_arg != null) {
        usageFail("kill", "--all cannot be combined with a session name", .{});
    }

    const dir = try workspaceDir("kill", alloc, ws_flag);
    defer alloc.free(dir);

    if (all) {
        const sessions = try paths.listSessions(alloc, dir);
        defer {
            for (sessions) |s| alloc.free(s);
            alloc.free(sessions);
        }
        for (sessions) |name| {
            const sock = try paths.socketPath(alloc, dir, name);
            defer alloc.free(sock);
            const result = client.control(alloc, sock, &.{"quit"}) catch {
                std.fs.cwd().deleteFile(sock) catch {};
                removeAgentSession(alloc, dir, name);
                continue;
            };
            alloc.free(result.text);
            removeAgentSession(alloc, dir, name);
            try stdoutPrint(alloc, "{s}\n", .{name});
        }
        return;
    }

    const want = name_arg orelse usageFail("kill", "a session name or --all is required", .{});
    const name = try resolveSession(alloc, dir, want);
    defer alloc.free(name);
    const result = try mustControl(alloc, dir, name, &.{"quit"});
    defer alloc.free(result.text);
    if (!result.ok) fail(exit_runtime, "{s}", .{result.text});
    removeAgentSession(alloc, dir, name);
}

fn cmdRename(alloc: std.mem.Allocator, args: []const [:0]const u8) !void {
    var old_arg: ?[]const u8 = null;
    var new_arg: ?[]const u8 = null;
    var ws_flag: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (isHelpFlag(arg)) return printHelpPage("rename");
        if (flagValue("rename", "--workspace", args, &i)) |v| {
            ws_flag = v;
        } else if (flagValue("rename", "-w", args, &i)) |v| {
            ws_flag = v;
        } else if (arg.len > 0 and arg[0] == '-') {
            usageFail("rename", "unknown flag '{s}'", .{arg});
        } else if (old_arg == null) {
            old_arg = arg;
        } else if (new_arg == null) {
            new_arg = arg;
        } else {
            usageFail("rename", "unexpected argument '{s}'", .{arg});
        }
    }
    const want = old_arg orelse usageFail("rename", "a session name is required", .{});
    const new_name = new_arg orelse usageFail("rename", "a new session name is required", .{});
    paths.validateName(new_name) catch
        usageFail("rename", "invalid session name '{s}'", .{new_name});

    const dir = try workspaceDir("rename", alloc, ws_flag);
    defer alloc.free(dir);
    const name = try resolveSession(alloc, dir, want);
    defer alloc.free(name);

    const result = try mustControl(alloc, dir, name, &.{ "rename", new_name });
    defer alloc.free(result.text);
    if (!result.ok) fail(exit_runtime, "{s}", .{result.text});
}

// -- HTTP API -------------------------------------------------------------

const default_http_addr = "127.0.0.1:0";
const max_http_request = protocol.max_payload + 16 * 1024;

const ServeConfig = struct {
    token: ?[]const u8 = null,
};

const HttpRequest = struct {
    raw: []u8,
    method: []const u8,
    target: []const u8,
    path: []const u8,
    query: []const u8,
    body: []const u8,
    authorization: ?[]const u8,

    fn deinit(self: HttpRequest, alloc: std.mem.Allocator) void {
        alloc.free(self.raw);
    }
};

const SessionState = struct {
    text: []u8,
    attached: bool,
    idle_ms: i64,
    out_idle_ms: i64,
    rows: u32,
    cols: u32,
    event_seq: u64,
    title: []const u8,
};

fn cmdServe(alloc: std.mem.Allocator, args: []const [:0]const u8) !void {
    var addr_text: []const u8 = default_http_addr;
    var token_env: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (isHelpFlag(arg)) return printHelpPage("serve");
        if (flagValue("serve", "--addr", args, &i)) |v| {
            addr_text = v;
        } else if (flagValue("serve", "--token-env", args, &i)) |v| {
            token_env = v;
        } else {
            usageFail("serve", "unexpected argument '{s}'", .{arg});
        }
    }

    const addr = parseListenAddress(addr_text) catch
        usageFail("serve", "bad --addr '{s}' (use host:port)", .{addr_text});
    const token = if (token_env) |env_name| blk: {
        const value = posix.getenv(env_name) orelse
            usageFail("serve", "--token-env {s} is unset", .{env_name});
        if (value.len == 0) usageFail("serve", "--token-env {s} is empty", .{env_name});
        break :blk value;
    } else null;
    if (!isLoopback(addr) and token == null) {
        usageFail("serve", "non-loopback --addr requires --token-env", .{});
    }

    var server = try addr.listen(.{ .reuse_address = true });
    defer server.deinit();
    try stdoutPrint(alloc, "moo serve http://{f}\n", .{server.listen_address});

    const cfg: ServeConfig = .{ .token = token };
    while (true) {
        {
            var conn = server.accept() catch |err| {
                std.log.warn("http accept failed: {}", .{err});
                continue;
            };
            defer conn.stream.close();
            handleHttpConnection(alloc, conn.stream, cfg) catch |err| {
                std.log.warn("http request failed: {}", .{err});
            };
        }
    }
}

fn isLoopback(addr: std.net.Address) bool {
    return switch (addr.any.family) {
        posix.AF.INET => blk: {
            const bytes: *const [4]u8 = @ptrCast(&addr.in.sa.addr);
            break :blk bytes[0] == 127;
        },
        posix.AF.INET6 => blk: {
            const bytes = addr.in6.sa.addr;
            for (bytes[0..15]) |b| {
                if (b != 0) break :blk false;
            }
            break :blk bytes[15] == 1;
        },
        else => false,
    };
}

fn parseListenAddress(text: []const u8) !std.net.Address {
    if (text.len == 0) return error.InvalidAddress;
    if (text[0] == '[') {
        const end = std.mem.indexOfScalar(u8, text, ']') orelse return error.InvalidAddress;
        if (end + 1 >= text.len or text[end + 1] != ':') return error.InvalidAddress;
        const port = try std.fmt.parseInt(u16, text[end + 2 ..], 10);
        return std.net.Address.parseIp6(text[1..end], port);
    }
    const idx = std.mem.lastIndexOfScalar(u8, text, ':') orelse return error.InvalidAddress;
    const port = try std.fmt.parseInt(u16, text[idx + 1 ..], 10);
    return std.net.Address.parseIp(text[0..idx], port);
}

fn handleHttpConnection(alloc: std.mem.Allocator, stream: std.net.Stream, cfg: ServeConfig) !void {
    const req = readHttpRequest(alloc, stream) catch {
        return sendError(stream, 400, "bad_request", "malformed HTTP request");
    };
    defer req.deinit(alloc);
    try dispatchHttp(alloc, stream, req, cfg);
}

fn readHttpRequest(alloc: std.mem.Allocator, stream: std.net.Stream) !HttpRequest {
    var raw: std.ArrayList(u8) = .empty;
    errdefer raw.deinit(alloc);

    var header_end: ?usize = null;
    var buf: [4096]u8 = undefined;
    while (header_end == null) {
        const n = try stream.read(&buf);
        if (n == 0) return error.EndOfStream;
        try raw.appendSlice(alloc, buf[0..n]);
        if (raw.items.len > max_http_request) return error.RequestTooLarge;
        if (std.mem.indexOf(u8, raw.items, "\r\n\r\n")) |idx| header_end = idx;
    }

    const body_start = header_end.? + 4;
    const content_len = parseContentLength(raw.items[0..header_end.?]) orelse 0;
    if (content_len > protocol.max_payload) return error.RequestTooLarge;
    while (raw.items.len < body_start + content_len) {
        const n = try stream.read(&buf);
        if (n == 0) return error.EndOfStream;
        try raw.appendSlice(alloc, buf[0..n]);
        if (raw.items.len > max_http_request) return error.RequestTooLarge;
    }

    const owned = try raw.toOwnedSlice(alloc);
    errdefer alloc.free(owned);
    const headers = owned[0..header_end.?];
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    const request_line = lines.next() orelse return error.BadRequest;
    var parts = std.mem.splitScalar(u8, request_line, ' ');
    const method = parts.next() orelse return error.BadRequest;
    const target = parts.next() orelse return error.BadRequest;
    _ = parts.next() orelse return error.BadRequest;

    var authorization: ?[]const u8 = null;
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "Authorization")) authorization = value;
    }

    const q = std.mem.indexOfScalar(u8, target, '?');
    const path = if (q) |idx| target[0..idx] else target;
    const query = if (q) |idx| target[idx + 1 ..] else "";
    return .{
        .raw = owned,
        .method = method,
        .target = target,
        .path = path,
        .query = query,
        .body = owned[body_start .. body_start + content_len],
        .authorization = authorization,
    };
}

fn parseContentLength(headers: []const u8) ?usize {
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        if (!std.ascii.eqlIgnoreCase(name, "Content-Length")) continue;
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        return std.fmt.parseInt(usize, value, 10) catch null;
    }
    return null;
}

fn dispatchHttp(
    alloc: std.mem.Allocator,
    stream: std.net.Stream,
    req: HttpRequest,
    cfg: ServeConfig,
) !void {
    if (std.mem.eql(u8, req.method, "GET") and std.mem.eql(u8, req.path, "/v1/health")) {
        return sendJson(stream, 200, "{\"ok\":true,\"service\":\"moo\"}\n");
    }
    if (!authorized(req, cfg)) {
        return sendError(stream, 401, "unauthorized", "missing or invalid bearer token");
    }

    var seg_buf: [8][]const u8 = undefined;
    const segs = splitPath(req.path, &seg_buf);
    if (segs.len == 2 and eqlSegs(segs, &.{ "v1", "workspaces" }) and std.mem.eql(u8, req.method, "GET")) {
        return handleWorkspaces(alloc, stream);
    }
    if (segs.len >= 4 and std.mem.eql(u8, segs[0], "v1") and std.mem.eql(u8, segs[1], "workspaces") and
        std.mem.eql(u8, segs[3], "sessions"))
    {
        const workspace = workspaceFromSegment(segs[2]) catch
            return sendError(stream, 400, "bad_workspace", "invalid workspace segment");
        if (segs.len == 4) {
            if (std.mem.eql(u8, req.method, "GET")) return handleListSessions(alloc, stream, workspace);
            if (std.mem.eql(u8, req.method, "POST")) return handleCreateSession(alloc, stream, workspace, req.body);
        } else if (segs.len >= 5) {
            const want = segs[4];
            if (segs.len == 5) {
                if (std.mem.eql(u8, req.method, "GET")) return handleSessionInfo(alloc, stream, workspace, want);
                if (std.mem.eql(u8, req.method, "PATCH")) return handleRenameSession(alloc, stream, workspace, want, req.body);
                if (std.mem.eql(u8, req.method, "DELETE")) return handleDeleteSession(alloc, stream, workspace, want);
            } else if (segs.len == 6) {
                const action = segs[5];
                if (std.mem.eql(u8, action, "input") and std.mem.eql(u8, req.method, "POST")) {
                    return handleInput(alloc, stream, workspace, want, req.body);
                }
                if (std.mem.eql(u8, action, "screen") and std.mem.eql(u8, req.method, "GET")) {
                    return handleScreen(alloc, stream, workspace, want, req.query);
                }
                if (std.mem.eql(u8, action, "wait") and std.mem.eql(u8, req.method, "POST")) {
                    return handleWait(alloc, stream, workspace, want, req.body);
                }
                if (std.mem.eql(u8, action, "resize") and std.mem.eql(u8, req.method, "POST")) {
                    return handleResize(alloc, stream, workspace, want, req.body);
                }
                if (std.mem.eql(u8, action, "transcript") and std.mem.eql(u8, req.method, "GET")) {
                    return handleTranscript(alloc, stream, workspace, want);
                }
                if (std.mem.eql(u8, action, "events") and std.mem.eql(u8, req.method, "GET")) {
                    return handleEvents(alloc, stream, workspace, want, req.query);
                }
            }
        }
    }
    return sendError(stream, 404, "not_found", "unknown endpoint");
}

fn authorized(req: HttpRequest, cfg: ServeConfig) bool {
    const token = cfg.token orelse return true;
    const header = req.authorization orelse return false;
    if (!std.mem.startsWith(u8, header, "Bearer ")) return false;
    return std.mem.eql(u8, header["Bearer ".len..], token);
}

fn splitPath(path: []const u8, buf: *[8][]const u8) []const []const u8 {
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |seg| {
        if (seg.len == 0) continue;
        if (count >= buf.len) break;
        buf[count] = seg;
        count += 1;
    }
    return buf[0..count];
}

fn eqlSegs(segs: []const []const u8, want: []const []const u8) bool {
    if (segs.len != want.len) return false;
    for (segs, want) |a, b| {
        if (!std.mem.eql(u8, a, b)) return false;
    }
    return true;
}

fn workspaceFromSegment(segment: []const u8) !?[]const u8 {
    if (std.mem.eql(u8, segment, "@default")) return null;
    try paths.validateName(segment);
    return segment;
}

fn workspaceDirHttp(alloc: std.mem.Allocator, workspace: ?[]const u8) ![]u8 {
    return paths.socketDirFor(alloc, workspace);
}

fn handleWorkspaces(alloc: std.mem.Allocator, stream: std.net.Stream) !void {
    const base = try paths.socketDir(alloc);
    defer alloc.free(base);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"workspaces\":[");
    try appendWorkspaceJson(alloc, &out, "@default", "", try countSessions(alloc, base));

    const ws_root = try std.fs.path.join(alloc, &.{ base, "ws" });
    defer alloc.free(ws_root);
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |n| alloc.free(n);
        names.deinit(alloc);
    }
    if (std.fs.cwd().openDir(ws_root, .{ .iterate = true })) |dir_const| {
        var dir = dir_const;
        defer dir.close();
        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .directory) continue;
            paths.validateName(entry.name) catch continue;
            try names.append(alloc, try alloc.dupe(u8, entry.name));
        }
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    std.mem.sort([]u8, names.items, {}, struct {
        fn lessThan(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    for (names.items) |name| {
        const dir = try std.fs.path.join(alloc, &.{ ws_root, name });
        defer alloc.free(dir);
        try out.append(alloc, ',');
        try appendWorkspaceJson(alloc, &out, name, name, try countSessions(alloc, dir));
    }
    try out.appendSlice(alloc, "]}\n");
    return sendOwnedJson(alloc, stream, 200, &out);
}

fn appendWorkspaceJson(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    id: []const u8,
    name: []const u8,
    sessions: usize,
) !void {
    try out.appendSlice(alloc, "{\"id\":");
    try appendJsonString(alloc, out, id);
    try out.appendSlice(alloc, ",\"workspace\":");
    try appendJsonString(alloc, out, name);
    try out.print(alloc, ",\"sessions\":{d}}}", .{sessions});
}

fn handleListSessions(alloc: std.mem.Allocator, stream: std.net.Stream, workspace: ?[]const u8) !void {
    const dir = try workspaceDirHttp(alloc, workspace);
    defer alloc.free(dir);
    const sessions = try paths.listSessions(alloc, dir);
    defer {
        for (sessions) |s| alloc.free(s);
        alloc.free(sessions);
    }
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"sessions\":[");
    var emitted = false;
    for (sessions) |name| {
        const info = try sessionInfo(alloc, dir, name) orelse continue;
        defer alloc.free(info.text);
        if (emitted) try out.append(alloc, ',');
        emitted = true;
        try appendSessionInfoJson(alloc, &out, name, info, null);
    }
    try out.appendSlice(alloc, "]}\n");
    return sendOwnedJson(alloc, stream, 200, &out);
}

fn handleCreateSession(
    alloc: std.mem.Allocator,
    stream: std.net.Stream,
    workspace: ?[]const u8,
    body: []const u8,
) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch
        return sendError(stream, 400, "bad_json", "request body must be a JSON object");
    defer parsed.deinit();
    if (parsed.value != .object) return sendError(stream, 400, "bad_json", "request body must be a JSON object");

    const dir = try workspaceDirHttp(alloc, workspace);
    defer alloc.free(dir);
    var name_buf: [paths.max_name_len]u8 = undefined;
    const requested = jsonString(parsed.value, "name");
    const name = requested orelse paths.defaultName(&name_buf, dir);
    const agent = if (jsonString(parsed.value, "agent")) |agent_id| blk: {
        break :blk harness.Agent.fromId(agent_id) orelse
            return sendError(stream, 400, "bad_agent", "unknown agent");
    } else null;
    const rows = jsonU16(parsed.value, "rows") orelse 24;
    const cols = jsonU16(parsed.value, "cols") orelse 80;
    const argv = jsonArgv(alloc, parsed.value) catch |err| switch (err) {
        error.BadArgv => return sendError(stream, 400, "bad_argv", "argv or command must be an array of strings"),
        else => return err,
    };
    defer alloc.free(argv);

    const prev_close_fd = session_child_close_fd;
    session_child_close_fd = stream.handle;
    defer session_child_close_fd = prev_close_fd;
    startSessionNamed(alloc, dir, name, agent, workspace, argv, rows, cols) catch |err| switch (err) {
        error.InvalidSessionName => return sendError(stream, 400, "bad_session_name", "invalid session name"),
        error.SessionExists => return sendError(stream, 409, "session_exists", "session already exists"),
        else => return err,
    };
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"session\":");
    try appendJsonString(alloc, &out, name);
    try out.appendSlice(alloc, ",\"workspace\":");
    try appendJsonString(alloc, &out, workspace orelse "");
    try out.appendSlice(alloc, ",\"created\":true}\n");
    return sendOwnedJson(alloc, stream, 201, &out);
}

fn jsonArgv(alloc: std.mem.Allocator, root: std.json.Value) ![]const []const u8 {
    const value = if (root == .object)
        root.object.get("argv") orelse root.object.get("command")
    else
        null;
    const arr = if (value) |v| switch (v) {
        .array => |a| a,
        else => return error.BadArgv,
    } else return alloc.alloc([]const u8, 0);
    var out = try alloc.alloc([]const u8, arr.items.len);
    errdefer alloc.free(out);
    for (arr.items, 0..) |item, idx| {
        out[idx] = switch (item) {
            .string => |s| s,
            else => return error.BadArgv,
        };
    }
    return out;
}

fn handleResize(
    alloc: std.mem.Allocator,
    stream: std.net.Stream,
    workspace: ?[]const u8,
    want: []const u8,
    body: []const u8,
) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch
        return sendError(stream, 400, "bad_json", "request body must be JSON");
    defer parsed.deinit();
    const rows = jsonU16(parsed.value, "rows") orelse
        return sendError(stream, 400, "bad_resize", "rows is required");
    const cols = jsonU16(parsed.value, "cols") orelse
        return sendError(stream, 400, "bad_resize", "cols is required");

    const dir = try workspaceDirHttp(alloc, workspace);
    defer alloc.free(dir);
    const name = resolveSessionResult(alloc, dir, want) catch |err| return sendResolveError(stream, err);
    defer alloc.free(name);
    var rows_buf: [16]u8 = undefined;
    var cols_buf: [16]u8 = undefined;
    const rows_s = try std.fmt.bufPrint(&rows_buf, "{d}", .{rows});
    const cols_s = try std.fmt.bufPrint(&cols_buf, "{d}", .{cols});
    const result = try controlSession(alloc, dir, name, &.{ "resize", rows_s, cols_s });
    defer alloc.free(result.text);
    if (!result.ok) return sendError(stream, 400, "resize_failed", result.text);
    return sendJson(stream, 200, "{\"resized\":true}\n");
}

fn handleSessionInfo(
    alloc: std.mem.Allocator,
    stream: std.net.Stream,
    workspace: ?[]const u8,
    want: []const u8,
) !void {
    const dir = try workspaceDirHttp(alloc, workspace);
    defer alloc.free(dir);
    const name = resolveSessionResult(alloc, dir, want) catch |err| return sendResolveError(stream, err);
    defer alloc.free(name);
    const info = try sessionInfo(alloc, dir, name) orelse
        return sendError(stream, 404, "not_found", "session not found");
    defer alloc.free(info.text);
    const state = try sessionState(alloc, dir, name) orelse null;
    defer if (state) |s| alloc.free(s.text);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try appendSessionInfoJson(alloc, &out, name, info, if (state) |s| s.event_seq else null);
    try out.append(alloc, '\n');
    return sendOwnedJson(alloc, stream, 200, &out);
}

fn appendSessionInfoJson(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    name: []const u8,
    info: SessionInfo,
    event_seq: ?u64,
) !void {
    try out.appendSlice(alloc, "{\"name\":");
    try appendJsonString(alloc, out, name);
    try out.print(alloc, ",\"attached\":{},\"idle_ms\":{d},\"out_idle_ms\":{d},\"title\":", .{
        info.attached,
        info.idle_ms,
        info.out_idle_ms,
    });
    try appendJsonString(alloc, out, info.title);
    if (event_seq) |seq| try out.print(alloc, ",\"cursor\":{d}", .{seq});
    try out.append(alloc, '}');
}

fn handleRenameSession(
    alloc: std.mem.Allocator,
    stream: std.net.Stream,
    workspace: ?[]const u8,
    want: []const u8,
    body: []const u8,
) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch
        return sendError(stream, 400, "bad_json", "request body must be JSON");
    defer parsed.deinit();
    const new_name = jsonString(parsed.value, "name") orelse
        return sendError(stream, 400, "bad_request", "name is required");
    paths.validateName(new_name) catch
        return sendError(stream, 400, "bad_session_name", "invalid session name");
    const dir = try workspaceDirHttp(alloc, workspace);
    defer alloc.free(dir);
    const name = resolveSessionResult(alloc, dir, want) catch |err| return sendResolveError(stream, err);
    defer alloc.free(name);
    const result = try controlSession(alloc, dir, name, &.{ "rename", new_name });
    defer alloc.free(result.text);
    if (!result.ok) return sendError(stream, 409, "rename_failed", result.text);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"session\":");
    try appendJsonString(alloc, &out, new_name);
    try out.appendSlice(alloc, ",\"renamed\":true}\n");
    return sendOwnedJson(alloc, stream, 200, &out);
}

fn handleDeleteSession(
    alloc: std.mem.Allocator,
    stream: std.net.Stream,
    workspace: ?[]const u8,
    want: []const u8,
) !void {
    const dir = try workspaceDirHttp(alloc, workspace);
    defer alloc.free(dir);
    const name = resolveSessionResult(alloc, dir, want) catch |err| return sendResolveError(stream, err);
    defer alloc.free(name);
    const result = try controlSession(alloc, dir, name, &.{"quit"});
    defer alloc.free(result.text);
    if (!result.ok) return sendError(stream, 500, "delete_failed", result.text);
    removeAgentSession(alloc, dir, name);
    return sendJson(stream, 200, "{\"deleted\":true}\n");
}

fn handleInput(
    alloc: std.mem.Allocator,
    stream: std.net.Stream,
    workspace: ?[]const u8,
    want: []const u8,
    body: []const u8,
) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch
        return sendError(stream, 400, "bad_json", "request body must be JSON");
    defer parsed.deinit();
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(alloc);
    if (jsonString(parsed.value, "text")) |text| try payload.appendSlice(alloc, text);
    if (jsonString(parsed.value, "base64")) |encoded| {
        const size = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch
            return sendError(stream, 400, "bad_base64", "base64 input is invalid");
        const start = payload.items.len;
        try payload.resize(alloc, start + size);
        std.base64.standard.Decoder.decode(payload.items[start..], encoded) catch
            return sendError(stream, 400, "bad_base64", "base64 input is invalid");
    }
    if (jsonString(parsed.value, "key")) |key_name| {
        if (!appendKey(alloc, &payload, key_name)) {
            return sendError(stream, 400, "bad_key", "unknown key");
        }
    }
    if (parsed.value == .object) {
        if (parsed.value.object.get("keys")) |value| switch (value) {
            .array => |arr| for (arr.items) |item| {
                const key_name = switch (item) {
                    .string => |s| s,
                    else => return sendError(stream, 400, "bad_key", "keys must be strings"),
                };
                if (!appendKey(alloc, &payload, key_name)) return sendError(stream, 400, "bad_key", "unknown key");
            },
            else => return sendError(stream, 400, "bad_key", "keys must be an array"),
        };
    }
    if (jsonBool(parsed.value, "enter") orelse false) try payload.append(alloc, '\r');
    if (payload.items.len == 0) return sendError(stream, 400, "empty_input", "nothing to send");
    if (std.mem.indexOfScalar(u8, payload.items, 0) != null) {
        return sendError(stream, 400, "nul_input", "NUL bytes are not supported by v1 input");
    }

    const dir = try workspaceDirHttp(alloc, workspace);
    defer alloc.free(dir);
    const name = resolveSessionResult(alloc, dir, want) catch |err| return sendResolveError(stream, err);
    defer alloc.free(name);
    const result = try controlSession(alloc, dir, name, &.{ "send", payload.items });
    defer alloc.free(result.text);
    if (!result.ok) return sendError(stream, 500, "input_failed", result.text);
    return sendJson(stream, 200, "{\"sent\":true}\n");
}

fn handleScreen(
    alloc: std.mem.Allocator,
    stream: std.net.Stream,
    workspace: ?[]const u8,
    want: []const u8,
    query: []const u8,
) !void {
    const scrollback = if (queryParam(query, "scrollback")) |v|
        std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1")
    else
        false;
    const dir = try workspaceDirHttp(alloc, workspace);
    defer alloc.free(dir);
    const name = resolveSessionResult(alloc, dir, want) catch |err| return sendResolveError(stream, err);
    defer alloc.free(name);
    const result = try controlSession(alloc, dir, name, &.{ "peek", if (scrollback) "scrollback" else "screen" });
    defer alloc.free(result.text);
    if (!result.ok) return sendError(stream, 500, "screen_failed", result.text);
    const peek = parsePeek(result.text) orelse return sendError(stream, 500, "bad_daemon_response", "malformed screen response");
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"session\":");
    try appendJsonString(alloc, &out, name);
    try out.appendSlice(alloc, ",\"title\":");
    try appendJsonString(alloc, &out, peek.title);
    try out.print(alloc, ",\"rows\":{d},\"cols\":{d},\"cursor\":{{\"row\":{d},\"col\":{d}}},\"screen\":", .{
        peek.rows,
        peek.cols,
        peek.cursor_row,
        peek.cursor_col,
    });
    try appendJsonString(alloc, &out, peek.screen);
    try out.appendSlice(alloc, "}\n");
    return sendOwnedJson(alloc, stream, 200, &out);
}

fn handleWait(
    alloc: std.mem.Allocator,
    stream: std.net.Stream,
    workspace: ?[]const u8,
    want: []const u8,
    body: []const u8,
) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch
        return sendError(stream, 400, "bad_json", "request body must be JSON");
    defer parsed.deinit();
    const text = jsonString(parsed.value, "text");
    const idle = jsonBool(parsed.value, "idle") orelse false;
    if ((text != null) == idle) return sendError(stream, 400, "bad_wait", "set exactly one of text or idle");
    const timeout_text = jsonString(parsed.value, "timeout") orelse "30s";
    const timeout_ms = parseDurationMs(timeout_text) orelse
        return sendError(stream, 400, "bad_timeout", "bad timeout duration");

    const dir = try workspaceDirHttp(alloc, workspace);
    defer alloc.free(dir);
    const name = resolveSessionResult(alloc, dir, want) catch |err| return sendResolveError(stream, err);
    defer alloc.free(name);
    const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
    while (true) {
        if (text) |needle| {
            const result = try controlSession(alloc, dir, name, &.{ "peek", "screen" });
            defer alloc.free(result.text);
            if (!result.ok) return sendError(stream, 500, "wait_failed", result.text);
            const peek = parsePeek(result.text) orelse return sendError(stream, 500, "bad_daemon_response", "malformed screen response");
            if (std.mem.indexOf(u8, peek.screen, needle) != null) {
                return sendJson(stream, 200, "{\"matched\":true}\n");
            }
        } else {
            const info = try sessionInfo(alloc, dir, name) orelse
                return sendError(stream, 404, "not_found", "session not found");
            defer alloc.free(info.text);
            if (info.out_idle_ms >= idle_settle_ms) return sendJson(stream, 200, "{\"idle\":true}\n");
        }
        if (std.time.milliTimestamp() >= deadline) {
            return sendError(stream, 408, "timeout", "wait timed out");
        }
        std.Thread.sleep(50 * std.time.ns_per_ms);
    }
}

fn handleTranscript(
    alloc: std.mem.Allocator,
    stream: std.net.Stream,
    workspace: ?[]const u8,
    want: []const u8,
) !void {
    const dir = try workspaceDirHttp(alloc, workspace);
    defer alloc.free(dir);
    const name = resolveSessionResult(alloc, dir, want) catch |err| return sendResolveError(stream, err);
    defer alloc.free(name);
    const body = liveTranscriptJson(alloc, dir, name, false) catch |err| switch (err) {
        error.NotAgent => return sendError(stream, 404, "not_agent", "session was not started with --agent"),
        error.BadSidecar => return sendError(stream, 500, "bad_sidecar", "corrupt agent sidecar"),
        else => return err,
    };
    defer alloc.free(body);
    return sendJson(stream, 200, body);
}

fn liveTranscriptJson(alloc: std.mem.Allocator, dir: []const u8, name: []const u8, thinking: bool) ![]u8 {
    const sc_path = try paths.sidecarPath(alloc, dir, name);
    defer alloc.free(sc_path);
    const sc_data = readTranscript(alloc, sc_path) orelse return error.NotAgent;
    defer alloc.free(sc_data);
    const sc = harness.Sidecar.fromJson(alloc, sc_data) catch return error.BadSidecar;
    defer sc.deinit(alloc);

    const t_path = sc.agent.transcriptPath(alloc, sc) catch null;
    defer if (t_path) |p| alloc.free(p);
    const data = if (t_path) |p| (readTranscript(alloc, p) orelse try alloc.dupe(u8, "")) else try alloc.dupe(u8, "");
    defer alloc.free(data);
    var report = try sc.agent.detect(alloc, data);
    defer report.deinit(alloc);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"session\":");
    try appendJsonString(alloc, &out, name);
    try out.appendSlice(alloc, ",\"agent\":");
    try appendJsonString(alloc, &out, sc.agent.id());
    try out.appendSlice(alloc, ",\"state\":");
    try appendJsonString(alloc, &out, report.state.asStr());
    if (report.stop_reason) |s| {
        try out.appendSlice(alloc, ",\"stop_reason\":");
        try appendJsonString(alloc, &out, s);
    }
    if (report.detail) |d| {
        try out.appendSlice(alloc, ",\"detail\":");
        try appendJsonString(alloc, &out, d);
    }
    try out.print(alloc, ",\"messages\":{d},\"transcript\":", .{report.messages});
    const arr = try sc.agent.dumpJson(alloc, data, thinking);
    defer alloc.free(arr);
    try out.appendSlice(alloc, std.mem.trimRight(u8, arr, " \n"));
    try out.appendSlice(alloc, "}\n");
    return out.toOwnedSlice(alloc);
}

fn handleEvents(
    alloc: std.mem.Allocator,
    stream: std.net.Stream,
    workspace: ?[]const u8,
    want: []const u8,
    query: []const u8,
) !void {
    const since = if (queryParam(query, "since")) |v| std.fmt.parseInt(u64, v, 10) catch 0 else 0;
    const timeout_ms = if (queryParam(query, "timeout")) |v| parseDurationMs(v) orelse 0 else 0;
    const dir = try workspaceDirHttp(alloc, workspace);
    defer alloc.free(dir);
    const name = resolveSessionResult(alloc, dir, want) catch |err| return sendResolveError(stream, err);
    defer alloc.free(name);
    const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
    while (true) {
        const state = try sessionState(alloc, dir, name) orelse
            return sendError(stream, 404, "not_found", "session not found");
        defer alloc.free(state.text);
        if (since == 0 or state.event_seq > since or since > state.event_seq) {
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(alloc);
            try out.print(alloc, "{{\"cursor\":{d},\"events\":[", .{state.event_seq});
            if (since == 0 or state.event_seq > since) {
                try out.appendSlice(alloc, "{\"type\":\"session_state\",\"cursor\":");
                try out.print(alloc, "{d}", .{state.event_seq});
                try out.appendSlice(alloc, ",\"title\":");
                try appendJsonString(alloc, &out, state.title);
                try out.append(alloc, '}');
            }
            try out.appendSlice(alloc, "]");
            if (since > state.event_seq) try out.appendSlice(alloc, ",\"stale\":true");
            try out.appendSlice(alloc, "}\n");
            return sendOwnedJson(alloc, stream, 200, &out);
        }
        if (std.time.milliTimestamp() >= deadline) {
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(alloc);
            try out.print(alloc, "{{\"cursor\":{d},\"events\":[],\"timed_out\":true}}\n", .{since});
            return sendOwnedJson(alloc, stream, 200, &out);
        }
        std.Thread.sleep(50 * std.time.ns_per_ms);
    }
}

fn sessionState(alloc: std.mem.Allocator, dir: []const u8, name: []const u8) !?SessionState {
    const result = controlSession(alloc, dir, name, &.{"state"}) catch |err| switch (err) {
        error.NoSession => return null,
        else => return err,
    };
    errdefer alloc.free(result.text);
    if (!result.ok) return error.BadResponse;
    var rest: []const u8 = result.text;
    _ = cutTab(&rest) orelse return error.BadResponse;
    const attached = std.mem.eql(u8, cutTab(&rest) orelse return error.BadResponse, "Attached");
    const idle_ms = std.fmt.parseInt(i64, cutTab(&rest) orelse return error.BadResponse, 10) catch
        return error.BadResponse;
    const out_idle_ms = std.fmt.parseInt(i64, cutTab(&rest) orelse return error.BadResponse, 10) catch
        return error.BadResponse;
    const rows = std.fmt.parseInt(u32, cutTab(&rest) orelse return error.BadResponse, 10) catch
        return error.BadResponse;
    const cols = std.fmt.parseInt(u32, cutTab(&rest) orelse return error.BadResponse, 10) catch
        return error.BadResponse;
    const event_seq = std.fmt.parseInt(u64, cutTab(&rest) orelse return error.BadResponse, 10) catch
        return error.BadResponse;
    return .{
        .text = result.text,
        .attached = attached,
        .idle_ms = idle_ms,
        .out_idle_ms = out_idle_ms,
        .rows = rows,
        .cols = cols,
        .event_seq = event_seq,
        .title = rest,
    };
}

fn queryParam(query: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |part| {
        const eq = std.mem.indexOfScalar(u8, part, '=') orelse continue;
        if (std.mem.eql(u8, part[0..eq], key)) return part[eq + 1 ..];
    }
    return null;
}

fn jsonString(root: std.json.Value, key: []const u8) ?[]const u8 {
    if (root != .object) return null;
    const value = root.object.get(key) orelse return null;
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

fn jsonBool(root: std.json.Value, key: []const u8) ?bool {
    if (root != .object) return null;
    const value = root.object.get(key) orelse return null;
    return switch (value) {
        .bool => |b| b,
        else => null,
    };
}

fn jsonU16(root: std.json.Value, key: []const u8) ?u16 {
    if (root != .object) return null;
    const value = root.object.get(key) orelse return null;
    return switch (value) {
        .integer => |n| if (n > 0 and n <= std.math.maxInt(u16)) @intCast(n) else null,
        else => null,
    };
}

fn sendResolveError(stream: std.net.Stream, err: anyerror) !void {
    return switch (err) {
        error.NoSession => sendError(stream, 404, "not_found", "session not found"),
        error.AmbiguousSession => sendError(stream, 409, "ambiguous_session", "session prefix is ambiguous"),
        else => err,
    };
}

fn sendOwnedJson(
    alloc: std.mem.Allocator,
    stream: std.net.Stream,
    status: u16,
    out: *std.ArrayList(u8),
) !void {
    const body = try out.toOwnedSlice(alloc);
    defer alloc.free(body);
    return sendJson(stream, status, body);
}

fn sendError(stream: std.net.Stream, status: u16, code: []const u8, message: []const u8) !void {
    const alloc = std.heap.c_allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"error\":{\"code\":");
    try appendJsonString(alloc, &out, code);
    try out.appendSlice(alloc, ",\"message\":");
    try appendJsonString(alloc, &out, message);
    try out.appendSlice(alloc, "}}\n");
    return sendJson(stream, status, out.items);
}

fn sendJson(stream: std.net.Stream, status: u16, body: []const u8) !void {
    var header_buf: [256]u8 = undefined;
    const status_text = switch (status) {
        200 => "OK",
        201 => "Created",
        400 => "Bad Request",
        401 => "Unauthorized",
        404 => "Not Found",
        408 => "Request Timeout",
        409 => "Conflict",
        500 => "Internal Server Error",
        else => "OK",
    };
    const header = try std.fmt.bufPrint(
        &header_buf,
        "HTTP/1.1 {d} {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
        .{ status, status_text, body.len },
    );
    try stream.writeAll(header);
    try stream.writeAll(body);
}

fn cmdVersion(alloc: std.mem.Allocator) !void {
    try stdoutPrint(alloc, "moo {s}\n", .{version});
}

fn cmdHelp(alloc: std.mem.Allocator, args: []const [:0]const u8) !void {
    _ = alloc;
    if (args.len == 0) return stdoutWrite(help.overview);
    if (args.len > 1) usageFail("help", "expected one help page", .{});

    const topic = args[0];
    if (std.mem.eql(u8, topic, "--all")) {
        try stdoutWrite(help.overview);
        for (&help.commands) |*entry| {
            try stdoutWrite("\n");
            try stdoutWrite(entry.body);
        }
        for (&help.topics) |*entry| {
            try stdoutWrite("\n");
            try stdoutWrite(entry.body);
        }
        return;
    }
    if (help.find(topic)) |entry| return stdoutWrite(entry.body);
    usageFail("help", "no help for '{s}'", .{topic});
}

// -- Output helpers -------------------------------------------------------

fn appendPadded(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    text: []const u8,
    width: usize,
) !void {
    try out.appendSlice(alloc, text);
    var i = text.len;
    while (i < width) : (i += 1) try out.append(alloc, ' ');
}

/// Append a JSON string literal, escaping per RFC 8259.
fn appendJsonString(alloc: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    try out.append(alloc, '"');
    for (s) |byte| {
        switch (byte) {
            '"' => try out.appendSlice(alloc, "\\\""),
            '\\' => try out.appendSlice(alloc, "\\\\"),
            '\n' => try out.appendSlice(alloc, "\\n"),
            '\r' => try out.appendSlice(alloc, "\\r"),
            '\t' => try out.appendSlice(alloc, "\\t"),
            else => {
                if (byte < 0x20) {
                    var buf: [8]u8 = undefined;
                    const esc = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{byte}) catch unreachable;
                    try out.appendSlice(alloc, esc);
                } else {
                    try out.append(alloc, byte);
                }
            },
        }
    }
    try out.append(alloc, '"');
}

/// Parse a duration like 500ms, 2s, 1m, 4h (or 4hr), 1d. Returns
/// milliseconds.
fn parseDurationMs(s: []const u8) ?u64 {
    const Unit = struct { suffix: []const u8, ms: u64 };
    // "ms" must match before "s", and "hr" before "h".
    const units = [_]Unit{
        .{ .suffix = "ms", .ms = 1 },
        .{ .suffix = "hr", .ms = std.time.ms_per_hour },
        .{ .suffix = "s", .ms = std.time.ms_per_s },
        .{ .suffix = "m", .ms = std.time.ms_per_min },
        .{ .suffix = "h", .ms = std.time.ms_per_hour },
        .{ .suffix = "d", .ms = std.time.ms_per_day },
    };
    for (units) |unit| {
        if (std.mem.endsWith(u8, s, unit.suffix)) {
            const n = std.fmt.parseInt(u64, s[0 .. s.len - unit.suffix.len], 10) catch return null;
            return std.math.mul(u64, n, unit.ms) catch null;
        }
    }
    return null;
}

/// Human idle durations for `ls`: 12s, 5m, 3h.
fn fmtIdle(buf: []u8, ms: i64) []const u8 {
    const s = @divTrunc(@max(0, ms), std.time.ms_per_s);
    if (s < 60) return std.fmt.bufPrint(buf, "{d}s", .{s}) catch "?";
    if (s < 3600) return std.fmt.bufPrint(buf, "{d}m", .{@divTrunc(s, 60)}) catch "?";
    return std.fmt.bufPrint(buf, "{d}h", .{@divTrunc(s, 3600)}) catch "?";
}

// -- Daemon plumbing ------------------------------------------------------

fn runDaemon(
    alloc: std.mem.Allocator,
    name: []const u8,
    sock: []const u8,
    listen_fd: posix.fd_t,
    argv: []const []const u8,
    env_overrides: []const [2][]const u8,
    rows: u16,
    cols: u16,
) noreturn {
    _ = posix.setsid() catch {};

    // Detach stdio. Keep stderr pointed at MOO_LOG if set so std.log
    // output is preserved for debugging.
    const devnull = posix.open("/dev/null", .{ .ACCMODE = .RDWR }, 0) catch posix.exit(1);
    posix.dup2(devnull, 0) catch {};
    posix.dup2(devnull, 1) catch {};
    if (posix.getenv("MOO_LOG")) |log_path| blk: {
        const fd = posix.open(log_path, .{
            .ACCMODE = .WRONLY,
            .CREAT = true,
            .APPEND = true,
        }, 0o600) catch break :blk;
        posix.dup2(fd, 2) catch {};
        posix.close(fd);
    } else {
        posix.dup2(devnull, 2) catch {};
    }
    if (devnull > 2) posix.close(devnull);

    daemonpkg.Daemon.run(alloc, .{
        .name = name,
        .socket_path = sock,
        .listen_fd = listen_fd,
        .argv = argv,
        .env_overrides = env_overrides,
        .rows = rows,
        .cols = cols,
    }) catch |err| {
        std.log.err("daemon failed: {}", .{err});
        posix.exit(1);
    };
    posix.exit(0);
}

fn bindListen(alloc: std.mem.Allocator, sock_path: []const u8) !posix.fd_t {
    const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
    errdefer posix.close(fd);

    var addr: posix.sockaddr.un = .{ .family = posix.AF.UNIX, .path = undefined };
    if (sock_path.len >= addr.path.len) return error.NameTooLong;
    @memset(&addr.path, 0);
    @memcpy(addr.path[0..sock_path.len], sock_path);

    posix.bind(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) catch |err| switch (err) {
        error.AddressInUse => {
            // Either a live session or a stale socket file.
            if (client.connect(alloc, sock_path)) |probe| {
                posix.close(probe);
                return error.SessionExists;
            } else |_| {
                try std.fs.cwd().deleteFile(sock_path);
                try posix.bind(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));
            }
        },
        else => return err,
    };

    try posix.listen(fd, 8);
    return fd;
}

// -- Tests ----------------------------------------------------------------

test "parseDurationMs" {
    try std.testing.expectEqual(@as(?u64, 500), parseDurationMs("500ms"));
    try std.testing.expectEqual(@as(?u64, 2000), parseDurationMs("2s"));
    try std.testing.expectEqual(@as(?u64, 60_000), parseDurationMs("1m"));
    try std.testing.expectEqual(@as(?u64, 4 * 3_600_000), parseDurationMs("4h"));
    try std.testing.expectEqual(@as(?u64, 4 * 3_600_000), parseDurationMs("4hr"));
    try std.testing.expectEqual(@as(?u64, 10 * 86_400_000), parseDurationMs("10d"));
    try std.testing.expectEqual(@as(?u64, null), parseDurationMs("2"));
    try std.testing.expectEqual(@as(?u64, null), parseDurationMs("s"));
    try std.testing.expectEqual(@as(?u64, null), parseDurationMs("hr"));
    try std.testing.expectEqual(@as(?u64, null), parseDurationMs("2x"));
}

test "appendKey named keys" {
    const alloc = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try std.testing.expect(appendKey(alloc, &out, "Enter"));
    try std.testing.expect(appendKey(alloc, &out, "C-c"));
    try std.testing.expect(appendKey(alloc, &out, "up"));
    try std.testing.expectEqualStrings("\r\x03\x1b[A", out.items);
    try std.testing.expect(!appendKey(alloc, &out, "C-1"));
    try std.testing.expect(!appendKey(alloc, &out, "banana"));
}

test "appendJsonString escapes" {
    const alloc = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try appendJsonString(alloc, &out, "a\"b\\c\nd\x01");
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\\nd\\u0001\"", out.items);
}

test "parsePeek" {
    const peek = parsePeek("24\t80\t3\t7\tvim\nline1\nline2").?;
    try std.testing.expectEqual(@as(u32, 24), peek.rows);
    try std.testing.expectEqual(@as(u32, 80), peek.cols);
    try std.testing.expectEqual(@as(u32, 3), peek.cursor_row);
    try std.testing.expectEqual(@as(u32, 7), peek.cursor_col);
    try std.testing.expectEqualStrings("vim", peek.title);
    try std.testing.expectEqualStrings("line1\nline2", peek.screen);
}

test "fmtIdle" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("0s", fmtIdle(&buf, 400));
    try std.testing.expectEqualStrings("12s", fmtIdle(&buf, 12_500));
    try std.testing.expectEqualStrings("5m", fmtIdle(&buf, 5 * 60_000));
    try std.testing.expectEqualStrings("2h", fmtIdle(&buf, 2 * 3_600_000));
}

test {
    _ = @import("protocol.zig");
    _ = @import("paths.zig");
    _ = @import("keys.zig");
    _ = @import("pty.zig");
    _ = @import("altscreen.zig");
    _ = @import("window.zig");
    _ = @import("daemon.zig");
    _ = @import("client.zig");
    _ = @import("help.zig");
    _ = @import("ui.zig");
    _ = @import("harness.zig");
}
