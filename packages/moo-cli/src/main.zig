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
const slash = @import("slash.zig");
const ui = @import("ui.zig");

pub const version = "0.5.20";
const mcp_server_exe = "moo-mcp-server";

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
    if (eql(cmd, "workspace") or eql(cmd, "ws")) return cmdWorkspace(alloc, rest);
    if (eql(cmd, "send")) return cmdSend(alloc, rest);
    if (eql(cmd, "slash")) return cmdSlash(alloc, rest);
    if (eql(cmd, "peek")) return cmdPeek(alloc, rest);
    if (eql(cmd, "read")) return cmdRead(alloc, rest);
    if (eql(cmd, "wait")) return cmdWait(alloc, rest);
    if (eql(cmd, "kill")) return cmdKill(alloc, rest);
    if (eql(cmd, "rename")) return cmdRename(alloc, rest);
    if (eql(cmd, "serve")) return cmdServe(alloc, rest);
    if (eql(cmd, "mcp")) return cmdMcp(alloc, rest);
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

fn cmdMcp(alloc: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (args.len > 0 and isHelpFlag(args[0])) return printHelpPage("mcp");
    const server = findMcpServer(alloc) catch |err| switch (err) {
        error.FileNotFound => fail(exit_runtime, "cannot find bundled {s}; rebuild or set MOO_MCP_SERVER_BIN", .{mcp_server_exe}),
        else => return err,
    };
    defer alloc.free(server);

    var argv = try alloc.alloc([]const u8, args.len + 1);
    defer alloc.free(argv);
    argv[0] = server;
    for (args, 0..) |arg, idx| argv[idx + 1] = arg;

    var child = std.process.Child.init(argv, alloc);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    const term = child.spawnAndWait() catch |err| {
        fail(exit_runtime, "failed to run {s}: {}", .{ server, err });
    };
    exitWithChildTerm(term);
}

fn findMcpServer(alloc: std.mem.Allocator) ![]u8 {
    if (posix.getenv("MOO_MCP_SERVER_BIN")) |path| return alloc.dupe(u8, path);

    const self_path = try std.fs.selfExePathAlloc(alloc);
    defer alloc.free(self_path);
    if (std.fs.path.dirname(self_path)) |dir| {
        const sibling = try std.fs.path.join(alloc, &.{ dir, mcp_server_exe });
        if (fileExists(sibling)) return sibling;
        alloc.free(sibling);
    }

    const dev = try std.fs.path.join(alloc, &.{ "zig-out", "bin", mcp_server_exe });
    if (fileExists(dev)) return dev;
    alloc.free(dev);

    return error.FileNotFound;
}

