//! End-to-end tests that drive the real moo binary through a real
//! PTY: a test "terminal" (PTY master) hosts the attach client as
//! its controlling terminal, exactly like a user's terminal would.
//! Detached control flows go through the public subcommand CLI.

const std = @import("std");
const posix = std.posix;
const build_options = @import("build_options");
const vt = @import("ghostty-vt");

const exe_path: []const u8 = build_options.exe_path;

extern "c" fn posix_openpt(flags: c_int) c_int;
extern "c" fn grantpt(fd: c_int) c_int;
extern "c" fn unlockpt(fd: c_int) c_int;
extern "c" fn ptsname_r(fd: c_int, buf: [*]u8, len: usize) c_int;
extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;
extern "c" fn kill(pid: std.c.pid_t, sig: c_int) c_int;

const default_timeout_ms: u64 = 10_000;

/// Terminal ioctl request codes; Zig's std lacks the darwin set variants.
const Tio = switch (@import("builtin").os.tag) {
    .macos, .ios, .tvos, .watchos, .visionos => struct {
        const IOCSWINSZ: c_ulong = 0x80087467;
        const IOCSCTTY: c_ulong = 0x20007461;
    },
    else => struct {
        const IOCSWINSZ: c_ulong = std.c.T.IOCSWINSZ;
        const IOCSCTTY: c_ulong = std.c.T.IOCSCTTY;
    },
};

/// Per-test environment: an isolated socket directory under /tmp (kept
/// short because of sockaddr_un path limits).
const Harness = struct {
    alloc: std.mem.Allocator,
    dir: []u8,

    fn init(alloc: std.mem.Allocator) !Harness {
        var random_bytes: [6]u8 = undefined;
        std.crypto.random.bytes(&random_bytes);
        var suffix: [12]u8 = undefined;
        const hex = std.fmt.bufPrint(&suffix, "{x}", .{&random_bytes}) catch unreachable;
        const dir = try std.fmt.allocPrint(alloc, "/tmp/bootest-{s}", .{hex});
        errdefer alloc.free(dir);
        try std.fs.cwd().makePath(dir);
        return .{ .alloc = alloc, .dir = dir };
    }

    fn deinit(self: *Harness) void {
        // Best effort: terminate any session daemons still running.
        if (self.run(&.{ "kill", "--all" })) |result| {
            self.alloc.free(result.stdout);
            self.alloc.free(result.stderr);
        } else |_| {}
        std.Thread.sleep(50 * std.time.ns_per_ms);
        std.fs.cwd().deleteTree(self.dir) catch {};
        self.alloc.free(self.dir);
    }

    fn run(self: *Harness, argv: []const []const u8) !std.process.Child.RunResult {
        return self.runInEnv(null, argv, null);
    }

    /// Run a CLI command with an explicit working directory; cwd null
    /// inherits the test runner's directory.
    fn runIn(
        self: *Harness,
        cwd: ?[]const u8,
        argv: []const []const u8,
    ) !std.process.Child.RunResult {
        return self.runInEnv(cwd, argv, null);
    }

    /// Run a CLI command with MOO_WORKSPACE exported to `ws_env`, the way a
    /// shell inside a workspace session would for nested commands. This
    /// re-injects the variable that runInEnv strips for hermeticity, so the
    /// env-driven workspace path can be exercised without a -w flag.
    fn runWithWorkspaceEnv(
        self: *Harness,
        argv: []const []const u8,
        ws_env: []const u8,
    ) !std.process.Child.RunResult {
        return self.runInEnv(null, argv, ws_env);
    }

    fn runInEnv(
        self: *Harness,
        cwd: ?[]const u8,
        argv: []const []const u8,
        ws_env: ?[]const u8,
    ) !std.process.Child.RunResult {
        // exe_path is relative to the build root; resolve it so a
        // custom cwd does not break spawning.
        var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
        const exe_abs = try std.fs.cwd().realpath(exe_path, &exe_buf);

        var full_argv: std.ArrayList([]const u8) = .empty;
        defer full_argv.deinit(self.alloc);
        try full_argv.append(self.alloc, exe_abs);
        try full_argv.appendSlice(self.alloc, argv);

        var env = try std.process.getEnvMap(self.alloc);
        defer env.deinit();
        // Hermetic: never inherit the developer's own moo session config.
        // A leaked MOO (the host session name) makes the UI treat a
        // same-named session as its host and refuse to focus it, which
        // only reproduces when the suite is run from inside a moo session.
        env.remove("MOO");
        env.remove("MOO_FOREGROUND");
        env.remove("MOO_LOG");
        // A developer running the suite from inside a workspace session would
        // otherwise leak MOO_WORKSPACE into the child and shift every command's
        // socket dir; the -w flag is exercised explicitly instead. A test that
        // wants the env path re-puts it after this remove via ws_env.
        env.remove("MOO_WORKSPACE");
        if (ws_env) |ws| try env.put("MOO_WORKSPACE", ws);
        try env.put("MOO_DIR", self.dir);

        return std.process.Child.run(.{
            .allocator = self.alloc,
            .argv = full_argv.items,
            .cwd = cwd,
            .env_map = &env,
        });
    }

    /// Run a CLI command and require exit code 0.
    fn runOk(self: *Harness, argv: []const []const u8) !void {
        const result = try self.run(argv);
        defer self.alloc.free(result.stdout);
        defer self.alloc.free(result.stderr);
        if (result.term != .Exited or result.term.Exited != 0) {
            std.debug.print("moo {s} failed: {s}\n", .{ argv[0], result.stderr });
            return error.CommandFailed;
        }
    }

    /// Run a CLI command and require a specific exit code.
    fn runExit(self: *Harness, argv: []const []const u8, want: u32) !void {
        const result = try self.run(argv);
        defer self.alloc.free(result.stdout);
        defer self.alloc.free(result.stderr);
        if (result.term != .Exited or result.term.Exited != want) {
            std.debug.print(
                "moo {s}: wanted exit {d}, got {any}: {s}\n",
                .{ argv[0], want, result.term, result.stderr },
            );
            return error.WrongExit;
        }
    }

    fn startDetached(self: *Harness, session: []const u8, cmd: []const []const u8) !void {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(self.alloc);
        try argv.appendSlice(self.alloc, &.{ "new", session, "-d", "--" });
        try argv.appendSlice(self.alloc, cmd);
        const result = try self.run(argv.items);
        defer self.alloc.free(result.stdout);
        defer self.alloc.free(result.stderr);
        if (result.term != .Exited or result.term.Exited != 0) {
            std.debug.print("new -d failed: {s}\n", .{result.stderr});
            return error.StartFailed;
        }
        // The session name lands on stdout for scripts to capture.
        try std.testing.expect(std.mem.indexOf(u8, result.stdout, session) != null);
        try self.waitSessionUp(session);
    }

    fn waitSessionUp(self: *Harness, session: []const u8) !void {
        var deadline = Deadline.init(default_timeout_ms);
        while (true) {
            const result = try self.run(&.{ "peek", session });
            defer self.alloc.free(result.stdout);
            defer self.alloc.free(result.stderr);
            if (result.term == .Exited and result.term.Exited == 0) return;
            try deadline.tick("session did not come up");
        }
    }

    /// Type text into the session, followed by Enter.
    fn sendLine(self: *Harness, session: []const u8, text: []const u8) !void {
        try self.runOk(&.{ "send", session, "--text", text, "--enter" });
    }

    /// Poll the session's screen contents until `needle` shows up.
    /// Returns the matching peek output; caller frees.
    fn waitPeekContains(self: *Harness, session: []const u8, needle: []const u8) ![]u8 {
        var deadline = Deadline.init(default_timeout_ms);
        var last: ?[]u8 = null;
        errdefer if (last) |l| self.alloc.free(l);
        while (true) {
            const result = try self.run(&.{ "peek", session });
            self.alloc.free(result.stderr);
            if (last) |l| self.alloc.free(l);
            last = null;
            if (result.term == .Exited and result.term.Exited == 0) {
                last = result.stdout;
                if (std.mem.indexOf(u8, result.stdout, needle) != null) return result.stdout;
            } else {
                self.alloc.free(result.stdout);
            }
            deadline.tick("peek never contained needle") catch |err| {
                std.debug.print("--- last peek ---\n{s}\n---\n", .{last orelse "<none>"});
                return err;
            };
        }
    }
};

const Deadline = struct {
    end: i64,

    fn init(ms: u64) Deadline {
        return .{ .end = std.time.milliTimestamp() + @as(i64, @intCast(ms)) };
    }

    fn tick(self: *Deadline, comptime what: []const u8) !void {
        if (std.time.milliTimestamp() > self.end) {
            std.debug.print("timeout: " ++ what ++ "\n", .{});
            return error.Timeout;
        }
        std.Thread.sleep(25 * std.time.ns_per_ms);
    }
};

/// A moo client process running on a real PTY owned by the test.
const PtyClient = struct {
    alloc: std.mem.Allocator,
    master: posix.fd_t,
    pid: posix.pid_t,
    output: std.ArrayList(u8) = .empty,
    exited: ?u32 = null,

    fn spawn(
        harness: *Harness,
        argv: []const []const u8,
        rows: u16,
        cols: u16,
    ) !PtyClient {
        return spawnWithEnv(harness, argv, rows, cols, &.{});
    }

    /// Like spawn, but with explicit environment overrides. The default spawn
    /// path stays hermetic; tests that need MOO_WORKSPACE must opt in here.
    fn spawnWithEnv(
        harness: *Harness,
        argv: []const []const u8,
        rows: u16,
        cols: u16,
        env_overrides: []const [2][]const u8,
    ) !PtyClient {
        return spawnProgramWithEnv(harness, exe_path, argv, rows, cols, env_overrides);
    }

    /// Like spawn, but runs an arbitrary program instead of the moo
    /// binary, e.g. a shell wrapping an attach the way a login shell
    /// does for a user.
    fn spawnProgram(
        harness: *Harness,
        program: []const u8,
        argv: []const []const u8,
        rows: u16,
        cols: u16,
    ) !PtyClient {
        return spawnProgramWithEnv(harness, program, argv, rows, cols, &.{});
    }

    fn spawnProgramWithEnv(
        harness: *Harness,
        program: []const u8,
        argv: []const []const u8,
        rows: u16,
        cols: u16,
        env_overrides: []const [2][]const u8,
    ) !PtyClient {
        const alloc = harness.alloc;

        // PTY pair.
        const master = posix_openpt(@bitCast(@as(u32, @bitCast(posix.O{
            .ACCMODE = .RDWR,
            .NOCTTY = true,
        }))));
        if (master < 0) return error.OpenPtyFailed;
        errdefer posix.close(master);
        if (grantpt(master) != 0) return error.OpenPtyFailed;
        if (unlockpt(master) != 0) return error.OpenPtyFailed;
        var path_buf: [128]u8 = undefined;
        if (ptsname_r(master, &path_buf, path_buf.len) != 0) return error.OpenPtyFailed;
        const path_len = std.mem.indexOfScalar(u8, &path_buf, 0) orelse return error.OpenPtyFailed;
        const slave_path = path_buf[0..path_len :0];

        // Open the slave before setting the size: macOS rejects
        // TIOCSWINSZ on the master until the slave has been opened.
        const slave = posix.openZ(slave_path, .{
            .ACCMODE = .RDWR,
            .NOCTTY = true,
        }, 0) catch return error.OpenPtyFailed;
        errdefer posix.close(slave);

        const ws: posix.winsize = .{ .row = rows, .col = cols, .xpixel = 0, .ypixel = 0 };
        if (ioctl(slave, Tio.IOCSWINSZ, @intFromPtr(&ws)) != 0) {
            return error.IoctlFailed;
        }

        // Exec args, prepared before fork.
        var arena_state = std.heap.ArenaAllocator.init(alloc);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const argv0 = try arena.dupeZ(u8, program);
        const argv_z = try arena.allocSentinel(?[*:0]const u8, argv.len + 1, null);
        argv_z[0] = argv0;
        for (argv, 1..) |arg, i| argv_z[i] = try arena.dupeZ(u8, arg);

        var env = try std.process.getEnvMap(arena);
        // Hermetic: drop the developer's own moo session config, as in
        // Harness.runIn — a leaked MOO would set host_name in the UI.
        env.remove("MOO");
        env.remove("MOO_FOREGROUND");
        env.remove("MOO_LOG");
        env.remove("MOO_WORKSPACE");
        for (env_overrides) |entry| try env.put(entry[0], entry[1]);
        try env.put("MOO_DIR", harness.dir);
        const envp = try std.process.createEnvironFromMap(arena, &env, .{});

        const pid = try posix.fork();
        if (pid == 0) {
            // Child: make the inherited PTY slave the controlling
            // terminal (login_tty pattern).
            _ = posix.setsid() catch posix.exit(127);
            if (ioctl(slave, Tio.IOCSCTTY, @as(c_ulong, 0)) != 0) {
                posix.exit(127);
            }
            posix.dup2(slave, 0) catch posix.exit(127);
            posix.dup2(slave, 1) catch posix.exit(127);
            posix.dup2(slave, 2) catch posix.exit(127);
            if (slave > 2) posix.close(slave);
            posix.close(master);
            const err = posix.execveZ(argv0, argv_z, envp);
            _ = err catch {};
            posix.exit(127);
        }

        posix.close(slave);
        return .{ .alloc = alloc, .master = master, .pid = pid };
    }

    fn deinit(self: *PtyClient) void {
        if (self.exited == null) {
            _ = kill(self.pid, posix.SIG.KILL);
            var status: c_int = undefined;
            _ = std.c.waitpid(self.pid, &status, 0);
        }
        posix.close(self.master);
        self.output.deinit(self.alloc);
    }

    fn send(self: *PtyClient, bytes: []const u8) !void {
        var i: usize = 0;
        while (i < bytes.len) i += try posix.write(self.master, bytes[i..]);
    }

    fn setSize(self: *PtyClient, rows: u16, cols: u16) !void {
        const ws: posix.winsize = .{ .row = rows, .col = cols, .xpixel = 0, .ypixel = 0 };
        if (ioctl(self.master, Tio.IOCSWINSZ, @intFromPtr(&ws)) != 0) {
            return error.IoctlFailed;
        }
    }

    fn pump(self: *PtyClient, timeout_ms: i32) !bool {
        var fds = [_]posix.pollfd{
            .{ .fd = self.master, .events = posix.POLL.IN, .revents = 0 },
        };
        const n = try posix.poll(&fds, timeout_ms);
        if (n == 0) return false;
        var buf: [4096]u8 = undefined;
        const got = posix.read(self.master, &buf) catch |err| switch (err) {
            error.InputOutput => return error.ClientGone,
            else => return err,
        };
        if (got == 0) return error.ClientGone;
        try self.output.appendSlice(self.alloc, buf[0..got]);
        return true;
    }

    /// Read output until `needle` appears anywhere in the accumulated
    /// stream. Fails loudly with the captured output on timeout.
    fn waitFor(self: *PtyClient, needle: []const u8) !void {
        var deadline = Deadline.init(default_timeout_ms);
        while (std.mem.indexOf(u8, self.output.items, needle) == null) {
            _ = self.pump(100) catch |err| switch (err) {
                error.ClientGone => {
                    if (std.mem.indexOf(u8, self.output.items, needle) != null) return;
                    std.debug.print(
                        "client exited; output so far:\n{s}\n",
                        .{self.output.items},
                    );
                    return err;
                },
                else => return err,
            };
            deadline.tick("waiting for output") catch |err| {
                std.debug.print(
                    "--- waiting for {s} --- captured:\n{s}\n---\n",
                    .{ needle, self.output.items },
                );
                return err;
            };
        }
    }

    /// Drop accumulated output so later waitFor calls only see new data.
    fn clearOutput(self: *PtyClient) void {
        self.output.clearRetainingCapacity();
    }

    fn waitExit(self: *PtyClient) !u32 {
        if (self.exited) |code| return code;
        var deadline = Deadline.init(default_timeout_ms);
        while (true) {
            var status: c_int = undefined;
            const r = std.c.waitpid(self.pid, &status, std.c.W.NOHANG);
            if (r == self.pid) {
                const code: u32 = if (std.c.W.IFEXITED(@bitCast(status)))
                    std.c.W.EXITSTATUS(@bitCast(status))
                else
                    128;
                self.exited = code;
                return code;
            }
            // Keep draining the PTY so the client can't block on writes.
            _ = self.pump(0) catch {};
            try deadline.tick("waiting for client exit");
        }
    }
};