fn fileExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn exitWithChildTerm(term: std.process.Child.Term) noreturn {
    switch (term) {
        .Exited => |code| posix.exit(@intCast(@min(code, 255))),
        .Signal => |sig| posix.exit(@intCast(@min(128 + sig, 255))),
        else => posix.exit(exit_runtime),
    }
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

const SessionMeta = struct {
    cwd: ?[]u8 = null,
    created_at_ms: i64 = 0,

    fn deinit(self: SessionMeta, alloc: std.mem.Allocator) void {
        if (self.cwd) |cwd| alloc.free(cwd);
    }
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

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = posix.getcwd(&cwd_buf) catch ".";
    writeSessionMeta(alloc, dir, name, cwd);

    // An agent harness augments the launch command (pinning a session id),
    // supplies per-session env (e.g. CODEX_HOME), and records a sidecar so the
    // transcript can be found by `moo read`. Allocations here live until the
    // forked child execs; the short-lived parent never frees them.
    var argv = cmd_argv;
    var env_overrides: []const [2][]const u8 = &.{};
    if (agent) |ag| {
        const launch = prepareAgent(alloc, dir, name, ag, cmd_argv, cwd);
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
    cwd: []const u8,
) AgentLaunch {
    const fallback: AgentLaunch = .{ .argv = cmd_argv, .env = &.{} };
    const store = paths.storeDir(alloc, dir, name) catch return fallback;
    // Clear any store left by a prior same-named session, so transcript lookup
    // (e.g. codex's newest-rollout glob) can only ever see this session's data.
    std.fs.cwd().deleteTree(store) catch {};
    const prepared = agent.prepare(alloc, cmd_argv, store) catch return fallback;

    const overrides = agent.launchOverrides(alloc, prepared.session_id, cwd, store) catch
        harness.LaunchOverrides{};

    writeSidecar(alloc, dir, name, .{
        .agent = agent,
        .session_id = prepared.session_id,
        .session_store = overrides.session_store,
        .cwd = cwd,
    });
    appendRunHistorySidecar(alloc, dir, name, .{
        .agent = agent,
        .session_id = prepared.session_id,
        .session_store = overrides.session_store,
        .cwd = cwd,
    }, .sidecar, .exact);
    return .{ .argv = prepared.argv, .env = overrides.env };
}

fn writeSessionMeta(
    alloc: std.mem.Allocator,
    dir: []const u8,
    name: []const u8,
    cwd: []const u8,
) void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    out.appendSlice(alloc, "{\"created_at_ms\":") catch return;
    out.print(alloc, "{d},\"cwd\":", .{std.time.milliTimestamp()}) catch return;
    appendJsonString(alloc, &out, cwd) catch return;
    out.appendSlice(alloc, "}\n") catch return;
    const path = paths.sessionMetaPath(alloc, dir, name) catch return;
    defer alloc.free(path);
    std.fs.cwd().writeFile(.{ .sub_path = path, .data = out.items }) catch {};
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
    const sc_path = paths.sidecarPath(alloc, dir, name) catch null;
    if (sc_path) |path| {
        defer alloc.free(path);
        if (readTranscript(alloc, path)) |sc_data| {
            defer alloc.free(sc_data);
            if (harness.Sidecar.fromJson(alloc, sc_data)) |sc| {
                defer sc.deinit(alloc);
                if (sc.session_store) |store| std.fs.cwd().deleteTree(store) catch {};
            } else |_| {}
        }
    }
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

const WorkspaceEntry = struct {
    name: []u8,
    dir: []u8,
};

fn freeWorkspaceEntries(alloc: std.mem.Allocator, entries: []WorkspaceEntry) void {
    for (entries) |entry| {
        alloc.free(entry.name);
        alloc.free(entry.dir);
    }
    alloc.free(entries);
}

fn collectWorkspaces(alloc: std.mem.Allocator) ![]WorkspaceEntry {
    var entries: std.ArrayList(WorkspaceEntry) = .empty;
    errdefer {
        for (entries.items) |entry| {
            alloc.free(entry.name);
            alloc.free(entry.dir);
        }
        entries.deinit(alloc);
    }

    const base = try paths.socketDir(alloc);
    errdefer alloc.free(base);
    try entries.append(alloc, .{
        .name = try alloc.dupe(u8, ""),
        .dir = base,
    });

    const ws_root = try std.fs.path.join(alloc, &.{ base, "ws" });
    defer alloc.free(ws_root);
    if (std.fs.cwd().openDir(ws_root, .{ .iterate = true })) |dir_const| {
        var dir = dir_const;
        defer dir.close();
        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .directory) continue;
            paths.validateName(entry.name) catch continue;
            const name = try alloc.dupe(u8, entry.name);
            errdefer alloc.free(name);
            const ws_dir = try std.fs.path.join(alloc, &.{ ws_root, entry.name });
            errdefer alloc.free(ws_dir);
            try entries.append(alloc, .{ .name = name, .dir = ws_dir });
        }
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    if (entries.items.len > 1) {
        std.mem.sort(WorkspaceEntry, entries.items[1..], {}, struct {
            fn lessThan(_: void, a: WorkspaceEntry, b: WorkspaceEntry) bool {
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.lessThan);
    }
    return entries.toOwnedSlice(alloc);
}

fn workspaceDirExisting(alloc: std.mem.Allocator, workspace: ?[]const u8) ![]u8 {
    const base = try paths.socketDir(alloc);
    if (workspace == null) return base;
    defer alloc.free(base);

    const ws = workspace.?;
    try paths.validateName(ws);
    const dir = try std.fs.path.join(alloc, &.{ base, "ws", ws });
    errdefer alloc.free(dir);
    std.fs.cwd().access(dir, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.NoWorkspace,
        else => return err,
    };
    return dir;
}

fn countSessions(alloc: std.mem.Allocator, dir: []const u8) !usize {
    const sessions = try paths.listSessions(alloc, dir);
    defer {
        for (sessions) |s| alloc.free(s);
        alloc.free(sessions);
    }
    return sessions.len;
}

fn cmdWorkspace(alloc: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (args.len == 0 or std.mem.eql(u8, args[0], "--json")) return cmdWorkspaceList(alloc, args);
    if (isHelpFlag(args[0])) return printHelpPage("workspace");
    if (std.mem.eql(u8, args[0], "list") or std.mem.eql(u8, args[0], "ls")) return cmdWorkspaceList(alloc, args[1..]);
    if (std.mem.eql(u8, args[0], "remove") or std.mem.eql(u8, args[0], "rm")) return cmdWorkspaceRemove(alloc, args[1..]);
    usageFail("workspace", "unknown workspace subcommand '{s}'", .{args[0]});
}

fn cmdWorkspaceList(alloc: std.mem.Allocator, args: []const [:0]const u8) !void {
    var json = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (isHelpFlag(arg)) return printHelpPage("workspace");
        if (std.mem.eql(u8, arg, "--json")) {
            json = true;
        } else {
            usageFail("workspace", "unexpected argument '{s}'", .{arg});
        }
    }

    const entries = try collectWorkspaces(alloc);
    defer freeWorkspaceEntries(alloc, entries);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    if (json) {
        try out.append(alloc, '[');
        for (entries, 0..) |entry, idx| {
            if (idx > 0) try out.append(alloc, ',');
            try appendWsJson(alloc, &out, entry.name, try countSessions(alloc, entry.dir));
        }
        try out.appendSlice(alloc, "]\n");
        return stdoutWrite(out.items);
    }

    var name_width: usize = "(default)".len;
    for (entries[1..]) |entry| name_width = @max(name_width, entry.name.len);

    try appendPadded(alloc, &out, "WORKSPACE", name_width);
    try out.appendSlice(alloc, "  SESSIONS\n");
    for (entries) |entry| {
        const label = if (entry.name.len == 0) "(default)" else entry.name;
        try appendWsRow(alloc, &out, label, try countSessions(alloc, entry.dir), name_width);
    }
    try stdoutWrite(out.items);
}

fn cmdWorkspaceRemove(alloc: std.mem.Allocator, args: []const [:0]const u8) !void {
    var all = false;
    var workspace_arg: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (isHelpFlag(arg)) return printHelpPage("workspace");
        if (std.mem.eql(u8, arg, "--all")) {
            all = true;
        } else if (arg.len > 0 and arg[0] == '-') {
            usageFail("workspace", "unknown flag '{s}'", .{arg});
        } else if (workspace_arg == null) {
            workspace_arg = arg;
        } else {
            usageFail("workspace", "unexpected argument '{s}'", .{arg});
        }
    }
    if (all and workspace_arg != null) {
        usageFail("workspace", "--all cannot be combined with a workspace name", .{});
    }
    if (all) return removeAllWorkspacesCli(alloc);

    const raw = workspace_arg orelse usageFail("workspace", "a workspace name or --all is required", .{});
    const workspace = workspaceFromCli(raw) catch
        usageFail("workspace", "invalid workspace name '{s}'", .{raw});
    const dir = workspaceDirExisting(alloc, workspace) catch |err| switch (err) {
        error.NoWorkspace => fail(exit_no_session, "no workspace named {s}", .{raw}),
        error.InvalidSessionName => usageFail("workspace", "invalid workspace name '{s}'", .{raw}),
        else => return err,
    };
    defer alloc.free(dir);
    _ = try removeWorkspaceDir(alloc, dir, workspace != null, false);
    try stdoutPrint(alloc, "{s}\n", .{if (workspace) |ws| ws else "(default)"});
}

fn workspaceFromCli(raw: []const u8) !?[]const u8 {
    if (std.mem.eql(u8, raw, "@default")) return null;
    try paths.validateName(raw);
    return raw;
}

fn removeAllWorkspacesCli(alloc: std.mem.Allocator) !void {
    const entries = try collectWorkspaces(alloc);
    defer freeWorkspaceEntries(alloc, entries);
    for (entries) |entry| {
        _ = try removeWorkspaceDir(alloc, entry.dir, entry.name.len != 0, false);
        try stdoutPrint(alloc, "{s}\n", .{if (entry.name.len == 0) "(default)" else entry.name});
    }
}

fn removeWorkspaceDir(
    alloc: std.mem.Allocator,
    dir: []const u8,
    remove_dir: bool,
    print_sessions: bool,
) !usize {
    const sessions = try terminateSessions(alloc, dir, print_sessions);
    destroyUiManager(alloc, dir);
    if (remove_dir) {
        try std.fs.cwd().deleteTree(dir);
    }
    return sessions;
}

fn terminateSessions(alloc: std.mem.Allocator, dir: []const u8, print_names: bool) !usize {
    const sessions = try paths.listSessions(alloc, dir);
    defer {
        for (sessions) |s| alloc.free(s);
        alloc.free(sessions);
    }
    var count: usize = 0;
    for (sessions) |name| {
        const sock = try paths.socketPath(alloc, dir, name);
        defer alloc.free(sock);
        const result = client.control(alloc, sock, &.{"quit"}) catch {
            std.fs.cwd().deleteFile(sock) catch {};
            removeAgentSession(alloc, dir, name);
            count += 1;
            if (print_names) try stdoutPrint(alloc, "{s}\n", .{name});
            continue;
        };
        defer alloc.free(result.text);
        removeAgentSession(alloc, dir, name);
        count += 1;
        if (print_names) try stdoutPrint(alloc, "{s}\n", .{name});
    }
    return count;
}

fn destroyUiManager(alloc: std.mem.Allocator, dir: []const u8) void {
    const sock = paths.uiManagerSocketPath(alloc, dir) catch return;
    defer alloc.free(sock);
    const id_path = paths.uiManagerIdPath(alloc, dir) catch return;
    defer alloc.free(id_path);

    var reachable = false;
    if (client.connect(alloc, sock)) |fd| {
        reachable = true;
        posix.close(fd);
    } else |_| {}
    if (reachable) {
        if (std.fs.cwd().readFileAlloc(alloc, id_path, 64)) |data| {
            defer alloc.free(data);
            const trimmed = std.mem.trim(u8, data, " \t\r\n");
            if (std.fmt.parseInt(std.c.pid_t, trimmed, 10)) |pid| {
                if (pid > 1) posix.kill(pid, posix.SIG.TERM) catch {};
            } else |_| {}
        } else |_| {}
    }
    std.fs.cwd().deleteFile(sock) catch {};
    std.fs.cwd().deleteFile(id_path) catch {};
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

fn slashUsageMessage(err: slash.ComposeError, command: slash.Command) []const u8 {
    return switch (err) {
        slash.ComposeError.PromptRequired => "goal requires --prompt or --clear",
        slash.ComposeError.PromptNotAllowed => "clear does not accept --prompt",
        slash.ComposeError.ClearNotAllowed => switch (command) {
            .compact => "compact does not accept --clear",
            .clear => "clear does not accept --clear",
            .goal => unreachable,
        },
        slash.ComposeError.InvalidGoal => "goal accepts either --prompt or --clear, not both",
    };
}

fn slashPayload(alloc: std.mem.Allocator, line: []const u8) ![]u8 {
    if (std.mem.indexOfScalar(u8, line, 0) != null) return error.NulInput;
    var payload: std.ArrayList(u8) = .empty;
    errdefer payload.deinit(alloc);
    try payload.appendSlice(alloc, line);
    try payload.append(alloc, '\r');
    return payload.toOwnedSlice(alloc);
}

fn cmdSlash(alloc: std.mem.Allocator, args: []const [:0]const u8) !void {
    var name_arg: ?[]const u8 = null;
    var command_arg: ?[]const u8 = null;
    var prompt: ?[]const u8 = null;
    var clear = false;
    var ws_flag: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (isHelpFlag(arg)) return printHelpPage("slash");
        if (std.mem.eql(u8, arg, "--clear")) {
            clear = true;
        } else if (flagValue("slash", "--prompt", args, &i)) |v| {
            prompt = v;
        } else if (flagValue("slash", "--workspace", args, &i)) |v| {
            ws_flag = v;
        } else if (flagValue("slash", "-w", args, &i)) |v| {
            ws_flag = v;
        } else if (arg.len > 0 and arg[0] == '-') {
            usageFail("slash", "unknown flag '{s}'", .{arg});
        } else if (name_arg == null) {
            name_arg = arg;
        } else if (command_arg == null) {
            command_arg = arg;
        } else {
            usageFail("slash", "unexpected argument '{s}'", .{arg});
        }
    }

    const want = name_arg orelse usageFail("slash", "a session name is required", .{});
    const cmd_name = command_arg orelse
        usageFail("slash", "a command is required (compact, clear, or goal)", .{});
    const command = slash.Command.parse(cmd_name) orelse
        usageFail("slash", "unknown command '{s}' (expected compact, clear, or goal)", .{cmd_name});

    const line = slash.compose(alloc, command, .{ .prompt = prompt, .clear = clear }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => |e| usageFail("slash", "{s}", .{slashUsageMessage(e, command)}),
    };
    defer alloc.free(line);

    const dir = try workspaceDir("slash", alloc, ws_flag);
    defer alloc.free(dir);
    const name = try resolveSession(alloc, dir, want);
    defer alloc.free(name);

    const payload = slashPayload(alloc, line) catch |err| switch (err) {
        error.NulInput => usageFail("slash", "cannot send NUL bytes", .{}),
        else => |e| return e,
    };
    defer alloc.free(payload);

    const result = try mustControl(alloc, dir, name, &.{ "send", payload });
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
    var history = false;
    var current = false;
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
        } else if (std.mem.eql(u8, arg, "--history")) {
            history = true;
        } else if (std.mem.eql(u8, arg, "--current")) {
            current = true;
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
    if (file) |path| {
        const kind = agent_kind orelse
            usageFail("read", "--file requires --agent <claude|codex|pi>", .{});
        const agent = harness.Agent.fromId(kind) orelse
            usageFail("read", "unknown agent '{s}' (claude, codex, pi)", .{kind});
        if (!agent.hasTranscript())
            usageFail("read", "agent '{s}' has no transcript (claude, codex, pi)", .{kind});
        if (positional != null)
            usageFail("read", "unexpected session/path argument with --file", .{});
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

    const agent_override = if (agent_kind) |kind| blk: {
        const agent = harness.Agent.fromId(kind) orelse
            usageFail("read", "unknown agent '{s}' (claude, codex, pi)", .{kind});
        if (!agent.hasTranscript())
            usageFail("read", "agent '{s}' has no transcript (claude, codex, pi)", .{kind});
        break :blk agent;
    } else null;

    // Session mode: resolve a live session, then resolve sidecar, override,
    // detected process, and bounded store-scan transcript candidates.
    const want = positional orelse usageFail("read", "a session name is required", .{});
    const dir = try workspaceDir("read", alloc, ws_flag);
    defer alloc.free(dir);
    const name = try resolveSession(alloc, dir, want);
    defer alloc.free(name);
    var resolved = resolveTranscriptRuns(alloc, dir, name, .{
        .agent_override = agent_override,
        .history = history and !current,
        .current = current or !history,
    }) catch |err| switch (err) {
        error.BadSidecar => fail(exit_runtime, "corrupt agent sidecar for {s}", .{name}),
        error.NotAgent => fail(exit_runtime, "no agent transcript found for session {s}", .{name}),
        error.AmbiguousTranscript => {
            if (json) {
                const body = try transcriptErrorJson(alloc, "ambiguous_transcript", "multiple matching agent transcripts; pass --agent or narrow the session context");
                defer alloc.free(body);
                try stdoutWrite(body);
                posix.exit(exit_runtime);
            }
            fail(exit_runtime, "multiple matching agent transcripts for {s}; pass --agent or narrow the session context", .{name});
        },
        else => return err,
    };
    defer resolved.deinit(alloc);

    if (json) {
        const body = try renderTranscriptJson(alloc, name, resolved.runs, thinking);
        defer alloc.free(body);
        return stdoutWrite(body);
    }
    const body = try renderTranscriptText(alloc, name, resolved.runs, thinking);
    defer alloc.free(body);
    try emitDump(body, false);
}

/// Read a transcript/sidecar file fully into memory; null on any error
/// (missing, unreadable). Caller frees.
fn readTranscript(alloc: std.mem.Allocator, path: []const u8) ?[]u8 {
    return std.fs.cwd().readFileAlloc(alloc, path, max_transcript_bytes) catch null;
}

const ReadSource = enum {
    history,
    sidecar,
    override,
    process,
    scan,

    fn asStr(self: ReadSource) []const u8 {
        return @tagName(self);
    }
};

const ReadConfidence = enum {
    low,
    medium,
    high,
    exact,

    fn asStr(self: ReadConfidence) []const u8 {
        return @tagName(self);
    }
};

const ReadOptions = struct {
    agent_override: ?harness.Agent = null,
    history: bool = false,
    current: bool = true,
};

const TranscriptRun = struct {
    agent: harness.Agent,
    source: ReadSource,
    confidence: ReadConfidence,
    state: harness.SessionState = .unknown,
    session_id: ?[]u8 = null,
    session_store: ?[]u8 = null,
    cwd: ?[]u8 = null,
    transcript_path: ?[]u8 = null,
    transcript_key: ?[]u8 = null,
    detected_at_ms: i64 = 0,
    updated_at_ms: i64 = 0,

    fn deinit(self: TranscriptRun, alloc: std.mem.Allocator) void {
        if (self.session_id) |s| alloc.free(s);
        if (self.session_store) |s| alloc.free(s);
        if (self.cwd) |s| alloc.free(s);
        if (self.transcript_path) |s| alloc.free(s);
        if (self.transcript_key) |s| alloc.free(s);
    }

    fn clone(self: TranscriptRun, alloc: std.mem.Allocator) !TranscriptRun {
        return .{
            .agent = self.agent,
            .source = self.source,
            .confidence = self.confidence,
            .state = self.state,
            .session_id = try dupeOptMain(alloc, self.session_id),
            .session_store = try dupeOptMain(alloc, self.session_store),
            .cwd = try dupeOptMain(alloc, self.cwd),
            .transcript_path = try dupeOptMain(alloc, self.transcript_path),
            .transcript_key = try dupeOptMain(alloc, self.transcript_key),
            .detected_at_ms = self.detected_at_ms,
            .updated_at_ms = self.updated_at_ms,
        };
    }
};

const TranscriptResolution = struct {
    runs: []TranscriptRun,

    fn deinit(self: *TranscriptResolution, alloc: std.mem.Allocator) void {
        for (self.runs) |run| run.deinit(alloc);
        alloc.free(self.runs);
    }
};

fn resolveTranscriptRuns(
    alloc: std.mem.Allocator,
    dir: []const u8,
    name: []const u8,
    opts: ReadOptions,
) !TranscriptResolution {
    var all: std.ArrayList(TranscriptRun) = .empty;
    errdefer deinitRunList(alloc, &all);

    try loadRunHistory(alloc, dir, name, &all);
    const meta = try readSessionMeta(alloc, dir, name);
    defer meta.deinit(alloc);

    if (try sidecarRun(alloc, dir, name)) |run| {
        try appendRunDedupe(alloc, &all, run);
        appendRunHistoryCandidate(alloc, dir, name, run);
    }

    var process_agent: ?harness.Agent = null;
    if (opts.agent_override) |agent| {
        try discoverAgentRuns(alloc, dir, name, agent, .override, meta, &all);
    } else {
        process_agent = detectProcessAgent(alloc, dir, name) catch null;
        if (process_agent) |agent| {
            try discoverAgentRuns(alloc, dir, name, agent, .process, meta, &all);
        }
        if (all.items.len == 0) {
            inline for (.{ harness.Agent.claude, harness.Agent.codex, harness.Agent.pi }) |agent| {
                try discoverAgentRuns(alloc, dir, name, agent, .scan, meta, &all);
            }
        }
    }

    if (all.items.len == 0) return error.NotAgent;
    sortRuns(all.items);

    if (opts.history and !opts.current) {
        return .{ .runs = try all.toOwnedSlice(alloc) };
    }

    const idx = selectCurrentRun(all.items, opts.agent_override, process_agent) orelse
        return error.NotAgent;
    const selected = try all.items[idx].clone(alloc);
    deinitRunList(alloc, &all);
    const runs = try alloc.alloc(TranscriptRun, 1);
    runs[0] = selected;
    return .{ .runs = runs };
}

fn discoverAgentRuns(
    alloc: std.mem.Allocator,
    dir: []const u8,
    name: []const u8,
    agent: harness.Agent,
    source: ReadSource,
    meta: SessionMeta,
    all: *std.ArrayList(TranscriptRun),
) !void {
    const before = all.items.len;
    const cwd = meta.cwd orelse currentCwd(alloc) catch "";
    defer if (meta.cwd == null and cwd.len > 0) alloc.free(cwd);
    const min_mtime_ns: i128 = if (meta.created_at_ms > 0)
        @as(i128, meta.created_at_ms - 5000) * std.time.ns_per_ms
    else
        0;

    const matches = try scanAgentStores(alloc, agent, cwd, min_mtime_ns, source, all);
    if (matches > 1) return error.AmbiguousTranscript;
    if (matches == 0 and (source == .override or source == .process)) {
        var run: TranscriptRun = .{
            .agent = agent,
            .source = source,
            .confidence = .low,
            .cwd = if (cwd.len > 0) try alloc.dupe(u8, cwd) else null,
            .detected_at_ms = std.time.milliTimestamp(),
            .updated_at_ms = std.time.milliTimestamp(),
        };
        run.transcript_key = try makeRunKey(alloc, run);
        try appendRunDedupe(alloc, all, run);
        appendRunHistoryCandidate(alloc, dir, name, run);
    }
    if (all.items.len > before) {
        for (all.items[before..]) |run| appendRunHistoryCandidate(alloc, dir, name, run);
    }
}

fn scanAgentStores(
    alloc: std.mem.Allocator,
    agent: harness.Agent,
    cwd: []const u8,
    min_mtime_ns: i128,
    source: ReadSource,
    out: *std.ArrayList(TranscriptRun),
) !usize {
    var matches: usize = 0;
    switch (agent) {
        .claude => {
            const root = try homeJoin(alloc, &.{ ".claude", "projects" });
            defer alloc.free(root);
            matches += try scanJsonlTree(alloc, agent, root, cwd, min_mtime_ns, source, out);
        },
        .codex => {
            if (posix.getenv("CODEX_HOME")) |home| {
                const sessions = try std.fs.path.join(alloc, &.{ home, "sessions" });
                defer alloc.free(sessions);
                matches += try scanJsonlTree(alloc, agent, sessions, cwd, min_mtime_ns, source, out);
            }
            const root = try homeJoin(alloc, &.{ ".codex", "sessions" });
            defer alloc.free(root);
            matches += try scanJsonlTree(alloc, agent, root, cwd, min_mtime_ns, source, out);
        },
        .pi => {
            const root = try homeJoin(alloc, &.{".pi"});
            defer alloc.free(root);
            matches += try scanJsonlTree(alloc, agent, root, cwd, min_mtime_ns, source, out);
        },
        .raw, .bash, .zsh => {},
    }
    return matches;
}

fn scanJsonlTree(
    alloc: std.mem.Allocator,
    agent: harness.Agent,
    root: []const u8,
    cwd: []const u8,
    min_mtime_ns: i128,
    source: ReadSource,
    out: *std.ArrayList(TranscriptRun),
) !usize {
    var dir = std.fs.cwd().openDir(root, .{ .iterate = true }) catch return 0;
    defer dir.close();
    var walker = dir.walk(alloc) catch return 0;
    defer walker.deinit();
    var scanned: usize = 0;
    var matches: usize = 0;
    while (walker.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!agentTranscriptName(agent, entry.basename)) continue;
        scanned += 1;
        if (scanned > 512) break;
        const st = dir.statFile(entry.path) catch continue;
        if (st.mtime < min_mtime_ns) continue;
        const full = try std.fs.path.join(alloc, &.{ root, entry.path });
        errdefer alloc.free(full);
        const data = readTranscript(alloc, full) orelse {
            alloc.free(full);
            continue;
        };
        defer alloc.free(data);
        if (cwd.len > 0 and std.mem.indexOf(u8, data, cwd) == null) {
            alloc.free(full);
            continue;
        }
        var run: TranscriptRun = .{
            .agent = agent,
            .source = source,
            .confidence = if (cwd.len > 0) .high else .medium,
            .cwd = if (cwd.len > 0) try alloc.dupe(u8, cwd) else null,
            .transcript_path = full,
            .detected_at_ms = std.time.milliTimestamp(),
            .updated_at_ms = @intCast(@divFloor(st.mtime, std.time.ns_per_ms)),
        };
        run.transcript_key = try makeRunKey(alloc, run);
        try appendRunDedupe(alloc, out, run);
        matches += 1;
    }
    return matches;
}

fn agentTranscriptName(agent: harness.Agent, name: []const u8) bool {
    if (!std.mem.endsWith(u8, name, ".jsonl")) return false;
    return switch (agent) {
        .codex => std.mem.startsWith(u8, name, "rollout-"),
        .claude, .pi => true,
        .raw, .bash, .zsh => false,
    };
}

fn sidecarRun(alloc: std.mem.Allocator, dir: []const u8, name: []const u8) !?TranscriptRun {
    const sc_path = try paths.sidecarPath(alloc, dir, name);
    defer alloc.free(sc_path);
    const sc_data = readTranscript(alloc, sc_path) orelse return null;
    defer alloc.free(sc_data);
    const sc = harness.Sidecar.fromJson(alloc, sc_data) catch return error.BadSidecar;
    defer sc.deinit(alloc);
    var run = try runFromSidecar(alloc, sc, .sidecar, .exact);
    if (sc.agent.transcriptPath(alloc, sc) catch null) |p| {
        run.transcript_path = p;
        if (run.transcript_key) |k| alloc.free(k);
        run.transcript_key = try makeRunKey(alloc, run);
        if (statMtimeMs(p)) |mtime| run.updated_at_ms = mtime;
    }
    return run;
}

fn runFromSidecar(
    alloc: std.mem.Allocator,
    sc: harness.Sidecar,
    source: ReadSource,
    confidence: ReadConfidence,
) !TranscriptRun {
    var run: TranscriptRun = .{
        .agent = sc.agent,
        .source = source,
        .confidence = confidence,
        .session_id = try dupeOptMain(alloc, sc.session_id),
        .session_store = try dupeOptMain(alloc, sc.session_store),
        .cwd = try dupeOptMain(alloc, sc.cwd),
        .detected_at_ms = std.time.milliTimestamp(),
        .updated_at_ms = std.time.milliTimestamp(),
    };
    run.transcript_key = try makeRunKey(alloc, run);
    return run;
}

fn transcriptPathForRun(alloc: std.mem.Allocator, run: TranscriptRun) !?[]u8 {
    if (run.transcript_path) |p| return try alloc.dupe(u8, p);
    const sc: harness.Sidecar = .{
        .agent = run.agent,
        .session_id = run.session_id,
        .session_store = run.session_store,
        .cwd = run.cwd,
    };
    return run.agent.transcriptPath(alloc, sc) catch null;
}

fn loadRunHistory(
    alloc: std.mem.Allocator,
    dir: []const u8,
    name: []const u8,
    out: *std.ArrayList(TranscriptRun),
) !void {
    const path = try paths.runHistoryPath(alloc, dir, name);
    defer alloc.free(path);
    const data = readTranscript(alloc, path) orelse return;
    defer alloc.free(data);
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        const run = parseHistoryRun(alloc, line) catch continue;
        try appendRunDedupe(alloc, out, run);
    }
}

fn parseHistoryRun(alloc: std.mem.Allocator, line: []const u8) !TranscriptRun {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, line, .{}) catch
        return error.BadHistory;
    defer parsed.deinit();
    const agent = harness.Agent.fromId(jsonString(parsed.value, "agent") orelse "") orelse
        return error.BadHistory;
    const source = readSourceFromId(jsonString(parsed.value, "source") orelse "history");
    const confidence = readConfidenceFromId(jsonString(parsed.value, "confidence") orelse "medium");
    var run: TranscriptRun = .{
        .agent = agent,
        .source = source,
        .confidence = confidence,
        .state = readStateFromId(jsonString(parsed.value, "state") orelse "unknown"),
        .session_id = try dupeOptMain(alloc, jsonString(parsed.value, "session_id")),
        .session_store = try dupeOptMain(alloc, jsonString(parsed.value, "session_store")),
        .cwd = try dupeOptMain(alloc, jsonString(parsed.value, "cwd")),
        .transcript_path = try dupeOptMain(alloc, jsonString(parsed.value, "transcript_path")),
        .transcript_key = try dupeOptMain(alloc, jsonString(parsed.value, "transcript_key")),
        .detected_at_ms = jsonI64(parsed.value, "detected_at_ms") orelse 0,
        .updated_at_ms = jsonI64(parsed.value, "updated_at_ms") orelse 0,
    };
    if (run.transcript_key == null) run.transcript_key = try makeRunKey(alloc, run);
    return run;
}