fn waitFileEquals(alloc: std.mem.Allocator, path: []const u8, expected: []const u8) !void {
    var deadline = Deadline.init(default_timeout_ms);
    while (true) {
        const content = std.fs.cwd().readFileAlloc(alloc, path, 4096) catch "";
        defer if (content.len > 0) alloc.free(content);
        if (std.mem.eql(u8, content, expected)) return;
        deadline.tick("file never matched") catch |err| {
            std.debug.print("--- file {s} content: {s} (wanted {s})\n", .{ path, content, expected });
            return err;
        };
    }
}

test "detached session: send and peek round-trip through libghostty" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    try h.startDetached("t1", &.{"cat"});
    try h.sendLine("t1", "round-trip-42");

    const content = try h.waitPeekContains("t1", "round-trip-42");
    defer alloc.free(content);
}

test "vt sequences: cursor movement, SGR, and clear are emulated" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    try h.startDetached("t2", &.{"cat"});
    // Paint NOISE, clear the screen, write at row 3 col 5, color a
    // word. send carries the raw ESC bytes; no escaping layer.
    try h.sendLine("t2", "NOISE\x1b[2J\x1b[3;5HPOS\x1b[1;31mRED\x1b[0m-END");

    const content = try h.waitPeekContains("t2", "POSRED-END");
    defer alloc.free(content);

    // The clear must have removed earlier output.
    try std.testing.expect(std.mem.indexOf(u8, content, "NOISE") == null);

    // Row 3 starts with 4 blank columns (cursor positioning worked and
    // the peek reflects screen geometry, not the byte stream).
    var lines = std.mem.splitScalar(u8, content, '\n');
    _ = lines.next(); // row 1
    _ = lines.next(); // row 2
    const row3 = lines.next() orelse return error.MissingRow;
    try std.testing.expect(std.mem.startsWith(u8, row3, "    POS"));
}

test "attach over a real tty: echo, then detach with C-a d" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    var client = try PtyClient.spawn(&h, &.{ "new", "t3", "--", "cat" }, 24, 80);
    defer client.deinit();
    try h.waitSessionUp("t3");

    try client.send("typed-into-tty\r");
    try client.waitFor("typed-into-tty");

    try client.send("\x01d"); // C-a d
    try client.waitFor("detached from t3");
    try std.testing.expectEqual(@as(u32, 0), try client.waitExit());

    // Session survives the detach.
    const result = try h.run(&.{"ls"});
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "t3") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "detached") != null);
}

test "reattach rehydrates the screen from terminal state" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    try h.startDetached("t4", &.{"cat"});
    try h.sendLine("t4", "persisted-99");
    const content = try h.waitPeekContains("t4", "persisted-99");
    alloc.free(content);

    // Reattach: the repaint must reproduce content written while detached.
    var client = try PtyClient.spawn(&h, &.{ "attach", "t4" }, 24, 80);
    defer client.deinit();
    try client.waitFor("persisted-99");

    try client.send("\x01d");
    try client.waitFor("detached from t4");
    _ = try client.waitExit();
}

test "window size: initial attach size and SIGWINCH resize reach the app" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    var client = try PtyClient.spawn(&h, &.{ "new", "t5", "--", "/bin/sh" }, 12, 57);
    defer client.deinit();
    try h.waitSessionUp("t5");

    const size_file = try std.fmt.allocPrint(alloc, "{s}/size.txt", .{h.dir});
    defer alloc.free(size_file);

    const cmd1 = try std.fmt.allocPrint(alloc, "stty size > {s}", .{size_file});
    defer alloc.free(cmd1);
    try h.sendLine("t5", cmd1);
    try waitFileEquals(alloc, size_file, "12 57\n");

    // Dynamic resize: change the outer terminal size; SIGWINCH propagates
    // client -> daemon -> window PTY.
    try client.setSize(30, 90);
    var deadline = Deadline.init(default_timeout_ms);
    while (true) {
        try h.sendLine("t5", cmd1);
        std.Thread.sleep(50 * std.time.ns_per_ms);
        const content = std.fs.cwd().readFileAlloc(alloc, size_file, 4096) catch "";
        defer if (content.len > 0) alloc.free(content);
        if (std.mem.eql(u8, content, "30 90\n")) break;
        try deadline.tick("resize never reached the inner tty");
    }
}

test "default session name comes from the working directory" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    // A directory whose basename is a valid session name. Living under
    // h.dir gets it cleaned up with the harness; the daemon ignores
    // non-socket entries there.
    const proj = try std.fs.path.join(alloc, &.{ h.dir, "spooky-proj" });
    defer alloc.free(proj);
    try std.fs.cwd().makePath(proj);

    const first = try h.runIn(proj, &.{ "new", "-d", "--", "cat" });
    defer alloc.free(first.stdout);
    defer alloc.free(first.stderr);
    try std.testing.expect(first.term.Exited == 0);
    try std.testing.expectEqualStrings("spooky-proj\n", first.stdout);
    try h.waitSessionUp("spooky-proj");

    // The name is taken now, so the next session falls back to the
    // creating process id.
    const second = try h.runIn(proj, &.{ "new", "-d", "--", "cat" });
    defer alloc.free(second.stdout);
    defer alloc.free(second.stderr);
    try std.testing.expect(second.term.Exited == 0);
    const pid_name = std.mem.trimRight(u8, second.stdout, "\n");
    try std.testing.expect(pid_name.len > 0);
    for (pid_name) |c| try std.testing.expect(std.ascii.isDigit(c));

    const ls = try h.run(&.{"ls"});
    defer alloc.free(ls.stdout);
    defer alloc.free(ls.stderr);
    try std.testing.expect(std.mem.indexOf(u8, ls.stdout, "spooky-proj") != null);
    try std.testing.expect(std.mem.indexOf(u8, ls.stdout, pid_name) != null);
}

test "session listing shows attach state" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    try h.startDetached("listed", &.{"cat"});

    const detached = try h.run(&.{"ls"});
    defer alloc.free(detached.stdout);
    defer alloc.free(detached.stderr);
    try std.testing.expect(std.mem.indexOf(u8, detached.stdout, "listed") != null);
    try std.testing.expect(std.mem.indexOf(u8, detached.stdout, "detached") != null);
    // The listing includes the session's title (the launch command
    // until the app sets one).
    try std.testing.expect(std.mem.indexOf(u8, detached.stdout, "TITLE") != null);
    try std.testing.expect(std.mem.indexOf(u8, detached.stdout, "cat") != null);

    // `at` is the documented shorthand for attach.
    var client = try PtyClient.spawn(&h, &.{ "at", "listed" }, 24, 80);
    defer client.deinit();

    var deadline = Deadline.init(default_timeout_ms);
    while (true) {
        const attached = try h.run(&.{"ls"});
        defer alloc.free(attached.stdout);
        defer alloc.free(attached.stderr);
        if (std.mem.indexOf(u8, attached.stdout, "attached") != null) break;
        try deadline.tick("session never showed as attached");
    }
}

test "kill ends the session and notifies the attached client" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    var client = try PtyClient.spawn(&h, &.{ "new", "t8", "--", "cat" }, 24, 80);
    defer client.deinit();
    try h.waitSessionUp("t8");

    try h.runOk(&.{ "kill", "t8" });
    try client.waitFor("session t8 ended");
    try std.testing.expectEqual(@as(u32, 0), try client.waitExit());

    // The socket is gone: session commands now fail with exit 3.
    try h.runExit(&.{ "peek", "t8" }, 3);
}

test "attach without a tty fails cleanly" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    try h.startDetached("t9", &.{"cat"});
    const result = try h.run(&.{ "attach", "t9" });
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    try std.testing.expect(result.term == .Exited and result.term.Exited == 1);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "requires a terminal") != null);
}

test "attached client renders inside the terminal's alternate screen" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    var client = try PtyClient.spawn(&h, &.{ "new", "wrap", "--", "cat" }, 24, 80);
    defer client.deinit();
    try h.waitSessionUp("wrap");

    try client.send("inside-the-canvas\r");
    try client.waitFor("inside-the-canvas");

    // The client enters the alternate screen before any session content.
    const enter = std.mem.indexOf(u8, client.output.items, "\x1b[?1049h") orelse
        return error.MissingAltScreenEnter;
    const content = std.mem.indexOf(u8, client.output.items, "inside-the-canvas").?;
    try std.testing.expect(enter < content);

    try client.send("\x01d"); // C-a d
    try client.waitFor("detached from wrap");
    try std.testing.expectEqual(@as(u32, 0), try client.waitExit());

    // Detach leaves the alternate screen, restoring the user's shell
    // view, before the detach notice is printed.
    const leave = std.mem.lastIndexOf(u8, client.output.items, "\x1b[?1049l").?;
    const notice = std.mem.indexOf(u8, client.output.items, "detached from wrap").?;
    try std.testing.expect(leave < notice);
}

test "C-a C-d detaches like GNU screen" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    var client = try PtyClient.spawn(&h, &.{ "new", "ctrld", "--", "cat" }, 24, 80);
    defer client.deinit();
    try h.waitSessionUp("ctrld");

    try client.send("\x01\x04"); // C-a C-d
    try client.waitFor("detached from ctrld");
    try std.testing.expectEqual(@as(u32, 0), try client.waitExit());

    const result = try h.run(&.{"ls"});
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "detached") != null);
}

test "auto-repeated C-a stays armed until the command key" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    var client = try PtyClient.spawn(&h, &.{ "new", "rpt", "--", "cat" }, 24, 80);
    defer client.deinit();
    try h.waitSessionUp("rpt");

    // Holding the prefix key auto-repeats it: C-a C-a C-d. The
    // repeats must keep the prefix armed rather than claim the
    // command slot, or the trailing C-d leaks into the window and
    // EOFs the program.
    try client.send("\x01\x01\x04");
    try client.waitFor("detached from rpt");
    try std.testing.expectEqual(@as(u32, 0), try client.waitExit());

    // The session survived: nothing reached cat.
    const result = try h.run(&.{"ls"});
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "rpt") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "detached") != null);
}

/// Drive a detach with a command key that is still held while the
/// detach completes, the way a human does it over a remote link: the
/// key keeps auto-repeating until the restored screen is visible, and
/// one final repeat lands after the client has already restored. The
/// attach runs under a wrapping shell on the same tty (a login shell
/// stand-in) whose `read` exposes any input that moo leaks: leaked
/// repeats corrupt the typed probe line, and a leaked C-d (EOF) ends
/// the read prematurely, which is the SSH-session-killer variant.
fn expectNoDetachKeyLeak(
    h: *Harness,
    session: []const u8,
    key: []const u8,
    late_repeat_ms: ?i64,
) !void {
    const alloc = h.alloc;

    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_abs = try std.fs.cwd().realpath(exe_path, &exe_buf);
    const script = try std.fmt.allocPrint(
        alloc,
        "{s} attach {s}; IFS= read -r line; printf 'GOT[%s]\\n' \"$line\"",
        .{ exe_abs, session },
    );
    defer alloc.free(script);

    var client = try PtyClient.spawnProgram(h, "/bin/sh", &.{ "-c", script }, 24, 80);
    defer client.deinit();
    try client.waitFor("\x1b[?1049h");

    // Arm the prefix, then press the command key. The key arrives
    // with its first auto-repeat coalesced into one read, the way a
    // remote link batches keystrokes; the repeat must not be
    // forwarded into the window after the detach dispatches.
    try client.send("\x01");
    std.Thread.sleep(50 * std.time.ns_per_ms);
    const pressed_at = std.time.milliTimestamp();
    const pressed = try std.mem.concat(alloc, u8, &.{ key, key });
    defer alloc.free(pressed);
    try client.send(pressed);

    // Hold the key: auto-repeats keep arriving until the user sees
    // the restored screen.
    var deadline = Deadline.init(default_timeout_ms);
    while (std.mem.indexOf(u8, client.output.items, "\x1b[?1049l") == null) {
        try client.send(key);
        _ = try client.pump(30);
        try deadline.tick("detach restore never arrived");
    }
    // The release lags the restored screen by one repeat interval, so
    // this repeat arrives after the client's own restore write. It
    // must be absorbed before the shell regains the terminal.
    try client.send(key);

    // A keyboard with a long repeat delay sends its first repeat well
    // after the detach; the EOF guard has to outlast it. Real repeat
    // delays anchor at the press, so anchor there too: the margin to
    // the 800ms guard stays wide even on slow CI runners, while still
    // proving the 300ms short guard alone would have missed it.
    if (late_repeat_ms) |ms| {
        const elapsed = std.time.milliTimestamp() - pressed_at;
        if (elapsed < ms) {
            std.Thread.sleep(@intCast((ms - elapsed) * std.time.ns_per_ms));
        }
        try client.send(key);
    }

    // Type at the shell prompt once the key is long released. The
    // pause must outlast the client's post-detach drain window so the
    // probe reaches the shell, not the drain.
    std.Thread.sleep(1500 * std.time.ns_per_ms);
    try client.send("ok\n");
    try client.waitFor("GOT[ok]");
    try std.testing.expectEqual(@as(u32, 0), try client.waitExit());

    // The detach happened and the session survived.
    const result = try h.run(&.{"ls"});
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, session) != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "detached") != null);

    // Nothing leaked into the window either: the idle cat session's
    // screen stays empty.
    const peek = try h.run(&.{ "peek", session });
    defer alloc.free(peek.stdout);
    defer alloc.free(peek.stderr);
    try std.testing.expect(peek.term.Exited == 0);
    try std.testing.expect(std.mem.indexOf(u8, peek.stdout, "d") == null);
}