fn appendRunHistorySidecar(
    alloc: std.mem.Allocator,
    dir: []const u8,
    name: []const u8,
    sc: harness.Sidecar,
    source: ReadSource,
    confidence: ReadConfidence,
) void {
    const run = runFromSidecar(alloc, sc, source, confidence) catch return;
    defer run.deinit(alloc);
    appendRunHistoryCandidate(alloc, dir, name, run);
}

fn appendRunHistoryCandidate(
    alloc: std.mem.Allocator,
    dir: []const u8,
    name: []const u8,
    run: TranscriptRun,
) void {
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(alloc);
    appendRunHistoryJson(alloc, &line, run) catch return;
    line.append(alloc, '\n') catch return;
    const path = paths.runHistoryPath(alloc, dir, name) catch return;
    defer alloc.free(path);
    var file = std.fs.cwd().openFile(path, .{ .mode = .read_write }) catch |err| switch (err) {
        error.FileNotFound => std.fs.cwd().createFile(path, .{ .read = true }) catch return,
        else => return,
    };
    defer file.close();
    file.seekFromEnd(0) catch return;
    file.writeAll(line.items) catch return;
}

fn appendRunHistoryJson(alloc: std.mem.Allocator, out: *std.ArrayList(u8), run: TranscriptRun) !void {
    try out.appendSlice(alloc, "{\"agent\":");
    try appendJsonString(alloc, out, run.agent.id());
    try out.appendSlice(alloc, ",\"source\":");
    try appendJsonString(alloc, out, run.source.asStr());
    try out.appendSlice(alloc, ",\"state\":");
    try appendJsonString(alloc, out, run.state.asStr());
    try out.appendSlice(alloc, ",\"confidence\":");
    try appendJsonString(alloc, out, run.confidence.asStr());
    if (run.session_id) |s| {
        try out.appendSlice(alloc, ",\"session_id\":");
        try appendJsonString(alloc, out, s);
    }
    if (run.session_store) |s| {
        try out.appendSlice(alloc, ",\"session_store\":");
        try appendJsonString(alloc, out, s);
    }
    if (run.cwd) |s| {
        try out.appendSlice(alloc, ",\"cwd\":");
        try appendJsonString(alloc, out, s);
    }
    if (run.transcript_path) |s| {
        try out.appendSlice(alloc, ",\"transcript_path\":");
        try appendJsonString(alloc, out, s);
    }
    if (run.transcript_key) |s| {
        try out.appendSlice(alloc, ",\"transcript_key\":");
        try appendJsonString(alloc, out, s);
    }
    try out.print(alloc, ",\"detected_at_ms\":{d},\"updated_at_ms\":{d}}}", .{
        run.detected_at_ms,
        run.updated_at_ms,
    });
}

fn readSessionMeta(alloc: std.mem.Allocator, dir: []const u8, name: []const u8) !SessionMeta {
    const path = try paths.sessionMetaPath(alloc, dir, name);
    defer alloc.free(path);
    const data = readTranscript(alloc, path) orelse return .{
        .cwd = currentCwd(alloc) catch null,
        .created_at_ms = 0,
    };
    defer alloc.free(data);
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, data, .{}) catch return .{
        .cwd = currentCwd(alloc) catch null,
        .created_at_ms = 0,
    };
    defer parsed.deinit();
    return .{
        .cwd = try dupeOptMain(alloc, jsonString(parsed.value, "cwd")),
        .created_at_ms = jsonI64(parsed.value, "created_at_ms") orelse 0,
    };
}

fn appendRunDedupe(alloc: std.mem.Allocator, list: *std.ArrayList(TranscriptRun), run_in: TranscriptRun) !void {
    var run = run_in;
    if (run.transcript_key == null) run.transcript_key = try makeRunKey(alloc, run);
    const key = run.transcript_key.?;
    for (list.items, 0..) |*existing, idx| {
        _ = idx;
        if (existing.transcript_key) |ek| {
            if (std.mem.eql(u8, ek, key)) {
                if (runRank(run) >= runRank(existing.*) and run.updated_at_ms >= existing.updated_at_ms) {
                    existing.deinit(alloc);
                    existing.* = run;
                } else {
                    run.deinit(alloc);
                }
                return;
            }
        }
    }
    try list.append(alloc, run);
}

fn makeRunKey(alloc: std.mem.Allocator, run: TranscriptRun) ![]u8 {
    if (run.session_id) |sid| return std.fmt.allocPrint(alloc, "{s}:sid:{s}", .{ run.agent.id(), sid });
    if (run.session_store) |store| return std.fmt.allocPrint(alloc, "{s}:store:{s}", .{ run.agent.id(), store });
    if (run.transcript_path) |path| return std.fmt.allocPrint(alloc, "{s}:path:{s}", .{ run.agent.id(), path });
    if (run.cwd) |cwd| return std.fmt.allocPrint(alloc, "{s}:cwd:{s}", .{ run.agent.id(), cwd });
    return std.fmt.allocPrint(alloc, "{s}:unknown", .{run.agent.id()});
}

fn selectCurrentRun(
    runs: []const TranscriptRun,
    agent_override: ?harness.Agent,
    process_agent: ?harness.Agent,
) ?usize {
    var best: ?usize = null;
    for (runs, 0..) |run, idx| {
        if (agent_override) |agent| {
            if (run.agent != agent) continue;
        } else if (process_agent) |agent| {
            if (run.agent != agent) continue;
        }
        if (best == null or betterCurrent(run, runs[best.?])) best = idx;
    }
    if (best != null) return best;
    for (runs, 0..) |run, idx| {
        if (best == null or betterCurrent(run, runs[best.?])) best = idx;
    }
    return best;
}

fn betterCurrent(a: TranscriptRun, b: TranscriptRun) bool {
    const ar = runRank(a);
    const br = runRank(b);
    if (ar != br) return ar > br;
    return a.updated_at_ms > b.updated_at_ms;
}

fn runRank(run: TranscriptRun) u8 {
    const source_rank: u8 = switch (run.source) {
        .override => 50,
        .process => 45,
        .sidecar => 40,
        .scan => 30,
        .history => 10,
    };
    const conf_rank: u8 = switch (run.confidence) {
        .exact => 4,
        .high => 3,
        .medium => 2,
        .low => 1,
    };
    return source_rank + conf_rank;
}

fn sortRuns(runs: []TranscriptRun) void {
    std.mem.sort(TranscriptRun, runs, {}, struct {
        fn lessThan(_: void, a: TranscriptRun, b: TranscriptRun) bool {
            if (a.updated_at_ms != b.updated_at_ms) return a.updated_at_ms < b.updated_at_ms;
            return runRank(a) < runRank(b);
        }
    }.lessThan);
}

fn deinitRunList(alloc: std.mem.Allocator, list: *std.ArrayList(TranscriptRun)) void {
    for (list.items) |run| run.deinit(alloc);
    list.deinit(alloc);
}