test "held C-a d: repeats do not leak into the shell after detach" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    try h.startDetached("dleak", &.{"cat"});
    try expectNoDetachKeyLeak(&h, "dleak", "d", null);
}

test "held C-a C-d: repeats do not EOF the shell after detach" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    // The late repeat models a keyboard with a slow repeat delay
    // (450ms after the press): past the short guard, only the long
    // EOF guard absorbs it.
    try h.startDetached("eofleak", &.{"cat"});
    try expectNoDetachKeyLeak(&h, "eofleak", "\x04", 450);
}

test "alt screen apps: toggles are filtered and screens repaint from state" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    try h.startDetached("altapp", &.{"sh"});

    // Put a marker on the primary screen.
    try h.sendLine("altapp", "echo PRIMARY-MARK");
    const peeked = try h.waitPeekContains("altapp", "PRIMARY-MARK");
    alloc.free(peeked);

    var client = try PtyClient.spawn(&h, &.{ "attach", "altapp" }, 24, 80);
    defer client.deinit();
    try client.waitFor("PRIMARY-MARK");
    client.clearOutput();

    // The app enters the alternate screen. The raw toggle must never
    // reach the client (its canvas cannot switch screens); the alt
    // content arrives via a repaint instead. The echoed command line
    // also contains "ALT-MARK", so wait for the marker to show up
    // after a repaint's canvas clear specifically.
    try h.sendLine("altapp", "printf '\\033[?1049h\\033[H\\033[2JALT-MARK\\n'");
    var deadline = Deadline.init(default_timeout_ms);
    while (true) {
        if (std.mem.lastIndexOf(u8, client.output.items, "\x1b[H\x1b[2J")) |clear_pos| {
            if (std.mem.indexOfPos(u8, client.output.items, clear_pos, "ALT-MARK") != null) break;
        }
        _ = try client.pump(100);
        try deadline.tick("alt screen repaint never arrived");
    }
    try std.testing.expect(
        std.mem.indexOf(u8, client.output.items, "\x1b[?1049h") == null,
    );
    client.clearOutput();

    // The app leaves the alternate screen: still no raw toggle, and
    // the primary screen content is repainted from terminal state
    // rather than left blank.
    try h.sendLine("altapp", "printf '\\033[?1049l'");
    try client.waitFor("PRIMARY-MARK");
    try std.testing.expect(
        std.mem.indexOf(u8, client.output.items, "\x1b[?1049l") == null,
    );

    try client.send("\x01d");
    try client.waitFor("detached from altapp");
    _ = try client.waitExit();
}

test "queries in a discarded passthrough span are answered" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    // On a go-signal, emit an alternate-screen toggle immediately
    // followed by a cursor-position query, then block until the
    // response arrives. This mirrors shells that probe the terminal
    // at startup: the toggle flips passthrough into discard mode, so
    // the query never reaches the test terminal (which would not
    // answer anyway); only the daemon can unblock the read.
    const go_path = try std.fmt.allocPrint(alloc, "{s}/go", .{h.dir});
    defer alloc.free(go_path);
    const script = try std.fmt.allocPrint(
        alloc,
        "while [ ! -e {s} ]; do sleep 0.02; done; " ++
            "printf '\\033[?1049l\\033[6n'; " ++
            "IFS= read -rs -d R pos; " ++
            "printf 'CPR-ANSWERED\\n'; sleep 5",
        .{go_path},
    );
    defer alloc.free(script);

    var client = try PtyClient.spawn(&h, &.{ "new", "qry", "--", "bash", "-c", script }, 24, 80);
    defer client.deinit();
    try h.waitSessionUp("qry");
    // Wait for the attach repaint so the burst takes the passthrough
    // path rather than being answered as an unattached window.
    try client.waitFor("\x1b[H\x1b[2J");

    try std.fs.cwd().writeFile(.{ .sub_path = go_path, .data = "" });
    try client.waitFor("CPR-ANSWERED");
}

test "reattach restores the window title" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    try h.startDetached("ttl", &.{"sh"});

    // Set the title from inside the session. The title is assembled
    // from two printf arguments so the echoed command line (which
    // ends up in the repainted screen content) never contains the
    // assembled marker.
    try h.sendLine("ttl", "printf '\\033]2;TTL-%s\\007' MARK");

    // The session listing reflects the OSC title once processed.
    var deadline = Deadline.init(default_timeout_ms);
    while (true) {
        const result = try h.run(&.{"ls"});
        const found = std.mem.indexOf(u8, result.stdout, "TTL-MARK") != null;
        alloc.free(result.stdout);
        alloc.free(result.stderr);
        if (found) break;
        try deadline.tick("session title never updated");
    }

    // Reattach: the repaint must restore the title on the client's
    // terminal, not just the screen contents.
    var client = try PtyClient.spawn(&h, &.{ "attach", "ttl" }, 24, 80);
    defer client.deinit();
    try client.waitFor("\x1b]2;TTL-MARK\x07");

    try client.send("\x01d");
    try client.waitFor("detached from ttl");
    _ = try client.waitExit();
}

test "help: overview, command pages, topics, and version" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    const overview = try h.run(&.{"help"});
    defer alloc.free(overview.stdout);
    defer alloc.free(overview.stderr);
    try std.testing.expect(overview.term.Exited == 0);
    try std.testing.expect(std.mem.indexOf(u8, overview.stdout, "commands:") != null);
    try std.testing.expect(std.mem.indexOf(u8, overview.stdout, "kill") != null);
    try std.testing.expect(std.mem.indexOf(u8, overview.stdout, "attach, at, a <name>") != null);

    // The overview stays lean: no topics or exit-code sections (the
    // codes live on the automation page).
    try std.testing.expect(std.mem.indexOf(u8, overview.stdout, "topics:") == null);
    try std.testing.expect(std.mem.indexOf(u8, overview.stdout, "exit codes:") == null);

    const send_page = try h.run(&.{ "help", "send" });
    defer alloc.free(send_page.stdout);
    defer alloc.free(send_page.stderr);
    try std.testing.expect(send_page.term.Exited == 0);
    try std.testing.expect(std.mem.indexOf(u8, send_page.stdout, "--enter") != null);
    try std.testing.expect(std.mem.indexOf(u8, send_page.stdout, "--key") != null);

    const automation = try h.run(&.{ "help", "automation" });
    defer alloc.free(automation.stdout);
    defer alloc.free(automation.stderr);
    try std.testing.expect(automation.term.Exited == 0);
    try std.testing.expect(std.mem.indexOf(u8, automation.stdout, "wait") != null);

    const all = try h.run(&.{ "help", "--all" });
    defer alloc.free(all.stdout);
    defer alloc.free(all.stderr);
    try std.testing.expect(all.term.Exited == 0);
    try std.testing.expect(all.stdout.len > overview.stdout.len);

    const ver = try h.run(&.{"version"});
    defer alloc.free(ver.stdout);
    defer alloc.free(ver.stderr);
    try std.testing.expect(std.mem.startsWith(u8, ver.stdout, "moo "));
}

test "ls emits machine-readable JSON" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    try h.startDetached("js", &.{"cat"});

    const ls = try h.run(&.{ "ls", "--json" });
    defer alloc.free(ls.stdout);
    defer alloc.free(ls.stderr);
    try std.testing.expect(ls.term.Exited == 0);
    {
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, ls.stdout, .{});
        defer parsed.deinit();
        const sessions = parsed.value.array.items;
        try std.testing.expectEqual(@as(usize, 1), sessions.len);
        const obj = sessions[0].object;
        try std.testing.expectEqualStrings("js", obj.get("name").?.string);
        try std.testing.expectEqual(false, obj.get("attached").?.bool);
        try std.testing.expect(obj.get("idle_ms").?.integer >= 0);
        try std.testing.expectEqualStrings("cat", obj.get("title").?.string);
    }
}

test "peek --json includes geometry, cursor, and screen content" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    try h.startDetached("pj", &.{"cat"});
    try h.sendLine("pj", "json-peek-mark");
    const content = try h.waitPeekContains("pj", "json-peek-mark");
    alloc.free(content);

    const peek = try h.run(&.{ "peek", "pj", "--json" });
    defer alloc.free(peek.stdout);
    defer alloc.free(peek.stderr);
    try std.testing.expect(peek.term.Exited == 0);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, peek.stdout, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("pj", obj.get("session").?.string);
    try std.testing.expect(obj.get("rows").?.integer > 0);
    try std.testing.expect(obj.get("cols").?.integer > 0);
    try std.testing.expect(obj.get("cursor").?.object.get("row").?.integer >= 1);
    try std.testing.expect(
        std.mem.indexOf(u8, obj.get("screen").?.string, "json-peek-mark") != null,
    );
}

test "send --key presses named keys" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    try h.startDetached("keys", &.{"cat"});
    // Type a line without Enter, then press Enter by name; cat only
    // echoes the line back once the key arrives.
    try h.runOk(&.{ "send", "keys", "--text", "key-mark" });
    try h.runOk(&.{ "send", "keys", "--key", "Enter" });
    const content = try h.waitPeekContains("keys", "key-mark");
    defer alloc.free(content);
}

test "wait --text and --idle observe session output" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    try h.startDetached("w1", &.{"cat"});
    try h.sendLine("w1", "wait-mark");

    // --text: returns once the text is on screen. The =value flag
    // spelling is accepted too.
    try h.runOk(&.{ "wait", "w1", "--text=wait-mark", "--timeout", "10s" });

    // --idle: cat produces no further output, so this settles once
    // the screen has been quiet for the built-in threshold.
    try h.runOk(&.{ "wait", "w1", "--idle", "--timeout", "10s" });

    // Timeout: text that never appears exits with the documented code.
    try h.runExit(&.{ "wait", "w1", "--text", "NEVER-APPEARS", "--timeout", "300ms" }, 4);
}

test "zero-arg moo prints the help overview" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    const result = try h.run(&.{});
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    try std.testing.expect(result.term == .Exited and result.term.Exited == 0);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "usage:") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "commands:") != null);

    // Unlike earlier versions, no session is created or attached.
    const ls = try h.run(&.{"ls"});
    defer alloc.free(ls.stdout);
    defer alloc.free(ls.stderr);
    try std.testing.expect(std.mem.indexOf(u8, ls.stdout, "No sessions") != null);
}

test "kill --all banishes every session" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    try h.startDetached("ghost1", &.{"cat"});
    try h.startDetached("ghost2", &.{"cat"});
    try h.runOk(&.{ "kill", "--all" });

    var deadline = Deadline.init(default_timeout_ms);
    while (true) {
        const result = try h.run(&.{"ls"});
        const empty = std.mem.indexOf(u8, result.stdout, "No sessions") != null;
        alloc.free(result.stdout);
        alloc.free(result.stderr);
        if (empty) break;
        try deadline.tick("sessions survived kill --all");
    }
    try h.runExit(&.{ "peek", "ghost1" }, 3);
}

test "exit codes distinguish usage, missing sessions, and ambiguity" {
    var h = try Harness.init(std.testing.allocator);
    defer h.deinit();

    try h.startDetached("alpha", &.{"cat"});
    try h.startDetached("alike", &.{"cat"});

    // Unique prefix resolves; ambiguous prefix and unknown names exit 3.
    try h.runOk(&.{ "peek", "alp" });
    try h.runExit(&.{ "peek", "al" }, 3);
    try h.runExit(&.{ "attach", "nosuchzz" }, 3);
    try h.runExit(&.{ "a", "nosuchzz" }, 3);
    try h.runExit(&.{ "kill", "nosuchzz" }, 3);

    // Session names are required; nothing is guessed.
    try h.runExit(&.{"kill"}, 2);
    try h.runExit(&.{"attach"}, 2);
    try h.runExit(&.{"a"}, 2);
    try h.runExit(&.{"peek"}, 2);

    // Usage errors exit 2.
    try h.runExit(&.{"frobnicate"}, 2);
    try h.runExit(&.{ "wait", "alpha" }, 2);
    try h.runExit(&.{ "send", "alpha", "--key", "NoSuchKey" }, 2);
    try h.runExit(&.{ "send", "alpha", "--text", "text", "--key", "Enter" }, 2);
    try h.runExit(&.{ "help", "nosuchtopic" }, 2);
    try h.runExit(&.{ "kill", "--all", "alpha" }, 2);
}

test "kitty keyboard apps: encoded C-a still detaches" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    var client = try PtyClient.spawn(&h, &.{ "new", "kt", "--", "bash", "--norc" }, 24, 80);
    defer client.deinit();
    try h.waitSessionUp("kt");
    try client.waitFor("\x1b[H\x1b[2J"); // attach repaint

    // The app enters the alt screen and enables kitty keyboard
    // disambiguation, like a modern TUI. The passthrough mirrors both
    // onto the client's terminal, which then encodes Ctrl+A as
    // CSI 97;5u instead of 0x01. The marker is printed after the
    // kitty enable and assembled from two printf arguments: by the
    // time it is visible the daemon has processed the enable, and the
    // echoed command line never contains the assembled marker (the
    // tty echo would otherwise satisfy the wait while the keys still
    // leak into the window).
    try client.send("printf '\\033[?1049h\\033[H\\033[2J\\033[>1uKITTY-%s\\n' APP; read x\r");
    try client.waitFor("KITTY-APP");

    // Press C-a d the way a kitty-mode terminal sends it.
    client.clearOutput();
    try client.send("\x1b[97;5u");
    try client.send("d");
    try client.waitFor("detached from kt");
    try std.testing.expectEqual(@as(u32, 0), try client.waitExit());

    // The keys were intercepted, not leaked into the window.
    const peek = try h.run(&.{ "peek", "kt" });
    defer alloc.free(peek.stdout);
    defer alloc.free(peek.stderr);
    try std.testing.expect(peek.term.Exited == 0);
    try std.testing.expect(std.mem.indexOf(u8, peek.stdout, "97;5u") == null);

    // The session survives, and the kitty-encoded C-a C-d variant
    // detaches as well after a reattach.
    var second = try PtyClient.spawn(&h, &.{ "attach", "kt" }, 24, 80);
    defer second.deinit();
    try second.waitFor("KITTY-APP");
    try second.send("\x1b[97;5u\x1b[100;5u");
    try second.waitFor("detached from kt");
    try std.testing.expectEqual(@as(u32, 0), try second.waitExit());
}