fn detectProcessAgent(alloc: std.mem.Allocator, dir: []const u8, name: []const u8) !?harness.Agent {
    const result = try controlSession(alloc, dir, name, &.{"pid"});
    defer alloc.free(result.text);
    if (!result.ok) return null;
    const root_pid = std.fmt.parseInt(i32, std.mem.trim(u8, result.text, " \t\r\n"), 10) catch return null;
    return detectDescendantAgent(alloc, root_pid);
}

const PsProc = struct {
    pid: i32,
    ppid: i32,
    agent: ?harness.Agent,
};

fn detectDescendantAgent(alloc: std.mem.Allocator, root_pid: i32) !?harness.Agent {
    const ps = std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "/bin/ps", "-axo", "pid=,ppid=,comm=" },
    }) catch return null;
    defer alloc.free(ps.stdout);
    defer alloc.free(ps.stderr);
    if (ps.term != .Exited or ps.term.Exited != 0) return null;

    var procs: std.ArrayList(PsProc) = .empty;
    defer procs.deinit(alloc);
    var it = std.mem.splitScalar(u8, ps.stdout, '\n');
    while (it.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0) continue;
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const pid = std.fmt.parseInt(i32, fields.next() orelse continue, 10) catch continue;
        const ppid = std.fmt.parseInt(i32, fields.next() orelse continue, 10) catch continue;
        const comm = fields.rest();
        try procs.append(alloc, .{ .pid = pid, .ppid = ppid, .agent = agentFromCommand(comm) });
    }

    var found: ?harness.Agent = null;
    var changed = true;
    var descendants = std.AutoHashMap(i32, void).init(alloc);
    defer descendants.deinit();
    try descendants.put(root_pid, {});
    for (procs.items) |proc| {
        if (proc.pid == root_pid) {
            if (proc.agent) |agent| found = agent;
            break;
        }
    }
    while (changed) {
        changed = false;
        for (procs.items) |proc| {
            if (descendants.contains(proc.pid)) continue;
            if (descendants.contains(proc.ppid)) {
                try descendants.put(proc.pid, {});
                changed = true;
                if (proc.agent) |agent| {
                    if (found != null and found.? != agent) return null;
                    found = agent;
                }
            }
        }
    }
    return found;
}

fn agentFromCommand(command: []const u8) ?harness.Agent {
    const base = std.fs.path.basename(std.mem.trim(u8, command, " \t\r\n"));
    if (std.mem.eql(u8, base, "claude") or std.mem.eql(u8, base, "claude-code")) return .claude;
    if (std.mem.eql(u8, base, "codex")) return .codex;
    if (std.mem.eql(u8, base, "pi")) return .pi;
    return null;
}

fn renderTranscriptJson(
    alloc: std.mem.Allocator,
    name: []const u8,
    runs: []const TranscriptRun,
    thinking: bool,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    const current_idx = if (runs.len == 0) 0 else runs.len - 1;
    var current_report: ?harness.StateReport = null;
    defer if (current_report) |*r| r.deinit(alloc);
    var current_arr: ?[]u8 = null;
    defer if (current_arr) |a| alloc.free(a);

    var run_jsons: std.ArrayList([]u8) = .empty;
    defer {
        for (run_jsons.items) |j| alloc.free(j);
        run_jsons.deinit(alloc);
    }
    var combined: std.ArrayList(u8) = .empty;
    defer combined.deinit(alloc);
    try combined.append(alloc, '[');
    var first_combined = true;

    for (runs, 0..) |run, idx| {
        const one = try renderOneRunJson(alloc, run, thinking, &combined, &first_combined);
        try run_jsons.append(alloc, one.json);
        if (idx == current_idx) {
            current_report = one.report;
            current_arr = try alloc.dupe(u8, one.arr);
        } else {
            one.report.deinit(alloc);
        }
        alloc.free(one.arr);
    }
    try combined.appendSlice(alloc, "]\n");

    const cr = current_report.?;
    try out.appendSlice(alloc, "{\"session\":");
    try appendJsonString(alloc, &out, name);
    try out.appendSlice(alloc, ",\"agent\":");
    try appendJsonString(alloc, &out, runs[current_idx].agent.id());
    try out.appendSlice(alloc, ",\"state\":");
    try appendJsonString(alloc, &out, cr.state.asStr());
    if (cr.stop_reason) |s| {
        try out.appendSlice(alloc, ",\"stop_reason\":");
        try appendJsonString(alloc, &out, s);
    }
    if (cr.detail) |d| {
        try out.appendSlice(alloc, ",\"detail\":");
        try appendJsonString(alloc, &out, d);
    }
    try out.print(alloc, ",\"messages\":{d},\"transcript\":", .{cr.messages});
    if (runs.len > 1) {
        try out.appendSlice(alloc, combined.items);
    } else {
        try out.appendSlice(alloc, std.mem.trimRight(u8, current_arr.?, " \n"));
    }
    try out.appendSlice(alloc, ",\"runs\":[");
    for (run_jsons.items, 0..) |j, idx| {
        if (idx > 0) try out.append(alloc, ',');
        try out.appendSlice(alloc, j);
    }
    try out.appendSlice(alloc, "],\"warnings\":[]}\n");
    return out.toOwnedSlice(alloc);
}

const RenderedRun = struct {
    json: []u8,
    arr: []u8,
    report: harness.StateReport,
};

fn renderOneRunJson(
    alloc: std.mem.Allocator,
    run: TranscriptRun,
    thinking: bool,
    combined: *std.ArrayList(u8),
    first_combined: *bool,
) !RenderedRun {
    const t_path = try transcriptPathForRun(alloc, run);
    defer if (t_path) |p| alloc.free(p);
    const data = if (t_path) |p| (readTranscript(alloc, p) orelse try alloc.dupe(u8, "")) else try alloc.dupe(u8, "");
    defer alloc.free(data);
    var report = try run.agent.detect(alloc, data);
    errdefer report.deinit(alloc);
    const arr = try run.agent.dumpJson(alloc, data, thinking);
    errdefer alloc.free(arr);
    try appendJsonArrayItems(alloc, combined, arr, first_combined);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"agent\":");
    try appendJsonString(alloc, &out, run.agent.id());
    try out.appendSlice(alloc, ",\"source\":");
    try appendJsonString(alloc, &out, run.source.asStr());
    try out.appendSlice(alloc, ",\"state\":");
    try appendJsonString(alloc, &out, report.state.asStr());
    try out.appendSlice(alloc, ",\"confidence\":");
    try appendJsonString(alloc, &out, run.confidence.asStr());
    try out.print(alloc, ",\"messages\":{d},\"transcript\":", .{report.messages});
    try out.appendSlice(alloc, std.mem.trimRight(u8, arr, " \n"));
    try out.append(alloc, '}');
    return .{ .json = try out.toOwnedSlice(alloc), .arr = arr, .report = report };
}

fn appendJsonArrayItems(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    arr_json: []const u8,
    first: *bool,
) !void {
    const trimmed = std.mem.trim(u8, arr_json, " \t\r\n");
    if (trimmed.len < 2 or trimmed[0] != '[' or trimmed[trimmed.len - 1] != ']') return;
    const inner = std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t\r\n");
    if (inner.len == 0) return;
    if (!first.*) try out.append(alloc, ',');
    try out.appendSlice(alloc, inner);
    first.* = false;
}

fn renderTranscriptText(
    alloc: std.mem.Allocator,
    name: []const u8,
    runs: []const TranscriptRun,
    thinking: bool,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (runs, 0..) |run, idx| {
        const t_path = try transcriptPathForRun(alloc, run);
        defer if (t_path) |p| alloc.free(p);
        const data = if (t_path) |p| (readTranscript(alloc, p) orelse try alloc.dupe(u8, "")) else try alloc.dupe(u8, "");
        defer alloc.free(data);
        var report = try run.agent.detect(alloc, data);
        defer report.deinit(alloc);
        if (idx > 0) try out.append(alloc, '\n');
        try out.print(alloc, "{s} · {s} · {s}", .{ name, run.agent.id(), report.state.asStr() });
        if (runs.len > 1) try out.print(alloc, " · run {d}/{d} · {s}", .{ idx + 1, runs.len, run.source.asStr() });
        if (report.stop_reason) |s| try out.print(alloc, " ({s})", .{s});
        if (report.detail) |d| try out.print(alloc, " - {s}", .{d});
        try out.print(alloc, " · {d} message{s}\n\n", .{ report.messages, if (report.messages == 1) "" else "s" });
        const text = try run.agent.dumpText(alloc, data, thinking);
        defer alloc.free(text);
        if (text.len == 0) {
            try out.appendSlice(alloc, "(empty transcript)\n");
        } else {
            try out.appendSlice(alloc, text);
            if (text[text.len - 1] != '\n') try out.append(alloc, '\n');
        }
    }
    return out.toOwnedSlice(alloc);
}

fn transcriptErrorJson(alloc: std.mem.Allocator, code: []const u8, message: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"error\":{\"code\":");
    try appendJsonString(alloc, &out, code);
    try out.appendSlice(alloc, ",\"message\":");
    try appendJsonString(alloc, &out, message);
    try out.appendSlice(alloc, ",\"warnings\":[");
    try appendJsonString(alloc, &out, message);
    try out.appendSlice(alloc, "]}}\n");
    return out.toOwnedSlice(alloc);
}

fn readSourceFromId(id: []const u8) ReadSource {
    inline for (@typeInfo(ReadSource).@"enum".fields) |field| {
        if (std.mem.eql(u8, id, field.name)) return @enumFromInt(field.value);
    }
    return .history;
}

fn readConfidenceFromId(id: []const u8) ReadConfidence {
    inline for (@typeInfo(ReadConfidence).@"enum".fields) |field| {
        if (std.mem.eql(u8, id, field.name)) return @enumFromInt(field.value);
    }
    return .medium;
}

fn readStateFromId(id: []const u8) harness.SessionState {
    inline for (@typeInfo(harness.SessionState).@"enum".fields) |field| {
        if (std.mem.eql(u8, id, field.name)) return @enumFromInt(field.value);
    }
    return .unknown;
}

fn jsonI64(root: std.json.Value, key: []const u8) ?i64 {
    if (root != .object) return null;
    const value = root.object.get(key) orelse return null;
    return switch (value) {
        .integer => |n| @intCast(n),
        else => null,
    };
}

fn currentCwd(alloc: std.mem.Allocator) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = posix.getcwd(&cwd_buf) catch ".";
    return alloc.dupe(u8, cwd);
}

fn homeJoin(alloc: std.mem.Allocator, parts: []const []const u8) ![]u8 {
    const home = posix.getenv("HOME") orelse return error.NoHome;
    var all = try alloc.alloc([]const u8, parts.len + 1);
    defer alloc.free(all);
    all[0] = home;
    for (parts, 0..) |part, idx| all[idx + 1] = part;
    return std.fs.path.join(alloc, all);
}

fn statMtimeMs(path: []const u8) ?i64 {
    const st = std.fs.cwd().statFile(path) catch return null;
    return @intCast(@divFloor(st.mtime, std.time.ns_per_ms));
}

fn dupeOptMain(alloc: std.mem.Allocator, s: ?[]const u8) !?[]u8 {
    return if (s) |v| try alloc.dupe(u8, v) else null;
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
        _ = try terminateSessions(alloc, dir, true);
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
    dispatchHttp(alloc, stream, req, cfg) catch |err| {
        std.log.warn("http handler failed: {}", .{err});
        return sendError(stream, 500, "internal_error", @errorName(err));
    };
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
    if (segs.len == 2 and eqlSegs(segs, &.{ "v1", "workspaces" })) {
        if (std.mem.eql(u8, req.method, "GET")) return handleWorkspaces(alloc, stream);
        if (std.mem.eql(u8, req.method, "DELETE")) {
            if (queryBool(req.query, "all") orelse false) return handleRemoveAllWorkspaces(alloc, stream);
            return sendError(stream, 400, "bad_request", "DELETE /v1/workspaces requires all=true");
        }
    }
    if (segs.len == 3 and std.mem.eql(u8, segs[0], "v1") and std.mem.eql(u8, segs[1], "workspaces")) {
        const workspace = workspaceFromSegment(segs[2]) catch
            return sendError(stream, 400, "bad_workspace", "invalid workspace segment");
        if (std.mem.eql(u8, req.method, "POST")) return handleCreateWorkspace(alloc, stream, workspace);
        if (std.mem.eql(u8, req.method, "DELETE")) return handleRemoveWorkspace(alloc, stream, workspace);
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
                if (std.mem.eql(u8, action, "slash") and std.mem.eql(u8, req.method, "POST")) {
                    return handleSlash(alloc, stream, workspace, want, req.body);
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
                    return handleTranscript(alloc, stream, workspace, want, req.query);
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
    const entries = try collectWorkspaces(alloc);
    defer freeWorkspaceEntries(alloc, entries);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"workspaces\":[");
    for (entries, 0..) |entry, idx| {
        if (idx > 0) try out.append(alloc, ',');
        try appendWorkspaceJson(
            alloc,
            &out,
            if (entry.name.len == 0) "@default" else entry.name,
            entry.name,
            try countSessions(alloc, entry.dir),
        );
    }
    try out.appendSlice(alloc, "]}\n");
    return sendOwnedJson(alloc, stream, 200, &out);
}

fn handleCreateWorkspace(alloc: std.mem.Allocator, stream: std.net.Stream, workspace: ?[]const u8) !void {
    const dir = try workspaceDirHttp(alloc, workspace);
    defer alloc.free(dir);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"id\":");
    try appendJsonString(alloc, &out, if (workspace) |ws| ws else "@default");
    try out.appendSlice(alloc, ",\"workspace\":");
    try appendJsonString(alloc, &out, workspace orelse "");
    try out.appendSlice(alloc, ",\"created\":true}\n");
    return sendOwnedJson(alloc, stream, 201, &out);
}

fn handleRemoveWorkspace(alloc: std.mem.Allocator, stream: std.net.Stream, workspace: ?[]const u8) !void {
    const dir = workspaceDirExisting(alloc, workspace) catch |err| switch (err) {
        error.NoWorkspace => return sendError(stream, 404, "not_found", "workspace not found"),
        error.InvalidSessionName => return sendError(stream, 400, "bad_workspace", "invalid workspace segment"),
        else => return err,
    };
    defer alloc.free(dir);
    const sessions = try removeWorkspaceDir(alloc, dir, workspace != null, false);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try appendWorkspaceRemoveJson(alloc, &out, workspace orelse "", sessions);
    try out.append(alloc, '\n');
    return sendOwnedJson(alloc, stream, 200, &out);
}

fn handleRemoveAllWorkspaces(alloc: std.mem.Allocator, stream: std.net.Stream) !void {
    const entries = try collectWorkspaces(alloc);
    defer freeWorkspaceEntries(alloc, entries);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"removed\":true,\"workspaces\":[");
    for (entries, 0..) |entry, idx| {
        if (idx > 0) try out.append(alloc, ',');
        const sessions = try removeWorkspaceDir(alloc, entry.dir, entry.name.len != 0, false);
        try appendWorkspaceRemoveJson(alloc, &out, entry.name, sessions);
    }
    try out.appendSlice(alloc, "]}\n");
    return sendOwnedJson(alloc, stream, 200, &out);
}

fn appendWorkspaceRemoveJson(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    workspace: []const u8,
    sessions: usize,
) !void {
    try out.appendSlice(alloc, "{\"workspace\":");
    try appendJsonString(alloc, out, workspace);
    try out.print(alloc, ",\"removed\":true,\"sessions\":{d}}}", .{sessions});
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
        try appendSessionInfoJson(alloc, &out, dir, name, info, null);
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
    const state = try trySessionStateForInfo(alloc, dir, name);
    defer if (state) |s| alloc.free(s.text);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try appendSessionInfoJson(alloc, &out, dir, name, info, if (state) |s| s.event_seq else null);
    try out.append(alloc, '\n');
    return sendOwnedJson(alloc, stream, 200, &out);
}

fn trySessionStateForInfo(alloc: std.mem.Allocator, dir: []const u8, name: []const u8) !?SessionState {
    return sessionState(alloc, dir, name) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            std.log.warn("session state unavailable for {s}: {}", .{ name, err });
            return null;
        },
    };
}