test "kitty keyboard apps: auto-repeated C-a still detaches" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    // The session enables kitty disambiguation before any client
    // attaches, so an attaching client's terminal kitty-encodes
    // every key, including the held prefix.
    try h.startDetached("krpt", &.{
        "sh", "-c", "printf '\\033[>1uKITTY-ON\\n'; exec cat",
    });
    const seeded = try h.waitPeekContains("krpt", "KITTY-ON");
    alloc.free(seeded);

    var client = try PtyClient.spawn(&h, &.{ "attach", "krpt" }, 24, 80);
    defer client.deinit();
    try client.waitFor("KITTY-ON");

    // Holding the prefix repeats CSI 97;5u. The repeat must not be
    // taken as the command key; the C-d that follows still detaches.
    client.clearOutput();
    try client.send("\x1b[97;5u\x1b[97;5u\x1b[100;5u");
    try client.waitFor("detached from krpt");
    try std.testing.expectEqual(@as(u32, 0), try client.waitExit());

    // The keys were intercepted, not leaked into the window.
    const peek = try h.run(&.{ "peek", "krpt" });
    defer alloc.free(peek.stdout);
    defer alloc.free(peek.stderr);
    try std.testing.expect(peek.term.Exited == 0);
    try std.testing.expect(std.mem.indexOf(u8, peek.stdout, "97;5u") == null);
}

test "modifyOtherKeys apps: encoded C-a still detaches" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    var client = try PtyClient.spawn(&h, &.{ "new", "mok", "--", "bash", "--norc" }, 24, 80);
    defer client.deinit();
    try h.waitSessionUp("mok");
    try client.waitFor("\x1b[H\x1b[2J"); // attach repaint

    // The app enables xterm modifyOtherKeys mode 2, like vim. The
    // passthrough mirrors it onto the client's terminal, which (on
    // xterm-faithful terminals) then encodes Ctrl+A as CSI 27;5;97~
    // instead of 0x01. The marker is assembled from two printf
    // arguments so the echoed command line cannot satisfy the wait.
    try client.send("printf '\\033[>4;2mMODIFY-%s\\n' APP; read x\r");
    try client.waitFor("MODIFY-APP");
    try client.waitFor("\x1b[>4;2m");

    // Press C-a d the way such a terminal sends it.
    client.clearOutput();
    try client.send("\x1b[27;5;97~");
    try client.send("d");
    try client.waitFor("detached from mok");
    try std.testing.expectEqual(@as(u32, 0), try client.waitExit());

    // The keys were intercepted, not leaked into the window.
    const peek = try h.run(&.{ "peek", "mok" });
    defer alloc.free(peek.stdout);
    defer alloc.free(peek.stderr);
    try std.testing.expect(peek.term.Exited == 0);
    try std.testing.expect(std.mem.indexOf(u8, peek.stdout, "27;5;97") == null);

    // The session survives; a reattach repaint replays the mode, and
    // the fully encoded C-a C-d variant detaches as well.
    var second = try PtyClient.spawn(&h, &.{ "attach", "mok" }, 24, 80);
    defer second.deinit();
    try second.waitFor("MODIFY-APP");
    try second.waitFor("\x1b[>4;2m");
    try second.send("\x1b[27;5;97~\x1b[27;5;100~");
    try second.waitFor("detached from mok");
    try std.testing.expectEqual(@as(u32, 0), try second.waitExit());
}

test "agent loop: new, send, wait, peek, kill" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    // The documented automation loop, end to end, with no terminal.
    try h.startDetached("agent", &.{"sh"});
    try h.sendLine("agent", "echo result-$((40+2))");
    try h.runOk(&.{ "wait", "agent", "--text", "result-42", "--timeout", "10s" });
    try h.runOk(&.{ "wait", "agent", "--idle", "--timeout=10s" });

    const content = try h.waitPeekContains("agent", "result-42");
    defer alloc.free(content);

    try h.runOk(&.{ "kill", "agent" });
    try h.runExit(&.{ "peek", "agent" }, 3);
}

test "agent: --agent writes a sidecar, read classifies, kill cleans up" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    // Wrap a fake long-running agent (sh acting as `cat`). --agent claude
    // augments the launch (a pinned --session-id, harmless to sh) and records a
    // sidecar, so no real `claude` binary is needed for the plumbing test.
    const new = try h.run(&.{ "new", "agx", "--agent", "claude", "-d", "--", "sh", "-c", "cat" });
    defer alloc.free(new.stdout);
    defer alloc.free(new.stderr);
    try std.testing.expect(new.term.Exited == 0);
    try h.waitSessionUp("agx");

    // The sidecar exists beside the socket and records the harness id.
    const sc_path = try std.fs.path.join(alloc, &.{ h.dir, "agx.agent" });
    defer alloc.free(sc_path);
    const sc_data = try std.fs.cwd().readFileAlloc(alloc, sc_path, 1 << 16);
    defer alloc.free(sc_data);
    {
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, sc_data, .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings("claude", parsed.value.object.get("agent").?.string);
    }

    // read resolves the live session and classifies from the (absent) transcript.
    const read = try h.run(&.{ "read", "agx", "--json" });
    defer alloc.free(read.stdout);
    defer alloc.free(read.stderr);
    try std.testing.expect(read.term.Exited == 0);
    {
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, read.stdout, .{});
        defer parsed.deinit();
        const obj = parsed.value.object;
        try std.testing.expectEqualStrings("agx", obj.get("session").?.string);
        try std.testing.expectEqualStrings("claude", obj.get("agent").?.string);
        try std.testing.expect(obj.get("state") != null);
    }

    // kill removes the sidecar.
    try h.runOk(&.{ "kill", "agx" });
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().access(sc_path, .{}));
}

test "agent: read --agent de-noises a saved transcript file" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    const path = try std.fs.path.join(alloc, &.{ h.dir, "codex.jsonl" });
    defer alloc.free(path);
    try std.fs.cwd().writeFile(.{
        .sub_path = path,
        .data =
        \\{"type":"event_msg","payload":{"type":"user_message","message":"hello CDX"}}
        \\{"type":"event_msg","payload":{"type":"agent_message","message":"reply RPLY-TOKEN"}}
        \\{"type":"event_msg","payload":{"type":"task_complete"}}
        ,
    });

    const read = try h.run(&.{ "read", "--agent", "codex", path, "--json" });
    defer alloc.free(read.stdout);
    defer alloc.free(read.stderr);
    try std.testing.expect(read.term.Exited == 0);
    try std.testing.expect(std.mem.indexOf(u8, read.stdout, "RPLY-TOKEN") != null);
    try std.testing.expect(std.mem.indexOf(u8, read.stdout, "hello CDX") != null);

    // A non-transcript agent kind is a usage error, matching the read help.
    try h.runExit(&.{ "read", "--agent", "bash", path }, 2);
}

test "agent: rename moves the sidecar so read still resolves it" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    const new = try h.run(&.{ "new", "ag1", "--agent", "claude", "-d", "--", "sh", "-c", "cat" });
    defer alloc.free(new.stdout);
    defer alloc.free(new.stderr);
    try std.testing.expect(new.term.Exited == 0);
    try h.waitSessionUp("ag1");

    try h.runOk(&.{ "rename", "ag1", "ag2" });

    // The sidecar moved with the session; read resolves under the new name.
    const read = try h.run(&.{ "read", "ag2", "--json" });
    defer alloc.free(read.stdout);
    defer alloc.free(read.stderr);
    try std.testing.expect(read.term.Exited == 0);
    try std.testing.expect(std.mem.indexOf(u8, read.stdout, "\"agent\":\"claude\"") != null);

    const old_sc = try std.fs.path.join(alloc, &.{ h.dir, "ag1.agent" });
    defer alloc.free(old_sc);
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().access(old_sc, .{}));

    try h.runOk(&.{ "kill", "ag2" });
}

test "kill: peek immediately after kill reports no session" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    // Once kill is acked the socket file is already unlinked, so a
    // back-to-back peek must deterministically resolve "no session"
    // (exit 3) and never observe EOF from the dying daemon. Repeat to
    // amplify the former race between the kill ack and teardown.
    var i: usize = 0;
    var name_buf: [16]u8 = undefined;
    while (i < 10) : (i += 1) {
        const name = try std.fmt.bufPrint(&name_buf, "reap{d}", .{i});
        try h.startDetached(name, &.{"sh"});
        try h.runOk(&.{ "kill", name });
        try h.runExit(&.{ "peek", name }, 3);
    }
}

test "rename: moves a session to a new name" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    try h.startDetached("before", &.{"cat"});
    try h.sendLine("before", "RN-MARK");
    const seeded = try h.waitPeekContains("before", "RN-MARK");
    alloc.free(seeded);

    // The screen and the running process survive the rename.
    try h.runOk(&.{ "rename", "before", "after" });
    const content = try h.waitPeekContains("after", "RN-MARK");
    alloc.free(content);
    try h.runExit(&.{ "peek", "before" }, 3);

    // Name collisions, invalid names, and missing sessions are
    // rejected with the documented exit codes.
    try h.startDetached("other", &.{"cat"});
    try h.runExit(&.{ "rename", "after", "other" }, 1);
    try h.runExit(&.{ "rename", "after", "sp ace" }, 2);
    try h.runExit(&.{ "rename", "nosuchzz", "x" }, 3);
    try h.runExit(&.{"rename"}, 2);
    try h.runExit(&.{ "rename", "after" }, 2);
}

// -- workspaces ---------------------------------------------------------------

/// True when `moo ls --json` (with any extra args, e.g. `-w proj`) lists a
/// session of the given name. Caller-supplied ls_args precede `--json`.
fn lsHasSession(h: *Harness, ls_args: []const []const u8, name: []const u8) !bool {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(h.alloc);
    try argv.append(h.alloc, "ls");
    try argv.appendSlice(h.alloc, ls_args);
    try argv.append(h.alloc, "--json");
    const result = try h.run(argv.items);
    defer h.alloc.free(result.stdout);
    defer h.alloc.free(result.stderr);
    if (result.term != .Exited or result.term.Exited != 0) return error.LsFailed;
    var parsed = try std.json.parseFromSlice(std.json.Value, h.alloc, result.stdout, .{});
    defer parsed.deinit();
    for (parsed.value.array.items) |entry| {
        if (std.mem.eql(u8, entry.object.get("name").?.string, name)) return true;
    }
    return false;
}

/// Start a detached session inside a workspace and wait for it to be live.
/// Mirrors Harness.startDetached but threads `-w <workspace>` through every
/// command, since the session is only visible within that workspace's dir.
fn startDetachedWs(
    h: *Harness,
    workspace: []const u8,
    session: []const u8,
    cmd: []const []const u8,
) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(h.alloc);
    try argv.appendSlice(h.alloc, &.{ "new", "-w", workspace, session, "-d", "--" });
    try argv.appendSlice(h.alloc, cmd);
    const result = try h.run(argv.items);
    defer h.alloc.free(result.stdout);
    defer h.alloc.free(result.stderr);
    if (result.term != .Exited or result.term.Exited != 0) {
        std.debug.print("new -w failed: {s}\n", .{result.stderr});
        return error.StartFailed;
    }
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, session) != null);

    var deadline = Deadline.init(default_timeout_ms);
    while (true) {
        const peek = try h.run(&.{ "peek", "-w", workspace, session });
        defer h.alloc.free(peek.stdout);
        defer h.alloc.free(peek.stderr);
        if (peek.term == .Exited and peek.term.Exited == 0) return;
        try deadline.tick("workspace session did not come up");
    }
}

test "workspace -w isolates a session into its own directory" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    // C1: a -w session is created and visible within that workspace.
    try startDetachedWs(&h, "proj", "wsone", &.{"cat"});
    try std.testing.expect(try lsHasSession(&h, &.{ "-w", "proj" }, "wsone"));

    // C2 (isolation): the default-workspace listing does not see it.
    try std.testing.expect(!try lsHasSession(&h, &.{}, "wsone"));
}

test "workspace kill --all only banishes its own sessions" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    // C4: one default-workspace session and one proj session.
    try h.startDetached("base", &.{"cat"});
    try startDetachedWs(&h, "proj", "inproj", &.{"cat"});
    try std.testing.expect(try lsHasSession(&h, &.{}, "base"));
    try std.testing.expect(try lsHasSession(&h, &.{ "-w", "proj" }, "inproj"));

    // kill --all scoped to proj removes only the proj session.
    try h.runOk(&.{ "kill", "-w", "proj", "--all" });

    var deadline = Deadline.init(default_timeout_ms);
    while (true) {
        if (!try lsHasSession(&h, &.{ "-w", "proj" }, "inproj")) break;
        try deadline.tick("proj session survived workspace kill --all");
    }
    // The default-workspace session is untouched.
    try std.testing.expect(try lsHasSession(&h, &.{}, "base"));
}

test "workspace prefix resolution is scoped to the workspace" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    // C5: a session named "worker" exists only in proj.
    try startDetachedWs(&h, "proj", "worker", &.{"cat"});

    // A unique prefix resolves within the workspace (exit 0).
    try h.runExit(&.{ "peek", "-w", "proj", "wor" }, 0);
    // The same prefix against the default workspace finds nothing (exit 3).
    try h.runExit(&.{ "peek", "wor" }, 3);
}

/// Poll a workspace-scoped session's screen until `needle` appears. Mirrors
/// Harness.waitPeekContains but threads `-w <workspace>` so the peek resolves
/// inside that workspace's directory. Returns the matching peek; caller frees.
fn waitPeekContainsWs(
    h: *Harness,
    workspace: []const u8,
    session: []const u8,
    needle: []const u8,
) ![]u8 {
    var deadline = Deadline.init(default_timeout_ms);
    var last: ?[]u8 = null;
    errdefer if (last) |l| h.alloc.free(l);
    while (true) {
        const result = try h.run(&.{ "peek", "-w", workspace, session });
        h.alloc.free(result.stderr);
        if (last) |l| h.alloc.free(l);
        last = null;
        if (result.term == .Exited and result.term.Exited == 0) {
            last = result.stdout;
            if (std.mem.indexOf(u8, result.stdout, needle) != null) return result.stdout;
        } else {
            h.alloc.free(result.stdout);
        }
        deadline.tick("workspace peek never contained needle") catch |err| {
            std.debug.print("--- last peek ---\n{s}\n---\n", .{last orelse "<none>"});
            return err;
        };
    }
}

// A session command that reports MOO_WORKSPACE at launch, then keeps the
// session alive. `exec cat` replaces the shell with a process that blocks on
// stdin forever, so the session stays up for later peeks without the printf
// scrolling away.
const ws_probe = "printf \"WS=[%s]\\n\" \"$MOO_WORKSPACE\"; exec cat";

test "workspace session inherits MOO_WORKSPACE in its env" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    // C1: the daemon exports MOO_WORKSPACE=<name> into a -w session's
    // process env, so the probe prints the workspace name.
    try startDetachedWs(&h, "proj", "envset", &.{ "sh", "-c", ws_probe });
    const content = try waitPeekContainsWs(&h, "proj", "envset", "WS=[proj]");
    defer alloc.free(content);
}

test "default session has no MOO_WORKSPACE in its env" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    // C2: a session created without -w must not inherit MOO_WORKSPACE; the
    // probe sees an empty value. This fails if an implementer wrongly exports
    // an empty (or any) MOO_WORKSPACE for default-workspace sessions.
    try h.startDetached("envunset", &.{ "sh", "-c", ws_probe });
    const content = try h.waitPeekContains("envunset", "WS=[]");
    defer alloc.free(content);
}

test "nested moo inside a workspace session is confined to that workspace" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    // C3 (end-to-end confinement): a process running inside a workspace
    // session inherits MOO_DIR + MOO_WORKSPACE, so a nested `moo ls` it runs
    // resolves to that workspace and never sees default-workspace sessions.
    try h.startDetached("base", &.{"cat"});
    try startDetachedWs(&h, "proj", "shell", &.{"sh"});
    // Confirm the proj shell is live before driving it.
    const ready = try waitPeekContainsWs(&h, "proj", "shell", "$");
    alloc.free(ready);

    // Drive the nested moo with the same absolute binary the harness spawns,
    // since a workspace session's PATH need not contain it.
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_abs = try std.fs.cwd().realpath(exe_path, &exe_buf);
    const cmd = try std.fmt.allocPrint(alloc, "{s} ls", .{exe_abs});
    defer alloc.free(cmd);
    try h.runOk(&.{ "send", "-w", "proj", "shell", "--text", cmd, "--enter" });

    // The nested listing shows the proj session and not the default one.
    // Assert on the distinctive names rather than exact layout, so terminal
    // wrapping in the captured screen does not make the check brittle.
    const listing = try waitPeekContainsWs(&h, "proj", "shell", "shell");
    defer alloc.free(listing);
    try std.testing.expect(std.mem.indexOf(u8, listing, "base") == null);
}

// -- invalid workspace names --------------------------------------------------

/// Assert a finished command rejected an invalid workspace name cleanly: the
/// usage exit code (2), the stable "invalid workspace name" phrase on stderr,
/// and none of the raw propagated error name or stack trace that an unhandled
/// error.InvalidSessionName would leak. Frees the result.
fn expectCleanWsError(h: *Harness, result: std.process.Child.RunResult) !void {
    defer h.alloc.free(result.stdout);
    defer h.alloc.free(result.stderr);
    if (result.term != .Exited or result.term.Exited != 2) {
        std.debug.print("wanted exit 2, got {any}: {s}\n", .{ result.term, result.stderr });
        return error.WrongExit;
    }
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "invalid workspace name") != null);
    // The raw error name and a Zig stack trace must not reach the user.
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "InvalidSessionName") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "paths.zig") == null);
}

test "invalid workspace name from -w is a clean usage error" {
    var h = try Harness.init(std.testing.allocator);
    defer h.deinit();

    // A traversal name, a leading-dash name (flagValue consumes "-bad" as the
    // -w value), and an empty value all fail validateName and must surface as
    // exit-2 usage errors, not a raw error.InvalidSessionName at exit 1.
    for ([_][]const u8{ "../x", "-bad", "" }) |bad| {
        try expectCleanWsError(&h, try h.run(&.{ "ls", "-w", bad }));
    }
}

test "invalid MOO_WORKSPACE env value is a clean usage error" {
    var h = try Harness.init(std.testing.allocator);
    defer h.deinit();

    // The env path (no -w flag) must be just as clean as the flag path: a bad
    // MOO_WORKSPACE in the environment yields the exit-2 usage message.
    try expectCleanWsError(&h, try h.runWithWorkspaceEnv(&.{"ls"}, "../x"));
}

test "invalid workspace name is clean across commands and creates nothing" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    // A non-ls command proves the clean error is consistent, not ls-specific.
    try expectCleanWsError(&h, try h.run(&.{ "new", "-w", "../x", "-d", "--", "cat" }));

    // The rejected traversal name must not have created a ws/ directory or
    // escaped the harness dir: validation happens before any mkdir.
    const ws_dir = try std.fs.path.join(alloc, &.{ h.dir, "ws" });
    defer alloc.free(ws_dir);
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().access(ws_dir, .{}));
}

// -- moo ws -------------------------------------------------------------------

/// Look up a workspace's session count in `moo ws --json`. The default
/// workspace is reported under the empty string, which a real workspace name
/// can never be (validateName rejects ""), so "" unambiguously denotes it.
/// Returns null when no entry names the workspace. Mirrors lsHasSession's
/// order-independent parse: entries are matched by name, not array position.
fn wsCount(h: *Harness, workspace: []const u8) !?i64 {
    const result = try h.run(&.{ "ws", "--json" });
    defer h.alloc.free(result.stdout);
    defer h.alloc.free(result.stderr);
    if (result.term != .Exited or result.term.Exited != 0) return error.WsFailed;
    var parsed = try std.json.parseFromSlice(std.json.Value, h.alloc, result.stdout, .{});
    defer parsed.deinit();
    for (parsed.value.array.items) |entry| {
        if (std.mem.eql(u8, entry.object.get("workspace").?.string, workspace)) {
            return entry.object.get("sessions").?.integer;
        }
    }
    return null;
}

test "ws --json reports the default and every workspace with a session count" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    // C1: sessions spread across the default workspace and two named ones.
    // cat stays alive so each session is counted as a live socket.
    try h.startDetached("base", &.{"cat"});
    try startDetachedWs(&h, "alpha", "a1", &.{"cat"});
    try startDetachedWs(&h, "alpha", "a2", &.{"cat"});
    try startDetachedWs(&h, "beta", "b1", &.{"cat"});

    try std.testing.expectEqual(@as(?i64, 1), try wsCount(&h, ""));
    try std.testing.expectEqual(@as(?i64, 2), try wsCount(&h, "alpha"));
    try std.testing.expectEqual(@as(?i64, 1), try wsCount(&h, "beta"));
}

test "ws human output lists workspace names and counts" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    // C2: the plain (non-JSON) listing exits 0 and surfaces the workspace
    // names alongside their counts. The exact table layout is left loose so
    // the assertion does not over-fit formatting the implementer chooses.
    try startDetachedWs(&h, "alpha", "a1", &.{"cat"});
    try startDetachedWs(&h, "alpha", "a2", &.{"cat"});

    const result = try h.run(&.{"ws"});
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    try std.testing.expect(result.term == .Exited and result.term.Exited == 0);
    try std.testing.expect(result.stdout.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "alpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "2") != null);
}

test "ws --json with no workspaces returns just the default entry" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    // C3: a fresh harness has no ws/ directory at all. ws must still exit 0
    // and report the default workspace (here with one live session) without
    // erroring on the absent ws/ subdir.
    try h.startDetached("only", &.{"cat"});

    const result = try h.run(&.{ "ws", "--json" });
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    try std.testing.expect(result.term == .Exited and result.term.Exited == 0);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, result.stdout, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.array.items.len);
    const entry = parsed.value.array.items[0].object;
    try std.testing.expectEqualStrings("", entry.get("workspace").?.string);
    try std.testing.expectEqual(@as(i64, 1), entry.get("sessions").?.integer);
}

// -- moo ui -------------------------------------------------------------------

fn runLsJson(
    h: *Harness,
    ls_args: []const []const u8,
) !std.process.Child.RunResult {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(h.alloc);
    try argv.append(h.alloc, "ls");
    try argv.appendSlice(h.alloc, ls_args);
    try argv.append(h.alloc, "--json");
    return h.run(argv.items);
}

fn lsSessionCount(h: *Harness, ls_args: []const []const u8) !usize {
    const result = try runLsJson(h, ls_args);
    defer h.alloc.free(result.stdout);
    defer h.alloc.free(result.stderr);
    if (result.term != .Exited or result.term.Exited != 0) return error.LsFailed;
    var parsed = try std.json.parseFromSlice(std.json.Value, h.alloc, result.stdout, .{});
    defer parsed.deinit();
    return parsed.value.array.items.len;
}

fn uiSessionCount(h: *Harness) !usize {
    return lsSessionCount(h, &.{});
}

const ScopedUiCounts = struct {
    target: usize,
    default: usize,
    unrelated: usize,
};

fn scopedUiCounts(
    h: *Harness,
    target_workspace: []const u8,
    unrelated_workspace: []const u8,
) !ScopedUiCounts {
    return .{
        .target = try lsSessionCount(h, &.{ "-w", target_workspace }),
        .default = try lsSessionCount(h, &.{}),
        .unrelated = try lsSessionCount(h, &.{ "-w", unrelated_workspace }),
    };
}

fn waitScopedUiCreateCountChange(
    h: *Harness,
    target_workspace: []const u8,
    unrelated_workspace: []const u8,
    before: ScopedUiCounts,
) !ScopedUiCounts {
    var deadline = Deadline.init(default_timeout_ms);
    while (true) {
        const after = try scopedUiCounts(h, target_workspace, unrelated_workspace);
        if (after.target != before.target or
            after.default != before.default or
            after.unrelated != before.unrelated)
        {
            return after;
        }
        try deadline.tick("scoped ui create did not change any workspace count");
    }
}

fn onlyLsSessionName(h: *Harness, ls_args: []const []const u8) ![]u8 {
    const result = try runLsJson(h, ls_args);
    defer h.alloc.free(result.stdout);
    defer h.alloc.free(result.stderr);
    if (result.term != .Exited or result.term.Exited != 0) return error.LsFailed;
    var parsed = try std.json.parseFromSlice(std.json.Value, h.alloc, result.stdout, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.array.items.len);
    return h.alloc.dupe(u8, parsed.value.array.items[0].object.get("name").?.string);
}

fn expectScopedUiCreateInWorkspace(
    h: *Harness,
    ui: *PtyClient,
    target_workspace: []const u8,
    unrelated_workspace: []const u8,
) !void {
    const before = try scopedUiCounts(h, target_workspace, unrelated_workspace);
    try std.testing.expectEqual(@as(usize, 0), before.target);
    try std.testing.expectEqual(@as(usize, 1), before.default);
    try std.testing.expectEqual(@as(usize, 1), before.unrelated);

    ui.clearOutput();
    try ui.send("\x01c");
    const after = try waitScopedUiCreateCountChange(
        h,
        target_workspace,
        unrelated_workspace,
        before,
    );
    try std.testing.expectEqual(before.target + 1, after.target);
    try std.testing.expectEqual(before.default, after.default);
    try std.testing.expectEqual(before.unrelated, after.unrelated);

    const created = try onlyLsSessionName(h, &.{ "-w", target_workspace });
    defer h.alloc.free(created);
    try ui.waitFor(created);
}

fn waitUiSessionCount(h: *Harness, want: usize) !void {
    var deadline = Deadline.init(default_timeout_ms);
    while (true) {
        if (try uiSessionCount(h) == want) return;
        try deadline.tick("session count never settled");
    }
}

/// Render raw client output through a terminal emulator and return
/// the resulting screen text, one line per row. Raw byte matching
/// cannot tell whether content survives on screen (a later erase can
/// remove it); this can.
fn renderScreen(
    alloc: std.mem.Allocator,
    bytes: []const u8,
    rows: u16,
    cols: u16,
) ![]const u8 {
    var term = try vt.Terminal.init(alloc, .{ .cols = cols, .rows = rows });
    defer term.deinit(alloc);
    var stream = term.vtStream();
    defer stream.deinit();
    stream.nextSlice(bytes);
    return term.screens.active.dumpStringAlloc(alloc, .{ .screen = .{} });
}

test "ui: sidebar lists sessions and the focused session renders in the viewport" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    try h.startDetached("aa", &.{"cat"});
    try h.startDetached("bb", &.{"cat"});
    try h.sendLine("bb", "BB-VIEW-MARK");
    const seeded = try h.waitPeekContains("bb", "BB-VIEW-MARK");
    alloc.free(seeded);

    // bb saw input last, so it is the most recent session and the UI
    // focuses it on startup.
    var ui = try PtyClient.spawn(&h, &.{"ui"}, 24, 100);
    defer ui.deinit();
    try ui.waitFor("aa");
    try ui.waitFor("bb");
    try ui.waitFor("BB-VIEW-MARK");

    // The UI renders on the alternate screen, like attach.
    try std.testing.expect(std.mem.indexOf(u8, ui.output.items, "\x1b[?1049h") != null);

    // C-a p focuses the previous (other) session; typing lands there.
    ui.clearOutput();
    try ui.send("\x01p");
    try ui.send("AA-TYPED-MARK\r");
    try ui.waitFor("AA-TYPED-MARK");
    const peeked = try h.waitPeekContains("aa", "AA-TYPED-MARK");
    defer alloc.free(peeked);
}

test "ui: dragging in the viewport selects text and copies it via osc 52" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    try h.startDetached("cp", &.{"cat"});

    var ui = try PtyClient.spawn(&h, &.{"ui"}, 24, 100);
    defer ui.deinit();
    try ui.waitFor("cp");

    // The echoed line lands on the session's first row, rendered at
    // screen row 1 starting at column 26 (24-column sidebar plus the
    // separator).
    try h.sendLine("cp", "COPYTEXT");
    try ui.waitFor("COPYTEXT");

    // Press on the C, drag right, release on the final T. cat never
    // asked for mouse reporting, so the UI selects instead of
    // forwarding, then copies as OSC 52 with base64("COPYTEXT").
    ui.clearOutput();
    try ui.send("\x1b[<0;26;1M");
    try ui.send("\x1b[<32;30;1M");
    try ui.send("\x1b[<32;33;1M");
    try ui.send("\x1b[<0;33;1m");
    try ui.waitFor("\x1b]52;c;Q09QWVRFWFQ=");
    try ui.waitFor("copied");
}