fn appendSessionInfoJson(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    dir: []const u8,
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
    if (try cheapAgentInfo(alloc, dir, name)) |agent_info| {
        try out.appendSlice(alloc, ",\"agent\":");
        try appendJsonString(alloc, out, agent_info.agent.id());
        try out.appendSlice(alloc, ",\"agent_state\":");
        try appendJsonString(alloc, out, agent_info.state.asStr());
        try out.appendSlice(alloc, ",\"agent_source\":");
        try appendJsonString(alloc, out, agent_info.source.asStr());
    }
    try out.append(alloc, '}');
}

const CheapAgentInfo = struct {
    agent: harness.Agent,
    state: harness.SessionState,
    source: ReadSource,
};

fn cheapAgentInfo(alloc: std.mem.Allocator, dir: []const u8, name: []const u8) !?CheapAgentInfo {
    var runs: std.ArrayList(TranscriptRun) = .empty;
    defer deinitRunList(alloc, &runs);
    try loadRunHistory(alloc, dir, name, &runs);
    if (try sidecarRun(alloc, dir, name)) |run| try appendRunDedupe(alloc, &runs, run);
    if (runs.items.len == 0) return null;
    const idx = selectCurrentRun(runs.items, null, null) orelse return null;
    const run = runs.items[idx];
    var state = run.state;
    const maybe_path = transcriptPathForRun(alloc, run) catch null;
    if (maybe_path) |p| {
        defer alloc.free(p);
        if (readTranscript(alloc, p)) |data| {
            defer alloc.free(data);
            var report = try run.agent.detect(alloc, data);
            defer report.deinit(alloc);
            state = report.state;
        }
    }
    return .{ .agent = run.agent, .state = state, .source = run.source };
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

fn handleSlash(
    alloc: std.mem.Allocator,
    stream: std.net.Stream,
    workspace: ?[]const u8,
    want: []const u8,
    body: []const u8,
) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch
        return sendError(stream, 400, "bad_json", "request body must be JSON");
    defer parsed.deinit();
    if (parsed.value != .object) return sendError(stream, 400, "bad_json", "request body must be a JSON object");

    const command_name = jsonString(parsed.value, "command") orelse
        return sendError(stream, 400, "bad_command", "command is required");
    const command = slash.Command.parse(command_name) orelse
        return sendError(stream, 400, "bad_command", "unknown command");
    const prompt = jsonString(parsed.value, "prompt");
    const clear = jsonBool(parsed.value, "clear") orelse false;

    const line = slash.compose(alloc, command, .{ .prompt = prompt, .clear = clear }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => |e| return sendError(stream, 400, "bad_slash", slashUsageMessage(e, command)),
    };
    defer alloc.free(line);

    const dir = try workspaceDirHttp(alloc, workspace);
    defer alloc.free(dir);
    const name = resolveSessionResult(alloc, dir, want) catch |err| return sendResolveError(stream, err);
    defer alloc.free(name);
    const payload = slashPayload(alloc, line) catch |err| switch (err) {
        error.NulInput => return sendError(stream, 400, "nul_input", "NUL bytes are not supported by v1 slash"),
        else => return err,
    };
    defer alloc.free(payload);

    const result = try controlSession(alloc, dir, name, &.{ "send", payload });
    defer alloc.free(result.text);
    if (!result.ok) return sendError(stream, 500, "slash_failed", result.text);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"sent\":true,\"command\":");
    try appendJsonString(alloc, &out, command.asStr());
    try out.appendSlice(alloc, ",\"line\":");
    try appendJsonString(alloc, &out, line);
    try out.appendSlice(alloc, "}\n");
    return sendOwnedJson(alloc, stream, 200, &out);
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
    query: []const u8,
) !void {
    const dir = try workspaceDirHttp(alloc, workspace);
    defer alloc.free(dir);
    const name = resolveSessionResult(alloc, dir, want) catch |err| return sendResolveError(stream, err);
    defer alloc.free(name);
    const agent_override = if (queryParam(query, "agent")) |id| blk: {
        const agent = harness.Agent.fromId(id) orelse
            return sendError(stream, 400, "bad_agent", "unknown agent");
        if (!agent.hasTranscript()) return sendError(stream, 400, "bad_agent", "agent has no transcript");
        break :blk agent;
    } else null;
    const history = queryBool(query, "history") orelse false;
    const current = queryBool(query, "current") orelse !history;
    var resolved = resolveTranscriptRuns(alloc, dir, name, .{
        .agent_override = agent_override,
        .history = history and !current,
        .current = current or !history,
    }) catch |err| switch (err) {
        error.NotAgent => return sendError(stream, 404, "not_agent", "no agent transcript found"),
        error.BadSidecar => return sendError(stream, 500, "bad_sidecar", "corrupt agent sidecar"),
        error.AmbiguousTranscript => return sendError(stream, 409, "ambiguous_transcript", "multiple matching agent transcripts"),
        else => return err,
    };
    defer resolved.deinit(alloc);
    const body = try renderTranscriptJson(alloc, name, resolved.runs, false);
    defer alloc.free(body);
    return sendJson(stream, 200, body);
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

fn queryBool(query: []const u8, key: []const u8) ?bool {
    const v = queryParam(query, key) orelse return null;
    if (std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1")) return true;
    if (std.mem.eql(u8, v, "false") or std.mem.eql(u8, v, "0")) return false;
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

test "transcript current ranking prefers detected process over stale sidecar" {
    const runs = [_]TranscriptRun{
        .{ .agent = .claude, .source = .sidecar, .confidence = .exact, .updated_at_ms = 10 },
        .{ .agent = .codex, .source = .process, .confidence = .low, .updated_at_ms = 20 },
    };
    try std.testing.expectEqual(@as(?usize, 1), selectCurrentRun(&runs, null, .codex));
}

test "run history parse dedupes sidecar v1 records" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir);

    const sc: harness.Sidecar = .{
        .agent = .claude,
        .session_id = "sid-1",
        .cwd = "/work",
    };
    appendRunHistorySidecar(alloc, dir, "s1", sc, .sidecar, .exact);
    appendRunHistorySidecar(alloc, dir, "s1", sc, .sidecar, .exact);

    var runs: std.ArrayList(TranscriptRun) = .empty;
    defer deinitRunList(alloc, &runs);
    try loadRunHistory(alloc, dir, "s1", &runs);
    try std.testing.expectEqual(@as(usize, 1), runs.items.len);
    try std.testing.expectEqual(harness.Agent.claude, runs.items[0].agent);
    try std.testing.expectEqualStrings("sid-1", runs.items[0].session_id.?);
    try std.testing.expectEqual(ReadSource.sidecar, runs.items[0].source);
}

test "sidecar v1 remains a transcript run candidate" {
    const alloc = std.testing.allocator;
    const data = "{\"agent\":\"codex\",\"session_store\":\"/tmp/codex-home\",\"cwd\":\"/work\"}";
    const sc = try harness.Sidecar.fromJson(alloc, data);
    defer sc.deinit(alloc);
    const run = try runFromSidecar(alloc, sc, .sidecar, .exact);
    defer run.deinit(alloc);
    try std.testing.expectEqual(harness.Agent.codex, run.agent);
    try std.testing.expectEqualStrings("/tmp/codex-home", run.session_store.?);
    try std.testing.expect(run.transcript_key != null);
}

test "bounded cwd scan surfaces ambiguity instead of selecting by mtime" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("sessions/2026/06/24");
    try tmp.dir.writeFile(.{ .sub_path = "sessions/2026/06/24/rollout-a.jsonl", .data = "{\"cwd\":\"/work\"}" });
    try tmp.dir.writeFile(.{ .sub_path = "sessions/2026/06/24/rollout-b.jsonl", .data = "{\"cwd\":\"/work\"}" });
    const root = try tmp.dir.realpathAlloc(alloc, "sessions");
    defer alloc.free(root);
    var runs: std.ArrayList(TranscriptRun) = .empty;
    defer deinitRunList(alloc, &runs);
    const matches = try scanJsonlTree(alloc, .codex, root, "/work", 0, .scan, &runs);
    try std.testing.expectEqual(@as(usize, 2), matches);
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
    _ = @import("slash.zig");
}