test "ui: mouse events forward natively when the application asks for them" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    // The session enables button tracking + SGR before the UI
    // attaches, so the attach replay must carry the modes to the
    // view terminal. cat -v makes the forwarded bytes visible.
    try h.startDetached("fwd", &.{
        "sh",                                                                                "-c",
        "stty -echo -icanon; printf '\\033[?1002h\\033[?1006h'; echo RAWREADY; exec cat -v",
    });
    const seeded = try h.waitPeekContains("fwd", "RAWREADY");
    alloc.free(seeded);

    var ui = try PtyClient.spawn(&h, &.{"ui"}, 24, 100);
    defer ui.deinit();
    try ui.waitFor("RAWREADY");

    // A click at screen (30, 3) is viewport cell (4, 2); the app gets
    // SGR press + release with viewport-relative coordinates instead
    // of a UI selection.
    try ui.send("\x1b[<0;30;3M\x1b[<0;30;3m");
    try ui.waitFor("^[[<0;5;3M^[[<0;5;3m");
}

test "ui: a row touching the viewport's right edge keeps its last cell" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    try h.startDetached("edge", &.{"sh"});

    var ui = try PtyClient.spawn(&h, &.{"ui"}, 24, 100);
    defer ui.deinit();
    try ui.waitFor("edge");

    // Paint a marker whose final cell sits in the session's last
    // column (75 wide inside a 100-column UI), which lands in the
    // last column of the whole terminal. The marker is assembled
    // from a variable so the echoed command line cannot match.
    try h.sendLine("edge", "T=EDGE; printf \"\\\\033[3;71H${T}Z\"");
    try ui.waitFor("EDGEZ");
    // The bottom row repaints with the keybind bar after arming the
    // prefix, so once it shows, the marker row's frame is fully
    // captured.
    try ui.send("\x01");
    try ui.waitFor("r rename");
    try ui.send("\x1b");

    // Erase-to-EOL emitted after a full-width row would eat the last
    // cell (the cursor rests on it in the pending-wrap state), so the
    // marker must survive on the rendered screen, not just in the
    // byte stream.
    const screen = try renderScreen(alloc, ui.output.items, 24, 100);
    defer alloc.free(screen);
    try std.testing.expect(std.mem.indexOf(u8, screen, "EDGEZ") != null);

    // The session list starts on the first sidebar row.
    var lines = std.mem.splitScalar(u8, screen, '\n');
    const first = lines.next().?;
    try std.testing.expect(std.mem.indexOf(u8, first, "edge") != null);
}

test "ui: scrolling output keeps the viewport in sync with the session" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    try h.startDetached("scroll", &.{"sh"});

    var ui = try PtyClient.spawn(&h, &.{"ui"}, 24, 100);
    defer ui.deinit();
    try ui.waitFor("scroll");

    // Print far more lines than the viewport is tall so the active
    // screen scrolls many times. Each scroll moves every visible row
    // onto a different libghostty row, so the viewport cache must key
    // on row identity and not reuse a stale serialization. Wait on
    // "LINE-200" (which the echoed command does not contain literally)
    // so the wait cannot race the command echo.
    try h.sendLine("scroll", "i=1; while [ $i -le 200 ]; do echo LINE-$i; i=$((i+1)); done");
    try ui.waitFor("LINE-200");

    const screen = try renderScreen(alloc, ui.output.items, 24, 100);
    defer alloc.free(screen);

    // Every LINE-N still on screen must appear in strictly increasing
    // order, and the newest line must have rendered. A stale reused row
    // would put an older number out of sequence or duplicate one.
    var prev: i64 = -1;
    var idx: usize = 0;
    while (std.mem.indexOfPos(u8, screen, idx, "LINE-")) |pos| {
        var end = pos + "LINE-".len;
        while (end < screen.len and std.ascii.isDigit(screen[end])) end += 1;
        idx = pos + "LINE-".len;
        if (end == idx) continue; // "LINE-$i" from the echoed command
        const n = std.fmt.parseInt(i64, screen[idx..end], 10) catch continue;
        try std.testing.expect(n > prev);
        prev = n;
    }
    try std.testing.expectEqual(@as(i64, 200), prev);
}

test "ui: the empty state shows moo, the cow, and the keybind hint" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    var ui = try PtyClient.spawn(&h, &.{"ui"}, 24, 100);
    defer ui.deinit();
    try ui.waitFor("^__^");
    try ui.waitFor("no sessions");
    try ui.waitFor("Press Ctrl+A for Keybinds");
}

test "ui: 'i' is the documented shorthand" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    var ui = try PtyClient.spawn(&h, &.{"i"}, 24, 100);
    defer ui.deinit();
    try ui.waitFor("no sessions");
    try ui.waitFor("Press Ctrl+A for Keybinds");
}

test "ui: clicking a session in the sidebar focuses it" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    try h.startDetached("one", &.{"cat"});
    try h.startDetached("two", &.{"cat"});
    try h.sendLine("one", "ONE-MARK");
    try h.sendLine("two", "TWO-MARK");
    const seeded = try h.waitPeekContains("two", "TWO-MARK");
    alloc.free(seeded);

    var ui = try PtyClient.spawn(&h, &.{"ui"}, 24, 100);
    defer ui.deinit();
    try ui.waitFor("TWO-MARK"); // most recent session focused

    // Sessions are sorted by name: "one" on sidebar row 1 (1-based,
    // top of the list). An SGR press + release on that row switches
    // the viewport.
    ui.clearOutput();
    try ui.send("\x1b[<0;5;1M\x1b[<0;5;1m");
    try ui.waitFor("ONE-MARK");
}

test "ui: create and kill sessions from the ui" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    try h.startDetached("keep1", &.{"cat"});
    try h.startDetached("keep2", &.{"cat"});

    var ui = try PtyClient.spawn(&h, &.{"ui"}, 24, 100);
    defer ui.deinit();
    try ui.waitFor("keep2");

    // C-a c creates a session (named after the cwd or the creating
    // pid) and focuses it.
    try ui.send("\x01c");
    try waitUiSessionCount(&h, 3);

    // C-a k asks for confirmation, then kills the focused (new)
    // session.
    try ui.send("\x01k");
    try ui.waitFor("? y/n");
    try ui.send("y");
    try waitUiSessionCount(&h, 2);

    // The pre-existing sessions survived.
    const ls = try h.run(&.{"ls"});
    defer alloc.free(ls.stdout);
    defer alloc.free(ls.stderr);
    try std.testing.expect(std.mem.indexOf(u8, ls.stdout, "keep1") != null);
    try std.testing.expect(std.mem.indexOf(u8, ls.stdout, "keep2") != null);
}

test "ui: create from -w workspace stays in that workspace" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    try h.startDetached("base", &.{"cat"});
    try startDetachedWs(&h, "other", "elsewhere", &.{"cat"});

    var ui = try PtyClient.spawn(&h, &.{ "ui", "-w", "proj" }, 24, 100);
    defer ui.deinit();
    try ui.waitFor("no sessions");

    try expectScopedUiCreateInWorkspace(&h, &ui, "proj", "other");
}

test "ui: create from MOO_WORKSPACE stays in that workspace" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    try h.startDetached("base", &.{"cat"});
    try startDetachedWs(&h, "other", "elsewhere", &.{"cat"});

    const env = [_][2][]const u8{.{ "MOO_WORKSPACE", "proj" }};
    var ui = try PtyClient.spawnWithEnv(&h, &.{"ui"}, 24, 100, &env);
    defer ui.deinit();
    try ui.waitFor("no sessions");

    try expectScopedUiCreateInWorkspace(&h, &ui, "proj", "other");
}

test "ui: clicking the kill target asks for confirmation" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    try h.startDetached("victim", &.{"cat"});

    var ui = try PtyClient.spawn(&h, &.{"ui"}, 24, 100);
    defer ui.deinit();
    try ui.waitFor("victim");

    // The kill target is the 'x' in the second-to-last sidebar
    // column (sidebar width 24 -> 1-based column 23), row 1.
    try ui.send("\x1b[<0;23;1M\x1b[<0;23;1m");
    try ui.waitFor("kill victim? y/n");
    try ui.send("y");
    try waitUiSessionCount(&h, 0);
}

test "ui: killing the focused session moves focus to the next one" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    try h.startDetached("doomed", &.{"cat"});
    try h.startDetached("stay", &.{"cat"});
    try h.sendLine("stay", "STAY-MARK");

    var ui = try PtyClient.spawn(&h, &.{"ui"}, 24, 100);
    defer ui.deinit();
    try ui.waitFor("stay");

    // Focus "doomed" (first alphabetically, sidebar row 1) so its
    // death has somewhere to fall back to.
    try ui.send("\x1b[<0;5;1M\x1b[<0;5;1m");
    try h.sendLine("doomed", "DOOM-MARK");
    try ui.waitFor("DOOM-MARK");

    // Killing the focused session attaches the remaining free one:
    // its screen contents render without any further input.
    try ui.send("\x01k");
    try ui.waitFor("kill doomed? y/n");
    try ui.send("y");
    try ui.waitFor("STAY-MARK");
    try std.testing.expect(std.mem.indexOf(u8, ui.output.items, "no session focused") == null);
}

test "ui: killing the last free session points at a held one" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    try h.startDetached("held", &.{"cat"});
    var holder = try PtyClient.spawn(&h, &.{ "attach", "held" }, 24, 80);
    defer holder.deinit();
    try h.sendLine("held", "HELD-MARK");
    try holder.waitFor("HELD-MARK");

    try h.startDetached("doomed", &.{"cat"});

    // The UI auto-focuses "doomed", the only free session.
    var ui = try PtyClient.spawn(&h, &.{"ui"}, 24, 100);
    defer ui.deinit();
    try h.sendLine("doomed", "DOOM-MARK");
    try ui.waitFor("DOOM-MARK");

    // After the kill nothing is free to attach: the held session is
    // selected without stealing it, with the viewport explaining how
    // to take it over.
    try ui.send("\x01k");
    try ui.waitFor("kill doomed? y/n");
    try ui.send("y");
    try ui.waitFor("attached elsewhere");
    try ui.waitFor("click the session to take it over");
    try std.testing.expect(std.mem.indexOf(u8, ui.output.items, "no session focused") == null);
}

test "ui: killing the only session brings back the splash" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    try h.startDetached("solo", &.{"cat"});

    var ui = try PtyClient.spawn(&h, &.{"ui"}, 24, 100);
    defer ui.deinit();
    try h.sendLine("solo", "SOLO-MARK");
    try ui.waitFor("SOLO-MARK");

    try ui.send("\x01k");
    try ui.waitFor("kill solo? y/n");
    try ui.send("y");
    try ui.waitFor("^__^");
    try ui.waitFor("no sessions");
    try std.testing.expect(std.mem.indexOf(u8, ui.output.items, "no session focused") == null);
}

test "ui: quit with C-a d leaves sessions running and restores the terminal" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    try h.startDetached("survivor", &.{"cat"});

    var ui = try PtyClient.spawn(&h, &.{"ui"}, 24, 100);
    defer ui.deinit();
    try ui.waitFor("survivor");

    try ui.send("\x01d");
    try ui.waitFor("[moo ui closed]");
    try std.testing.expectEqual(@as(u32, 0), try ui.waitExit());

    // The alternate screen is left before the exit notice prints.
    const leave = std.mem.lastIndexOf(u8, ui.output.items, "\x1b[?1049l").?;
    const notice = std.mem.indexOf(u8, ui.output.items, "[moo ui closed]").?;
    try std.testing.expect(leave < notice);

    const ls = try h.run(&.{"ls"});
    defer alloc.free(ls.stdout);
    defer alloc.free(ls.stderr);
    try std.testing.expect(std.mem.indexOf(u8, ls.stdout, "survivor") != null);
    try std.testing.expect(std.mem.indexOf(u8, ls.stdout, "detached") != null);
}

test "ui: viewport size tracks the terminal minus the sidebar" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    try h.startDetached("rz", &.{"/bin/sh"});

    // 100 columns - 24 sidebar - 1 separator = 75 viewport columns;
    // the viewport spans all 24 rows, since status content only
    // overlays the bottom row while it has something to show.
    var ui = try PtyClient.spawn(&h, &.{"ui"}, 24, 100);
    defer ui.deinit();
    try ui.waitFor("rz");

    const size_file = try std.fmt.allocPrint(alloc, "{s}/ui-size.txt", .{h.dir});
    defer alloc.free(size_file);
    const cmd = try std.fmt.allocPrint(alloc, "stty size > {s}", .{size_file});
    defer alloc.free(cmd);

    try h.sendLine("rz", cmd);
    try waitFileEquals(alloc, size_file, "24 75\n");

    // Resizing the outer terminal resizes the viewport with it.
    try ui.setSize(30, 120);
    var deadline = Deadline.init(default_timeout_ms);
    while (true) {
        try h.sendLine("rz", cmd);
        std.Thread.sleep(50 * std.time.ns_per_ms);
        const content = std.fs.cwd().readFileAlloc(alloc, size_file, 4096) catch "";
        defer if (content.len > 0) alloc.free(content);
        if (std.mem.eql(u8, content, "30 95\n")) break;
        try deadline.tick("viewport resize never reached the session");
    }
}

test "ui: a plain attach steals the focused session" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    try h.startDetached("st", &.{"cat"});

    var ui = try PtyClient.spawn(&h, &.{"ui"}, 24, 100);
    defer ui.deinit();
    try ui.waitFor("st");

    var thief = try PtyClient.spawn(&h, &.{ "attach", "st" }, 24, 80);
    defer thief.deinit();
    try ui.waitFor("attached elsewhere");

    // Clicking the session in the sidebar steals it back.
    try ui.send("\x1b[<0;5;1M\x1b[<0;5;1m");
    try thief.waitFor("attached elsewhere");
    _ = try thief.waitExit();
}

test "ui: startup leaves a session attached elsewhere alone until it frees up" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    try h.startDetached("ns", &.{"cat"});

    var holder = try PtyClient.spawn(&h, &.{ "attach", "ns" }, 24, 80);
    defer holder.deinit();
    try h.sendLine("ns", "HELD-MARK");
    try holder.waitFor("HELD-MARK");

    // The UI starts while another client holds the session: it points
    // at the session without stealing it.
    var ui = try PtyClient.spawn(&h, &.{"ui"}, 24, 100);
    defer ui.deinit();
    try ui.waitFor("attached elsewhere");
    try ui.waitFor("click the session to take it over");
    try std.testing.expect(std.mem.indexOf(u8, holder.output.items, "attached elsewhere") == null);

    // Once the holder detaches, the UI binds the session by itself.
    try holder.send("\x01d");
    try holder.waitFor("[detached from ns]");
    _ = try holder.waitExit();
    try h.sendLine("ns", "FREED-MARK");
    try ui.waitFor("FREED-MARK");
}

test "ui: a stolen view reclaims the session once the thief lets go" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    try h.startDetached("rc", &.{"cat"});

    var ui = try PtyClient.spawn(&h, &.{"ui"}, 24, 100);
    defer ui.deinit();
    try h.sendLine("rc", "FIRST-MARK");
    try ui.waitFor("FIRST-MARK");

    var thief = try PtyClient.spawn(&h, &.{ "attach", "rc" }, 24, 80);
    defer thief.deinit();
    try ui.waitFor("attached elsewhere");

    // The thief detaches; the UI re-attaches on its own.
    try thief.send("\x01d");
    try thief.waitFor("[detached from rc]");
    _ = try thief.waitExit();
    try h.sendLine("rc", "BACK-MARK");
    try ui.waitFor("BACK-MARK");
}

/// Pump the client until the rendered screen's last row contains
/// every needle (or, for `absent`, none of them).
fn waitLastRow(
    alloc: std.mem.Allocator,
    ui: *PtyClient,
    rows: u16,
    cols: u16,
    present: []const []const u8,
    absent: []const []const u8,
) !void {
    var deadline = Deadline.init(default_timeout_ms);
    while (true) {
        const screen = try renderScreen(alloc, ui.output.items, rows, cols);
        defer alloc.free(screen);
        var lines = std.mem.splitScalar(u8, screen, '\n');
        var last: []const u8 = "";
        while (lines.next()) |line| last = line;

        var ok = true;
        for (present) |needle| {
            if (std.mem.indexOf(u8, last, needle) == null) ok = false;
        }
        for (absent) |needle| {
            if (std.mem.indexOf(u8, last, needle) != null) ok = false;
        }
        if (ok) return;

        _ = try ui.pump(100);
        deadline.tick("waiting for the bottom row") catch |err| {
            std.debug.print("--- bottom row --- {s}\n", .{last});
            return err;
        };
    }
}

/// Pump output until the rendered screen contains every `present`
/// needle and none of the `absent` ones.
fn waitScreen(
    alloc: std.mem.Allocator,
    ui: *PtyClient,
    rows: u16,
    cols: u16,
    present: []const []const u8,
    absent: []const []const u8,
) !void {
    var deadline = Deadline.init(default_timeout_ms);
    while (true) {
        const screen = try renderScreen(alloc, ui.output.items, rows, cols);
        defer alloc.free(screen);

        var ok = true;
        for (present) |needle| {
            if (std.mem.indexOf(u8, screen, needle) == null) ok = false;
        }
        for (absent) |needle| {
            if (std.mem.indexOf(u8, screen, needle) != null) ok = false;
        }
        if (ok) return;

        _ = try ui.pump(100);
        deadline.tick("waiting for the screen") catch |err| {
            std.debug.print("--- screen ---\n{s}\n", .{screen});
            return err;
        };
    }
}

test "ui: the focused session exiting hands focus to the next one" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    try h.startDetached("fallback", &.{"cat"});
    try h.startDetached("doomed", &.{"/bin/sh"});
    try h.sendLine("doomed", "DOOMED-MARK");
    const seeded = try h.waitPeekContains("doomed", "DOOMED-MARK");
    alloc.free(seeded);

    // doomed saw input last, so the UI focuses it on startup.
    var ui = try PtyClient.spawn(&h, &.{"ui"}, 24, 100);
    defer ui.deinit();
    try ui.waitFor("DOOMED-MARK");

    // The focused session's command exits: the daemon reports the
    // exit, the session leaves the listing, and the refresh that
    // follows attaches the surviving session. The refresh used to
    // run inside the view's message loop and freed the view out
    // from under it.
    try h.sendLine("doomed", "exit");
    try ui.waitFor("session ended");
    try waitUiSessionCount(&h, 1);

    // The UI is still alive and renders the surviving session.
    try h.sendLine("fallback", "FALLBACK-MARK");
    try ui.waitFor("FALLBACK-MARK");

    // And it still shuts down cleanly.
    try ui.send("\x01d");
    try ui.waitFor("[moo ui closed]");
    try std.testing.expectEqual(@as(u32, 0), try ui.waitExit());
}

test "ui: the keybind bar overlays the bottom row and C-a r renames" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    try h.startDetached("oldname", &.{"cat"});

    var ui = try PtyClient.spawn(&h, &.{"ui"}, 24, 140);
    defer ui.deinit();
    try ui.waitFor("oldname");

    // The keybind hint sits in the sidebar's bottom row and the
    // separator runs through the last row: no reserved status bar.
    try waitLastRow(alloc, &ui, 24, 140, &.{ "Keybinds: Ctrl+A", "\u{2502}" }, &.{});

    // Arming the prefix overlays the keybind list across the whole
    // bottom row, covering the sidebar hint and the separator.
    try ui.send("\x01");
    try ui.waitFor("r rename");
    try ui.waitFor("up/dn browse");
    try ui.waitFor("lt/rt resize");
    try ui.waitFor("esc cancel");
    try waitLastRow(alloc, &ui, 24, 140, &.{"r rename"}, &.{"\u{2502}"});

    // Esc backs out: the overlay reverts to the hint, the separator,
    // and whatever the viewport had underneath.
    try ui.send("\x1b");
    try waitLastRow(alloc, &ui, 24, 140, &.{ "Keybinds: Ctrl+A", "\u{2502}" }, &.{"r rename"});

    // C-a r opens the prompt pre-filled with the old name; erase it
    // and type a new one.
    try ui.send("\x01r");
    try ui.waitFor("rename oldname:");
    try ui.send("\x7f\x7f\x7f\x7f\x7f\x7f\x7f");
    try ui.send("fresh\r");
    try ui.waitFor("renamed oldname to fresh");

    // The daemon moved with the name: the old one is gone and the
    // sidebar lists the new one.
    const ls = try h.run(&.{"ls"});
    defer alloc.free(ls.stdout);
    defer alloc.free(ls.stderr);
    try std.testing.expect(std.mem.indexOf(u8, ls.stdout, "fresh") != null);
    try std.testing.expect(std.mem.indexOf(u8, ls.stdout, "oldname") == null);
}

test "ui: a single esc cancels the rename prompt" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    try h.startDetached("esc1", &.{"cat"});

    var ui = try PtyClient.spawn(&h, &.{"ui"}, 24, 100);
    defer ui.deinit();
    try ui.waitFor("esc1");

    try ui.send("\x01r");
    try ui.waitFor("rename esc1:");

    // A lone ESC with no follow-up bytes must cancel by itself: the
    // input parser flushes a held ESC after a short deadline instead
    // of waiting for the next keypress.
    try ui.send("\x1b");
    try ui.waitFor("rename cancelled");
}

test "ui: kitty keyboard state mirrors to the client terminal" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    // The app enables kitty disambiguation, pops it after one byte of
    // input, and echoes everything else visibly via cat -v.
    try h.startDetached("kty", &.{
        "sh", "-c",
        "stty -echo -icanon; printf '\\033[>1u'; echo KITTY-ON; " ++
            "head -c 1 >/dev/null; printf '\\033[<u'; echo KITTY-OFF; exec cat -v",
    });
    const seeded = try h.waitPeekContains("kty", "KITTY-ON");
    alloc.free(seeded);

    // The UI mirrors the focused view's kitty flags onto the real
    // terminal, the way a plain attach's repaint does.
    var ui = try PtyClient.spawn(&h, &.{"ui"}, 24, 100);
    defer ui.deinit();
    try ui.waitFor("KITTY-ON");
    try ui.waitFor("\x1b[=1;1u");

    // The app popping its flags un-mirrors the terminal. The startup
    // sequence also carries an =0 reset, so only output after the
    // mirror counts.
    ui.clearOutput();
    try ui.send("x");
    try ui.waitFor("KITTY-OFF");
    try ui.waitFor("\x1b[=0;1u");
}

test "ui: kitty-encoded keys reach the application verbatim" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    try h.startDetached("ktf", &.{
        "sh", "-c",
        "stty -echo -icanon; printf '\\033[>1u'; " ++
            "echo KITTY-ON; exec cat -v",
    });
    const seeded = try h.waitPeekContains("ktf", "KITTY-ON");
    alloc.free(seeded);

    var ui = try PtyClient.spawn(&h, &.{"ui"}, 24, 100);
    defer ui.deinit();
    try ui.waitFor("\x1b[=1;1u");

    // Shift+Enter, as a kitty-mode terminal encodes it, is the
    // application's input and must arrive untouched (the original
    // failure mode downgraded it to a plain Enter).
    try ui.send("\x1b[13;2u");
    const enter = try h.waitPeekContains("ktf", "^[[13;2u");
    alloc.free(enter);

    // The Esc key, kitty-encoded, arrives immediately; nothing eats
    // it waiting for a second press.
    try ui.send("\x1b[27u");
    const esc = try h.waitPeekContains("ktf", "^[[27u");
    alloc.free(esc);
}

test "ui: kitty-encoded C-a is the prefix, not session input" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    try h.startDetached("ktp", &.{
        "sh", "-c",
        "stty -echo -icanon; printf '\\033[>1u'; " ++
            "echo KITTY-ON; exec cat -v",
    });
    const seeded = try h.waitPeekContains("ktp", "KITTY-ON");
    alloc.free(seeded);

    var ui = try PtyClient.spawn(&h, &.{"ui"}, 24, 100);
    defer ui.deinit();
    try ui.waitFor("\x1b[=1;1u");

    // C-a d the way a kitty-mode terminal sends it quits the UI.
    try ui.send("\x1b[97;5u");
    try ui.send("d");
    try ui.waitFor("[moo ui closed]");
    try std.testing.expectEqual(@as(u32, 0), try ui.waitExit());

    // The keys were intercepted, not leaked into the session.
    const peek = try h.run(&.{ "peek", "ktp" });
    defer alloc.free(peek.stdout);
    defer alloc.free(peek.stderr);
    try std.testing.expect(peek.term.Exited == 0);
    try std.testing.expect(std.mem.indexOf(u8, peek.stdout, "97;5u") == null);
}

test "ui: prompts suspend the mirrored kitty flags" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    try h.startDetached("ktg", &.{
        "sh", "-c",
        "stty -echo -icanon; printf '\\033[>1u'; " ++
            "echo KITTY-ON; exec cat -v",
    });
    const seeded = try h.waitPeekContains("ktg", "KITTY-ON");
    alloc.free(seeded);

    var ui = try PtyClient.spawn(&h, &.{"ui"}, 24, 100);
    defer ui.deinit();
    try ui.waitFor("\x1b[=1;1u");

    // Opening the goto prompt drops the mirrored flags, so prompt
    // input keeps its legacy byte encodings.
    ui.clearOutput();
    try ui.send("\x1b[97;5u");
    try ui.send("g");
    try ui.waitFor(" goto: ");
    try ui.waitFor("\x1b[=0;1u");

    // A lone ESC cancels the prompt and the mirror returns.
    try ui.send("\x1b");
    try ui.waitFor("goto cancelled");
    try ui.waitFor("\x1b[=1;1u");
}

test "ui: modifyOtherKeys state mirrors to the client terminal" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    // The app sets modifyOtherKeys mode 2 (vim-style), drops it after
    // one byte of input, and echoes everything else via cat -v.
    try h.startDetached("mdm", &.{
        "sh", "-c",
        "stty -echo -icanon; printf '\\033[>4;2m'; echo MODIFY-ON; " ++
            "head -c 1 >/dev/null; printf '\\033[>4;0m'; echo MODIFY-OFF; exec cat -v",
    });
    const seeded = try h.waitPeekContains("mdm", "MODIFY-ON");
    alloc.free(seeded);

    var ui = try PtyClient.spawn(&h, &.{"ui"}, 24, 100);
    defer ui.deinit();
    try ui.waitFor("MODIFY-ON");
    try ui.waitFor("\x1b[>4;2m");

    // A prompt suspends the mirror like it does kitty flags; the
    // modify-encoded prefix opens it, proving the decode works while
    // mirrored. Cancelling restores the mode.
    ui.clearOutput();
    try ui.send("\x1b[27;5;97~");
    try ui.send("g");
    try ui.waitFor(" goto: ");
    try ui.waitFor("\x1b[>4;0m");
    try ui.send("\x1b");
    try ui.waitFor("goto cancelled");
    try ui.waitFor("\x1b[>4;2m");

    // The app dropping the mode un-mirrors the terminal.
    ui.clearOutput();
    try ui.send("x");
    try ui.waitFor("MODIFY-OFF");
    try ui.waitFor("\x1b[>4;0m");
}

test "ui: modify-encoded C-a is the prefix, not session input" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    try h.startDetached("mdp", &.{
        "sh", "-c",
        "stty -echo -icanon; printf '\\033[>4;2m'; " ++
            "echo MODIFY-ON; exec cat -v",
    });
    const seeded = try h.waitPeekContains("mdp", "MODIFY-ON");
    alloc.free(seeded);

    var ui = try PtyClient.spawn(&h, &.{"ui"}, 24, 100);
    defer ui.deinit();
    try ui.waitFor("\x1b[>4;2m");

    // C-a d the way an xterm-faithful modifyOtherKeys terminal sends
    // it quits the UI.
    try ui.send("\x1b[27;5;97~");
    try ui.send("d");
    try ui.waitFor("[moo ui closed]");
    try std.testing.expectEqual(@as(u32, 0), try ui.waitExit());

    // The keys were intercepted, not leaked into the session.
    const peek = try h.run(&.{ "peek", "mdp" });
    defer alloc.free(peek.stdout);
    defer alloc.free(peek.stderr);
    try std.testing.expect(peek.term.Exited == 0);
    try std.testing.expect(std.mem.indexOf(u8, peek.stdout, "27;5;97") == null);
}

test "ui: C-a g goes to a session by name" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    try h.startDetached("alpha", &.{"cat"});
    try h.startDetached("bravo", &.{"cat"});
    try h.sendLine("bravo", "BRAVO-MARK");
    const seeded = try h.waitPeekContains("bravo", "BRAVO-MARK");
    alloc.free(seeded);

    // bravo saw input last, so the UI focuses it on startup.
    var ui = try PtyClient.spawn(&h, &.{"ui"}, 24, 100);
    defer ui.deinit();
    try ui.waitFor("BRAVO-MARK");

    // C-a g opens the goto prompt; a name prefix selects the
    // matching session and Enter focuses it. Each step waits for
    // its echo: bytes that arrive in the same read as the
    // committing Enter would be consumed by the prompt.
    try ui.send("\x01g");
    try ui.waitFor(" goto: ");
    try ui.send("al");
    try ui.waitFor("goto: al");

    // The commit closes the prompt and the focus switch forces a
    // full repaint: the sidebar hint returning proves both.
    ui.clearOutput();
    try ui.send("\r");
    try ui.waitFor("Keybinds: Ctrl+A");

    // Typing lands in alpha now.
    try ui.send("ALPHA-TYPED-MARK\r");
    try ui.waitFor("ALPHA-TYPED-MARK");
    const peeked = try h.waitPeekContains("alpha", "ALPHA-TYPED-MARK");
    defer alloc.free(peeked);
}

test "ui: arrow browsing selects without attaching until enter" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    try h.startDetached("alpha", &.{"cat"});
    try h.startDetached("bravo", &.{"cat"});
    try h.sendLine("bravo", "BRAVO-MARK");
    const seeded = try h.waitPeekContains("bravo", "BRAVO-MARK");
    alloc.free(seeded);

    // bravo saw input last, so the UI focuses it on startup.
    var ui = try PtyClient.spawn(&h, &.{"ui"}, 24, 100);
    defer ui.deinit();
    try ui.waitFor("BRAVO-MARK");

    // C-a Down moves the selection to alpha without attaching it;
    // the bottom row hints at the browse keys.
    try ui.send("\x01\x1b[B");
    try ui.waitFor("enter attach");

    // The selection move stole nothing: alpha is still free. The
    // attach would have happened synchronously before the hint
    // rendered.
    const ls = try h.run(&.{"ls"});
    defer alloc.free(ls.stdout);
    defer alloc.free(ls.stderr);
    var lines = std.mem.splitScalar(u8, ls.stdout, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "alpha") == null) continue;
        try std.testing.expect(std.mem.indexOf(u8, line, "detached") != null);
    }

    // Enter attaches the selection; the focus switch forces a full
    // repaint, proven by the sidebar hint returning.
    ui.clearOutput();
    try ui.send("\r");
    try ui.waitFor("Keybinds: Ctrl+A");

    // Typing lands in alpha now.
    try ui.send("ALPHA-TYPED-MARK\r");
    try ui.waitFor("ALPHA-TYPED-MARK");
    const peeked = try h.waitPeekContains("alpha", "ALPHA-TYPED-MARK");
    defer alloc.free(peeked);

    // Browse again and cancel with Esc: the selection snaps back to
    // alpha, so a following Enter is a no-op and typing still lands
    // in alpha rather than the browsed-to session.
    try ui.send("\x01\x1b[A");
    try ui.waitFor("enter attach");
    try ui.send("\x1b");
    try ui.send("\rSTILL-ALPHA-MARK\r");
    try ui.waitFor("STILL-ALPHA-MARK");
    const still = try h.waitPeekContains("alpha", "STILL-ALPHA-MARK");
    defer alloc.free(still);
    const bravo_peek = try h.run(&.{ "peek", "bravo" });
    defer alloc.free(bravo_peek.stdout);
    defer alloc.free(bravo_peek.stderr);
    try std.testing.expect(std.mem.indexOf(u8, bravo_peek.stdout, "STILL-ALPHA-MARK") == null);
}

test "ui: report-events arrows browse after the prefix" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    // A focused app on the kitty keyboard protocol: the UI mirrors
    // it, so a report-events terminal would encode the prefix CSI-u
    // and arrows in the functional ESC [ 1 ; mods : event form. cat -v
    // makes any leaked bytes visible.
    try h.startDetached("kca", &.{
        "sh", "-c",
        "stty -echo -icanon; printf '\\033[>1u'; " ++
            "echo KITTY-ON; exec cat -v",
    });
    const seeded = try h.waitPeekContains("kca", "KITTY-ON");
    alloc.free(seeded);

    var ui = try PtyClient.spawn(&h, &.{"ui"}, 24, 100);
    defer ui.deinit();
    try ui.waitFor("KITTY-ON");
    try ui.waitFor("\x1b[=1;1u");

    // C-a then Down, exactly as a report-events terminal sends them:
    // the prefix kitty-encoded, the arrow with an explicit press
    // event subfield. This must arm browse mode (the sidebar hint),
    // the regression that the legacy ESC [ B handled before the
    // keyboard mirror started re-encoding arrows.
    ui.clearOutput();
    try ui.send("\x1b[97;5u");
    try ui.send("\x1b[1;1:1B");
    try ui.waitFor("enter attach");

    // Neither the prefix nor the arrow leaked into the session.
    const peek = try h.run(&.{ "peek", "kca" });
    defer alloc.free(peek.stdout);
    defer alloc.free(peek.stderr);
    try std.testing.expect(peek.term.Exited == 0);
    try std.testing.expect(std.mem.indexOf(u8, peek.stdout, "1;1:1B") == null);
    try std.testing.expect(std.mem.indexOf(u8, peek.stdout, "97;5u") == null);
}

test "ui: enter attaches the selection when nothing is focused" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    try h.startDetached("one", &.{"cat"});
    try h.startDetached("two", &.{"cat"});

    var holder1 = try PtyClient.spawn(&h, &.{ "attach", "one" }, 24, 80);
    defer holder1.deinit();
    var holder2 = try PtyClient.spawn(&h, &.{ "attach", "two" }, 24, 80);
    defer holder2.deinit();
    try h.sendLine("two", "TWO-HELD-MARK");
    try holder2.waitFor("TWO-HELD-MARK");

    // Every session is held elsewhere: the UI starts unfocused and
    // points at the most recently active session without stealing.
    var ui = try PtyClient.spawn(&h, &.{"ui"}, 24, 100);
    defer ui.deinit();
    try ui.waitFor("click the session to take it over");

    // With nothing live focused, bare arrows browse: Down wraps the
    // selection from two to one.
    try ui.send("\x1b[B");
    try ui.waitFor("enter attach");

    // Enter is a deliberate attach and may steal: one's holder is
    // kicked and typing from the UI lands in one. Waiting on the
    // repaint and the echo also keeps the UI's output drained; an
    // undrained pty would wedge the UI before it reads the keys.
    ui.clearOutput();
    try ui.send("\r");
    try ui.waitFor("Keybinds: Ctrl+A");
    try holder1.waitFor("attached elsewhere");
    _ = try holder1.waitExit();
    try ui.send("ONE-TYPED-MARK\r");
    try ui.waitFor("ONE-TYPED-MARK");
    const peeked = try h.waitPeekContains("one", "ONE-TYPED-MARK");
    defer alloc.free(peeked);
    try std.testing.expect(std.mem.indexOf(u8, holder2.output.items, "attached elsewhere") == null);
}

test "ui: C-a side arrows resize the sidebar" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    try h.startDetached("resized", &.{"cat"});

    var ui = try PtyClient.spawn(&h, &.{"ui"}, 24, 100);
    defer ui.deinit();
    try ui.waitFor("resized");

    // Focusing the session sizes its pty to the viewport: 100
    // columns minus the 24-column sidebar and the separator.
    try waitPeekSize(&h, "resized", 24, 75);

    // C-a Right grows the sidebar one column (shrinking the
    // viewport) and shows the resize hint on the bottom row.
    try ui.send("\x01\x1b[C");
    try ui.waitFor("left/right resize");
    try waitPeekSize(&h, "resized", 24, 74);

    // Bare side arrows keep adjusting while the resize is active.
    ui.clearOutput();
    try ui.send("\x1b[C\x1b[C");
    try ui.waitFor("left/right resize");
    try waitPeekSize(&h, "resized", 24, 72);

    // Esc restores the width from before the resize; the sidebar
    // hint returning proves the overlay cleared.
    ui.clearOutput();
    try ui.send("\x1b");
    try ui.waitFor("Keybinds: Ctrl+A");
    try waitPeekSize(&h, "resized", 24, 75);

    // C-a Left shrinks the sidebar; Enter keeps the width and ends
    // the resize.
    ui.clearOutput();
    try ui.send("\x01\x1b[D");
    try ui.waitFor("left/right resize");
    try waitPeekSize(&h, "resized", 24, 76);
    ui.clearOutput();
    try ui.send("\r");
    try ui.waitFor("Keybinds: Ctrl+A");

    // The resize ended: a bare side arrow forwards to the focused
    // application instead of adjusting. The echoed marker proves the
    // arrow was processed, so the unchanged size is settled.
    try ui.send("\x1b[C");
    try ui.send("AFTER-MARK\r");
    try ui.waitFor("AFTER-MARK");
    const peeked = try h.waitPeekContains("resized", "AFTER-MARK");
    alloc.free(peeked);
    try waitPeekSize(&h, "resized", 24, 76);
}

test "ui: C-a s hides the sidebar and brings it back" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    try h.startDetached("tucked", &.{"cat"});

    var ui = try PtyClient.spawn(&h, &.{"ui"}, 24, 100);
    defer ui.deinit();
    try ui.waitFor("tucked");
    try ui.waitFor("Keybinds: Ctrl+A");
    try waitPeekSize(&h, "tucked", 24, 75);

    // C-a s hides the sidebar: the session list, the keybind hint,
    // and the separator all leave the screen, and the viewport (with
    // the session pty behind it) takes the full terminal width.
    try ui.send("\x01s");
    try waitPeekSize(&h, "tucked", 24, 100);
    try waitScreen(alloc, &ui, 24, 100, &.{}, &.{
        "tucked", "Keybinds: Ctrl+A", "\u{2502}",
    });

    // Typed input still reaches the focused session while hidden.
    try ui.send("HIDDEN-MARK\r");
    try ui.waitFor("HIDDEN-MARK");

    // C-a s again brings the sidebar back at its old width.
    try ui.send("\x01s");
    try waitPeekSize(&h, "tucked", 24, 75);
    try waitScreen(alloc, &ui, 24, 100, &.{
        "tucked", "Keybinds: Ctrl+A", "\u{2502}",
    }, &.{});
}

/// Pump `peek --json` until the session reports the given pty size.
fn waitPeekSize(h: *Harness, name: []const u8, rows: u16, cols: u16) !void {
    var buf: [64]u8 = undefined;
    const needle = try std.fmt.bufPrint(&buf, "\"rows\":{d},\"cols\":{d}", .{ rows, cols });
    var deadline = Deadline.init(default_timeout_ms);
    while (true) {
        const result = try h.run(&.{ "peek", name, "--json" });
        defer h.alloc.free(result.stdout);
        defer h.alloc.free(result.stderr);
        if (result.term == .Exited and result.term.Exited == 0 and
            std.mem.indexOf(u8, result.stdout, needle) != null) return;
        try deadline.tick("session pty size never matched");
    }
}

test "ui: wheel scrolls primary-screen scrollback" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    try h.startDetached("scrolly", &.{"cat"});

    var ui = try PtyClient.spawn(&h, &.{"ui"}, 24, 100);
    defer ui.deinit();
    try ui.waitFor("scrolly");

    // Stream enough lines through cat that the earliest ones scroll
    // off the 24-row screen into the view's scrollback.
    var n: usize = 1;
    while (n <= 40) : (n += 1) {
        var buf: [16]u8 = undefined;
        const line = try std.fmt.bufPrint(&buf, "SCROLL-{d:0>3}", .{n});
        try h.sendLine("scrolly", line);
    }
    try ui.waitFor("SCROLL-040");

    // cat never asked for mouse reporting and stays on the primary
    // screen, so wheel-up over the viewport pages local scrollback.
    // Over-scrolling clamps at the top, which puts the first line on
    // screen regardless of exact row math.
    ui.clearOutput();
    for (0..35) |_| try ui.send("\x1b[<64;50;10M");
    try ui.waitFor(" scrollback");
    try ui.waitFor("SCROLL-001");

    // A lone Esc snaps the viewport back to the live bottom.
    ui.clearOutput();
    try ui.send("\x1b");
    try ui.waitFor("SCROLL-040");
}

test "ui: wheel sends arrows to alternate-screen applications" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    // The application switches to the alternate screen before the UI
    // attaches; the painted marker proves the switch landed. cat -v
    // makes the arrow bytes visible in peek.
    try h.startDetached("alty", &.{
        "bash", "-c", "printf '\\033[?1049hALTREADY'; exec cat -v",
    });
    const seeded = try h.waitPeekContains("alty", "ALTREADY");
    alloc.free(seeded);

    var ui = try PtyClient.spawn(&h, &.{"ui"}, 24, 100);
    defer ui.deinit();
    try ui.waitFor("ALTREADY");

    // Round-trip a typed marker before wheeling: its echo rendering
    // in the viewport proves the attach repaint, and the `.screen`
    // message sent with it, has been processed.
    try ui.send("READY\r");
    try ui.waitFor("READY");

    // One wheel-up tick over the viewport turns into arrow keys for
    // the application instead of paging local scrollback. The tty is
    // canonical, so Enter flushes the buffered arrows through cat -v.
    try ui.send("\x1b[<64;50;10M");
    try ui.send("\r");
    const peeked = try h.waitPeekContains("alty", "^[[A^[[A^[[A");
    alloc.free(peeked);
}

test "ui: wheel scrolls again after a session resets the terminal" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    try h.startDetached("rst", &.{"bash"});

    var ui = try PtyClient.spawn(&h, &.{"ui"}, 24, 100);
    defer ui.deinit();
    try ui.waitFor("rst");

    // Enter the alternate screen while attached: the daemon strips the
    // toggle, repaints, and sends `.screen` = alt, so the wheel would
    // turn into arrow keys for the application.
    try h.sendLine("rst", "printf '\\033[?1049hINALT'");
    try ui.waitFor("INALT");

    // A full reset (RIS, ESC c) returns the terminal to the primary
    // screen without a 47/1047/1049 toggle, so the alt-screen filter
    // never sees a switch. The daemon must still repaint and send
    // `.screen` = primary, or the client keeps treating the session as
    // alternate-screen and the wheel never pages local scrollback.
    try h.sendLine("rst", "printf '\\033c'");
    try h.sendLine("rst", "echo POSTRIS");
    try ui.waitFor("POSTRIS");

    // Fill the view's scrollback on the primary screen.
    try h.sendLine("rst", "i=1; while [ $i -le 60 ]; do echo SCROLL-$i; i=$((i+1)); done");
    try ui.waitFor("SCROLL-60");

    // Wheel up pages local scrollback instead of sending arrows; the
    // hint only renders while the viewport is scrolled off the bottom.
    ui.clearOutput();
    for (0..35) |_| try ui.send("\x1b[<64;50;10M");
    try ui.waitFor(" scrollback");
}

test "ui: session titles render in the sidebar" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    try h.startDetached("titled", &.{"/bin/sh"});

    var ui = try PtyClient.spawn(&h, &.{"ui"}, 24, 100);
    defer ui.deinit();
    try ui.waitFor("titled");

    // Set the window title via OSC 2. The marker is assembled from a
    // variable so the echoed command line cannot match the wait.
    try h.sendLine("titled", "T=TITLE; printf \"\\033]2;${T}-MARK\\007\"");
    try ui.waitFor("TITLE-MARK");
}

test "ui without a tty fails cleanly" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    const result = try h.run(&.{"ui"});
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    try std.testing.expect(result.term == .Exited and result.term.Exited == 1);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "requires a terminal") != null);
}
