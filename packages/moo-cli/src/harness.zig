//! Agent harness adapters: spawn and read transcripts for coding agents.
//!
//! moo can wrap any program, but coding agents (Claude Code, codex, pi) each
//! keep a structured JSONL transcript on disk. This module knows, per agent,
//! how to (1) launch it so its transcript is locatable — augmenting argv and
//! supplying per-session launch isolation — and (2) read that transcript back:
//! classify what the session is doing right now and produce a de-noised view of
//! the conversation. The transport (daemon + PTY) stays agent-agnostic.
//!
//! The shape mirrors the keepalive `Harness` trait: `prepare` + `launchOverrides`
//! for spawning, `transcriptPath` + `detect` + `dump` for reading, and a string
//! registry via `Agent.fromId`. Adapters dispatch on an enum rather than a vtable
//! so the whole module is allocation-light and unit-testable without a daemon.

const std = @import("std");

// -- Session state --------------------------------------------------------

/// Harness-agnostic notion of "what is this session doing right now".
pub const SessionState = enum {
    /// Actively working: generating a reply and/or executing tools.
    running,
    /// Turn finished; the agent is sitting idle at its prompt.
    idle,
    /// The agent asked for human input via a native gating tool
    /// (Claude's AskUserQuestion / ExitPlanMode).
    waiting_for_input,
    /// Last turn was cut off (e.g. max_tokens).
    truncated,
    /// The harness process has exited.
    exited,
    /// Could not determine (e.g. transcript not created yet).
    unknown,

    pub fn asStr(self: SessionState) []const u8 {
        return @tagName(self);
    }

    /// Not actively working: usually needs a human or orchestrator.
    pub fn isStopped(self: SessionState) bool {
        return switch (self) {
            .idle, .waiting_for_input, .truncated, .exited => true,
            .running, .unknown => false,
        };
    }
};

/// Classification result. Owned strings are freed by `deinit`.
pub const StateReport = struct {
    state: SessionState,
    /// Human elaboration (e.g. the pending question, or executing tools).
    detail: ?[]const u8 = null,
    stop_reason: ?[]const u8 = null,
    messages: usize = 0,
    pending_tools: []const []const u8 = &.{},

    pub fn deinit(self: StateReport, alloc: std.mem.Allocator) void {
        if (self.detail) |d| alloc.free(d);
        if (self.stop_reason) |s| alloc.free(s);
        for (self.pending_tools) |t| alloc.free(t);
        if (self.pending_tools.len > 0) alloc.free(self.pending_tools);
    }
};

/// Result of preparing a launch: the augmented argv plus any session id the
/// adapter pinned so the transcript can later be located. All strings owned.
pub const Prepared = struct {
    argv: []const []const u8,
    session_id: ?[]const u8 = null,

    pub fn deinit(self: Prepared, alloc: std.mem.Allocator) void {
        for (self.argv) |a| alloc.free(a);
        alloc.free(self.argv);
        if (self.session_id) |s| alloc.free(s);
    }
};

/// Per-session launch isolation an adapter may request. `env` is applied in the
/// forked child before exec; `session_store` is persisted in the sidecar so the
/// transcript can be located later. Both empty by default.
pub const LaunchOverrides = struct {
    env: []const [2][]const u8 = &.{},
    session_store: ?[]const u8 = null,

    pub fn deinit(self: LaunchOverrides, alloc: std.mem.Allocator) void {
        for (self.env) |pair| {
            alloc.free(pair[0]);
            alloc.free(pair[1]);
        }
        if (self.env.len > 0) alloc.free(self.env);
        if (self.session_store) |s| alloc.free(s);
    }
};

/// Persisted per-session metadata, keyed by session name in the socket dir.
/// Enough to re-locate a transcript after the launching process is gone.
pub const Sidecar = struct {
    agent: Agent,
    session_id: ?[]const u8 = null,
    session_store: ?[]const u8 = null,
    cwd: ?[]const u8 = null,

    pub fn deinit(self: Sidecar, alloc: std.mem.Allocator) void {
        if (self.session_id) |s| alloc.free(s);
        if (self.session_store) |s| alloc.free(s);
        if (self.cwd) |s| alloc.free(s);
    }

    /// Serialize to JSON (caller frees).
    pub fn toJson(self: Sidecar, alloc: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(alloc);
        try out.appendSlice(alloc, "{\"agent\":");
        try appendJsonStr(alloc, &out, self.agent.id());
        if (self.session_id) |s| {
            try out.appendSlice(alloc, ",\"session_id\":");
            try appendJsonStr(alloc, &out, s);
        }
        if (self.session_store) |s| {
            try out.appendSlice(alloc, ",\"session_store\":");
            try appendJsonStr(alloc, &out, s);
        }
        if (self.cwd) |s| {
            try out.appendSlice(alloc, ",\"cwd\":");
            try appendJsonStr(alloc, &out, s);
        }
        try out.append(alloc, '}');
        return out.toOwnedSlice(alloc);
    }

    /// Parse from JSON. Returns owned strings; caller calls `deinit`.
    pub fn fromJson(alloc: std.mem.Allocator, data: []const u8) !Sidecar {
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, data, .{}) catch
            return error.BadSidecar;
        defer parsed.deinit();
        const root = parsed.value;
        const agent_id = getStr(root, "agent") orelse return error.BadSidecar;
        const agent = Agent.fromId(agent_id) orelse return error.BadSidecar;
        return .{
            .agent = agent,
            .session_id = try dupeOpt(alloc, getStr(root, "session_id")),
            .session_store = try dupeOpt(alloc, getStr(root, "session_store")),
            .cwd = try dupeOpt(alloc, getStr(root, "cwd")),
        };
    }
};

// -- The agent registry ---------------------------------------------------

pub const Agent = enum {
    claude,
    codex,
    pi,
    raw,
    bash,
    zsh,

    /// Resolve an `--agent` identifier; null when unrecognized.
    pub fn fromId(name: []const u8) ?Agent {
        const eql = std.mem.eql;
        if (eql(u8, name, "claude") or eql(u8, name, "claude-code")) return .claude;
        if (eql(u8, name, "codex")) return .codex;
        if (eql(u8, name, "pi")) return .pi;
        if (eql(u8, name, "raw") or eql(u8, name, "shell")) return .raw;
        if (eql(u8, name, "bash")) return .bash;
        if (eql(u8, name, "zsh")) return .zsh;
        return null;
    }

    pub fn id(self: Agent) []const u8 {
        return @tagName(self);
    }

    /// Whether this agent keeps a readable transcript (so `moo read` applies).
    pub fn hasTranscript(self: Agent) bool {
        return switch (self) {
            .claude, .codex, .pi => true,
            .raw, .bash, .zsh => false,
        };
    }

    /// Command used when the user provided none. Caller owns the result.
    pub fn defaultCommand(self: Agent, alloc: std.mem.Allocator) ![]const []const u8 {
        return switch (self) {
            .claude => try dupeArgv(alloc, &.{"claude"}),
            // Interactive TUI, unattended-safe: never block on an approval
            // prompt, workspace-write sandbox. The boot trust gate is handled
            // by the seeded CODEX_HOME in launchOverrides, not here.
            .codex => try dupeArgv(alloc, &.{ "codex", "-a", "never", "-s", "workspace-write" }),
            .pi => try dupeArgv(alloc, &.{"pi"}),
            .raw => try dupeArgv(alloc, &.{std.posix.getenv("SHELL") orelse "/bin/sh"}),
            .bash => try dupeArgv(alloc, &.{ "bash", "-i" }),
            .zsh => try dupeArgv(alloc, &.{ "zsh", "-i" }),
        };
    }

    /// Augment the user's command so the transcript is locatable. `store_dir`
    /// is the per-session store path moo reserved for this session (used by pi's
    /// `--session-dir`). Caller owns `Prepared`.
    pub fn prepare(
        self: Agent,
        alloc: std.mem.Allocator,
        user_cmd: []const []const u8,
        store_dir: []const u8,
    ) !Prepared {
        return switch (self) {
            .claude => try prepareClaude(alloc, user_cmd),
            .codex => try prepareCodex(alloc, user_cmd),
            .pi => try preparePi(alloc, user_cmd, store_dir),
            .raw => try prepareRaw(self, alloc, user_cmd),
            .bash, .zsh => try prepareShell(self, alloc, user_cmd),
        };
    }

    /// Per-session env + transcript-store isolation. May seed the filesystem
    /// (codex's CODEX_HOME). `store_dir` is created as needed. Caller owns it.
    pub fn launchOverrides(
        self: Agent,
        alloc: std.mem.Allocator,
        session_id: ?[]const u8,
        cwd: []const u8,
        store_dir: []const u8,
    ) !LaunchOverrides {
        _ = session_id; // derived from store_dir; reserved for future adapters
        return switch (self) {
            .codex => try codexLaunchOverrides(alloc, cwd, store_dir),
            .pi => try piLaunchOverrides(alloc, store_dir),
            .claude, .raw, .bash, .zsh => .{},
        };
    }

    /// Locate the transcript for a known session, or null when none exists yet.
    /// Caller owns the returned path.
    pub fn transcriptPath(self: Agent, alloc: std.mem.Allocator, sc: Sidecar) !?[]u8 {
        return switch (self) {
            .claude => if (sc.session_id) |sid| try findClaudeTranscript(alloc, sid) else null,
            .codex => if (sc.session_store) |store| try findCodexRollout(alloc, store) else null,
            .pi => if (sc.session_store) |store|
                if (sc.session_id) |sid| try findPiTranscript(alloc, store, sid) else null
            else
                null,
            .raw, .bash, .zsh => null,
        };
    }

    /// Classify the session from transcript bytes. Empty/garbage input is never
    /// `idle` for the agentic harnesses (so `moo wait` cannot short-circuit).
    pub fn detect(self: Agent, alloc: std.mem.Allocator, data: []const u8) !StateReport {
        return switch (self) {
            .claude => try detectClaude(alloc, data),
            .codex => try detectCodex(alloc, data),
            .pi => try detectPi(alloc, data),
            .raw, .bash, .zsh => .{ .state = .unknown },
        };
    }

    /// Produce a de-noised JSON view of the transcript (caller frees).
    pub fn dumpJson(
        self: Agent,
        alloc: std.mem.Allocator,
        data: []const u8,
        include_thinking: bool,
    ) ![]u8 {
        return self.renderTranscript(alloc, data, include_thinking, .json);
    }

    /// Produce a de-noised human-readable view of the transcript (caller frees).
    pub fn dumpText(
        self: Agent,
        alloc: std.mem.Allocator,
        data: []const u8,
        include_thinking: bool,
    ) ![]u8 {
        return self.renderTranscript(alloc, data, include_thinking, .text);
    }

    fn renderTranscript(
        self: Agent,
        alloc: std.mem.Allocator,
        data: []const u8,
        include_thinking: bool,
        format: RenderFormat,
    ) ![]u8 {
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const a = arena.allocator();
        const entries: []const Entry = switch (self) {
            .claude => try denoiseClaude(a, data, include_thinking),
            .codex => try denoiseCodex(a, data),
            .pi => try denoisePi(a, data, include_thinking),
            .raw, .bash, .zsh => &.{},
        };
        return switch (format) {
            .json => renderJson(alloc, entries),
            .text => renderText(alloc, entries, include_thinking),
        };
    }
};

const RenderFormat = enum { json, text };

// -- Shared launch helpers ------------------------------------------------

fn prepareClaude(alloc: std.mem.Allocator, user_cmd: []const []const u8) !Prepared {
    var argv = try baseArgv(alloc, user_cmd, &.{"claude"});
    errdefer freeArgvList(alloc, &argv);

    var session_id: ?[]u8 = null;
    errdefer if (session_id) |s| alloc.free(s);
    if (scanFlag(argv.items, "--session-id")) |existing| {
        session_id = try alloc.dupe(u8, existing);
    } else {
        const sid = try mintSessionId(alloc);
        errdefer alloc.free(sid);
        try argv.append(alloc, try alloc.dupe(u8, "--session-id"));
        try argv.append(alloc, try alloc.dupe(u8, sid));
        session_id = sid;
    }
    return .{ .argv = try argv.toOwnedSlice(alloc), .session_id = session_id };
}

fn prepareCodex(alloc: std.mem.Allocator, user_cmd: []const []const u8) !Prepared {
    // codex mints its own UUIDv7 rollout id; we locate it via the isolated
    // CODEX_HOME set in launchOverrides, so nothing to pin here.
    var argv = try baseArgv(alloc, user_cmd, &.{ "codex", "-a", "never", "-s", "workspace-write" });
    return .{ .argv = try argv.toOwnedSlice(alloc), .session_id = null };
}

fn preparePi(alloc: std.mem.Allocator, user_cmd: []const []const u8, store_dir: []const u8) !Prepared {
    var argv = try baseArgv(alloc, user_cmd, &.{"pi"});
    errdefer freeArgvList(alloc, &argv);

    var session_id: ?[]u8 = null;
    errdefer if (session_id) |s| alloc.free(s);
    if (scanFlag(argv.items, "--session-id")) |existing| {
        session_id = try alloc.dupe(u8, existing);
    } else {
        const sid = try mintSessionId(alloc);
        errdefer alloc.free(sid);
        try argv.append(alloc, try alloc.dupe(u8, "--session-id"));
        try argv.append(alloc, try alloc.dupe(u8, sid));
        session_id = sid;
    }

    // Isolate the transcript in the per-session store dir (pi writes
    // `<ts>_<id>.jsonl` directly under --session-dir, no cwd slug).
    if (scanFlag(argv.items, "--session-dir") == null) {
        try argv.append(alloc, try alloc.dupe(u8, "--session-dir"));
        try argv.append(alloc, try alloc.dupe(u8, store_dir));
    }
    return .{ .argv = try argv.toOwnedSlice(alloc), .session_id = session_id };
}

fn prepareRaw(self: Agent, alloc: std.mem.Allocator, user_cmd: []const []const u8) !Prepared {
    const def = try self.defaultCommand(alloc);
    if (user_cmd.len == 0) return .{ .argv = def, .session_id = null };
    freeArgv(alloc, def);
    var argv = try baseArgv(alloc, user_cmd, &.{});
    return .{ .argv = try argv.toOwnedSlice(alloc), .session_id = null };
}

fn prepareShell(self: Agent, alloc: std.mem.Allocator, user_cmd: []const []const u8) !Prepared {
    if (user_cmd.len == 0) {
        return .{ .argv = try self.defaultCommand(alloc), .session_id = null };
    }
    // A payload runs as a single shell command, like `bash -lc "<joined>"`.
    const joined = try std.mem.join(alloc, " ", user_cmd);
    defer alloc.free(joined);
    var argv = try dupeArgvList(alloc, &.{ self.id(), "-lc", joined });
    return .{ .argv = try argv.toOwnedSlice(alloc), .session_id = null };
}

fn codexLaunchOverrides(alloc: std.mem.Allocator, cwd: []const u8, store_dir: []const u8) !LaunchOverrides {
    // Seed a per-session CODEX_HOME so its sessions/ tree holds exactly one
    // rollout (sidestepping the mtime race in the shared ~/.codex). If seeding
    // fails we fall back to the inherited home: the session still runs, state
    // may read `unknown` — honest rather than wrong.
    seedCodexHome(alloc, cwd, store_dir) catch return .{};

    const env = try alloc.alloc([2][]const u8, 1);
    errdefer alloc.free(env);
    env[0] = .{ try alloc.dupe(u8, "CODEX_HOME"), try alloc.dupe(u8, store_dir) };
    return .{ .env = env, .session_store = try alloc.dupe(u8, store_dir) };
}

fn piLaunchOverrides(alloc: std.mem.Allocator, store_dir: []const u8) !LaunchOverrides {
    std.fs.cwd().makePath(store_dir) catch {};
    return .{ .session_store = try alloc.dupe(u8, store_dir) };
}

/// Seed `store_dir` as a codex home: symlink the real `auth.json` (no secret
/// copied) and copy `config.toml`, pre-trusting `cwd` so the interactive TUI
/// never shows the directory-trust gate.
fn seedCodexHome(alloc: std.mem.Allocator, cwd: []const u8, store_dir: []const u8) !void {
    try std.fs.cwd().makePath(store_dir);
    std.posix.fchmodat(std.posix.AT.FDCWD, store_dir, 0o700, 0) catch {};

    const src = try agentRoot(alloc, ".codex");
    defer alloc.free(src);

    // Credentials: symlink so no copy of the secret lands on disk.
    const auth_src = try std.fs.path.join(alloc, &.{ src, "auth.json" });
    defer alloc.free(auth_src);
    if (fileExists(auth_src)) {
        const auth_dst = try std.fs.path.join(alloc, &.{ store_dir, "auth.json" });
        defer alloc.free(auth_dst);
        std.posix.symlink(auth_src, auth_dst) catch {};
    }

    // Config: copy then append a trust entry for the canonical cwd.
    const cfg_src = try std.fs.path.join(alloc, &.{ src, "config.toml" });
    defer alloc.free(cfg_src);
    const existing = std.fs.cwd().readFileAlloc(alloc, cfg_src, 1 << 20) catch
        try alloc.dupe(u8, "");
    defer alloc.free(existing);

    var canon_buf: [std.fs.max_path_bytes]u8 = undefined;
    const canon = std.fs.cwd().realpath(cwd, &canon_buf) catch cwd;

    var cfg: std.ArrayList(u8) = .empty;
    defer cfg.deinit(alloc);
    try cfg.appendSlice(alloc, existing);
    const key = try std.fmt.allocPrint(alloc, "[projects.\"{s}\"]", .{canon});
    defer alloc.free(key);
    if (std.mem.indexOf(u8, cfg.items, key) == null) {
        if (cfg.items.len > 0 and cfg.items[cfg.items.len - 1] != '\n') try cfg.append(alloc, '\n');
        try cfg.print(alloc, "\n{s}\ntrust_level = \"trusted\"\n", .{key});
    }
    const cfg_dst = try std.fs.path.join(alloc, &.{ store_dir, "config.toml" });
    defer alloc.free(cfg_dst);
    try std.fs.cwd().writeFile(.{ .sub_path = cfg_dst, .data = cfg.items });
}

// -- Transcript location --------------------------------------------------

/// `~/.claude/projects/*/<session_id>.jsonl` (the id is globally unique).
fn findClaudeTranscript(alloc: std.mem.Allocator, session_id: []const u8) !?[]u8 {
    const root = try agentRoot(alloc, ".claude");
    defer alloc.free(root);
    const projects = try std.fs.path.join(alloc, &.{ root, "projects" });
    defer alloc.free(projects);

    const file = try std.fmt.allocPrint(alloc, "{s}.jsonl", .{session_id});
    defer alloc.free(file);

    var dir = std.fs.cwd().openDir(projects, .{ .iterate = true }) catch return null;
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .directory) continue;
        const candidate = try std.fs.path.join(alloc, &.{ projects, entry.name, file });
        if (fileExists(candidate)) return candidate;
        alloc.free(candidate);
    }
    return null;
}

/// The single `rollout-*.jsonl` under an isolated CODEX_HOME's `sessions/` tree.
fn findCodexRollout(alloc: std.mem.Allocator, home: []const u8) !?[]u8 {
    const sessions = try std.fs.path.join(alloc, &.{ home, "sessions" });
    defer alloc.free(sessions);

    var best: ?[]u8 = null;
    var best_mtime: i128 = std.math.minInt(i128);
    var dir = std.fs.cwd().openDir(sessions, .{ .iterate = true }) catch return null;
    defer dir.close();
    var walker = dir.walk(alloc) catch return null;
    defer walker.deinit();
    while (walker.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.basename, "rollout-")) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".jsonl")) continue;
        const full = try std.fs.path.join(alloc, &.{ sessions, entry.path });
        const st = dir.statFile(entry.path) catch {
            alloc.free(full);
            continue;
        };
        if (st.mtime > best_mtime) {
            if (best) |b| alloc.free(b);
            best = full;
            best_mtime = st.mtime;
        } else {
            alloc.free(full);
        }
    }
    return best;
}

/// `<dir>/*_<session_id>.jsonl`; null during pi's lazy no-file window.
fn findPiTranscript(alloc: std.mem.Allocator, store_dir: []const u8, session_id: []const u8) !?[]u8 {
    const suffix = try std.fmt.allocPrint(alloc, "_{s}.jsonl", .{session_id});
    defer alloc.free(suffix);

    var dir = std.fs.cwd().openDir(store_dir, .{ .iterate = true }) catch return null;
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, suffix)) continue;
        return try std.fs.path.join(alloc, &.{ store_dir, entry.name });
    }
    return null;
}

// =========================================================================
// Claude adapter
// =========================================================================

/// Tools whose unanswered `tool_use` means Claude is blocked on human input.
const claude_gating_tools = [_][]const u8{ "AskUserQuestion", "ExitPlanMode" };

fn isGatingTool(name: []const u8) bool {
    for (claude_gating_tools) |g| {
        if (std.mem.eql(u8, name, g)) return true;
    }
    return false;
}

const ClaudeTool = struct { id: []const u8, name: []const u8 };

const ClaudeRec = union(enum) {
    assistant: struct {
        id: []const u8,
        stop: ?[]const u8,
        tools: []const ClaudeTool,
        value: std.json.Value,
    },
    tool_results: []const []const u8,
    user_prompt,
};

/// Claude writes ONE content block per JSONL record; a logical assistant message
/// is split across 1-3 records sharing `message.id`.
fn parseClaudeRecords(a: std.mem.Allocator, data: []const u8) ![]const ClaudeRec {
    var recs: std.ArrayList(ClaudeRec) = .empty;
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        const v = std.json.parseFromSliceLeaky(std.json.Value, a, line, .{}) catch continue;
        const kind = getStr(v, "type") orelse "";
        if (std.mem.eql(u8, kind, "assistant")) {
            const msg = get(v, "message");
            const id = if (msg) |m| getStr(m, "id") orelse "" else "";
            const stop = if (msg) |m| getStr(m, "stop_reason") else null;
            var tools: std.ArrayList(ClaudeTool) = .empty;
            if (msg) |m| if (getArray(m, "content")) |content| {
                for (content) |b| {
                    if (std.mem.eql(u8, getStr(b, "type") orelse "", "tool_use")) {
                        try tools.append(a, .{
                            .id = getStr(b, "id") orelse "",
                            .name = getStr(b, "name") orelse "",
                        });
                    }
                }
            };
            try recs.append(a, .{ .assistant = .{
                .id = id,
                .stop = stop,
                .tools = try tools.toOwnedSlice(a),
                .value = v,
            } });
        } else if (std.mem.eql(u8, kind, "user")) {
            if (get(v, "toolUseResult") != null) {
                var ids: std.ArrayList([]const u8) = .empty;
                if (get(v, "message")) |m| if (getArray(m, "content")) |content| {
                    for (content) |b| {
                        if (std.mem.eql(u8, getStr(b, "type") orelse "", "tool_result")) {
                            if (getStr(b, "tool_use_id")) |tid| try ids.append(a, tid);
                        }
                    }
                };
                try recs.append(a, .{ .tool_results = try ids.toOwnedSlice(a) });
            } else {
                try recs.append(a, .user_prompt);
            }
        }
        // system + unknown/wrapper types are ignored.
    }
    return recs.toOwnedSlice(a);
}

fn detectClaude(alloc: std.mem.Allocator, data: []const u8) !StateReport {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const recs = try parseClaudeRecords(a, data);

    // Count logical messages: user prompts + distinct assistant message ids.
    var seen: std.ArrayList([]const u8) = .empty;
    var messages: usize = 0;
    for (recs) |r| switch (r) {
        .user_prompt => messages += 1,
        .assistant => |asst| {
            if (!containsStr(seen.items, asst.id)) {
                try seen.append(a, asst.id);
                messages += 1;
            }
        },
        else => {},
    };

    // Last assistant record index.
    var last_a: ?usize = null;
    for (recs, 0..) |r, i| {
        if (r == .assistant) last_a = i;
    }

    const ia = last_a orelse {
        var has_prompt = false;
        for (recs) |r| {
            if (r == .user_prompt) has_prompt = true;
        }
        return finishReport(alloc, if (has_prompt) .running else .unknown, null, null, messages, &.{});
    };

    const last_id = recs[ia].assistant.id;

    // A human prompt appended after the last assistant turn means the agent owes
    // a reply: it is working again, regardless of that turn's stop_reason. (codex
    // and pi already report running for a trailing human turn; match them.)
    for (recs[ia + 1 ..]) |r| {
        if (r == .user_prompt) {
            return finishReport(alloc, .running, null, null, messages, &.{});
        }
    }

    // Gather all tool_use blocks of the last logical message (its blocks span
    // records sharing last_id), the last non-null stop_reason among them (a
    // split message can end on a stop-less block), and any gating-tool record.
    var tools: std.ArrayList(ClaudeTool) = .empty;
    var gating_value: ?std.json.Value = null;
    var stop: ?[]const u8 = null;
    for (recs) |r| {
        if (r == .assistant and std.mem.eql(u8, r.assistant.id, last_id)) {
            if (r.assistant.stop) |s| stop = s;
            for (r.assistant.tools) |t| {
                if (isGatingTool(t.name)) gating_value = r.assistant.value;
                try tools.append(a, t);
            }
        }
    }

    // tool_result ids appearing after the last assistant record.
    var result_ids: std.ArrayList([]const u8) = .empty;
    for (recs[ia + 1 ..]) |r| {
        if (r == .tool_results) {
            for (r.tool_results) |tid| try result_ids.append(a, tid);
        }
    }

    var pending: std.ArrayList(ClaudeTool) = .empty;
    for (tools.items) |t| {
        if (!containsStr(result_ids.items, t.id)) try pending.append(a, t);
    }
    var waiting = false;
    for (pending.items) |t| {
        if (isGatingTool(t.name)) waiting = true;
    }

    const state: SessionState = blk: {
        const s = stop orelse break :blk .unknown;
        if (std.mem.eql(u8, s, "end_turn") or std.mem.eql(u8, s, "stop_sequence")) break :blk .idle;
        if (std.mem.eql(u8, s, "max_tokens")) break :blk .truncated;
        if (std.mem.eql(u8, s, "tool_use")) break :blk if (waiting) .waiting_for_input else .running;
        break :blk .unknown;
    };

    var detail: ?[]const u8 = null;
    if (state == .waiting_for_input) {
        detail = if (gating_value) |gv| firstQuestionText(a, gv) else null;
    } else if (state == .running and pending.items.len > 0) {
        var names: std.ArrayList([]const u8) = .empty;
        for (pending.items) |t| try names.append(a, t.name);
        const joined = try std.mem.join(a, ", ", names.items);
        detail = try std.fmt.allocPrint(a, "executing: {s}", .{joined});
    }

    var pending_names: std.ArrayList([]const u8) = .empty;
    for (pending.items) |t| try pending_names.append(a, t.name);

    return finishReport(alloc, state, detail, stop, messages, pending_names.items);
}

/// Pull the first AskUserQuestion / ExitPlanMode prompt text for display.
fn firstQuestionText(a: std.mem.Allocator, assistant: std.json.Value) ?[]const u8 {
    const msg = get(assistant, "message") orelse return null;
    const content = getArray(msg, "content") orelse return null;
    for (content) |b| {
        const name = getStr(b, "name") orelse "";
        if (std.mem.eql(u8, getStr(b, "type") orelse "", "tool_use") and
            std.mem.eql(u8, name, "AskUserQuestion"))
        {
            const input = get(b, "input") orelse continue;
            const qs = getArray(input, "questions") orelse continue;
            if (qs.len == 0) continue;
            const q = qs[0];
            const header = getStr(q, "header") orelse "";
            const question = getStr(q, "question") orelse "";
            if (header.len == 0) return a.dupe(u8, question) catch null;
            return std.fmt.allocPrint(a, "[{s}] {s}", .{ header, question }) catch null;
        }
        if (std.mem.eql(u8, name, "ExitPlanMode")) {
            return a.dupe(u8, "Plan ready — awaiting approval (ExitPlanMode)") catch null;
        }
    }
    return null;
}

const ClaudeAcc = struct {
    id: []const u8,
    text: std.ArrayList(u8) = .empty,
    thinking: std.ArrayList(u8) = .empty,
    tools: std.ArrayList(ToolCall) = .empty,
    stop: ?[]const u8 = null,
};

fn flushClaudeAcc(
    a: std.mem.Allocator,
    out: *std.ArrayList(Entry),
    acc: *?ClaudeAcc,
    include_thinking: bool,
) !void {
    const ac = acc.* orelse return;
    acc.* = null;
    const has_thinking = include_thinking and ac.thinking.items.len > 0;
    if (ac.text.items.len == 0 and ac.tools.items.len == 0 and !has_thinking) return;
    try out.append(a, .{
        .role = .assistant,
        .text = ac.text.items,
        .thinking = if (has_thinking) ac.thinking.items else "",
        .tools = ac.tools.items,
        .stop_reason = ac.stop orelse "",
    });
}

/// De-noised transcript: prompts, assistant text + tool calls, tool-result
/// summaries. Records sharing a `message.id` coalesce into one entry.
fn denoiseClaude(a: std.mem.Allocator, data: []const u8, include_thinking: bool) ![]const Entry {
    var out: std.ArrayList(Entry) = .empty;
    var acc: ?ClaudeAcc = null;
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        const v = std.json.parseFromSliceLeaky(std.json.Value, a, line, .{}) catch continue;
        const kind = getStr(v, "type") orelse "";
        if (!std.mem.eql(u8, kind, "assistant")) try flushClaudeAcc(a, &out, &acc, include_thinking);

        if (std.mem.eql(u8, kind, "assistant")) {
            const msg = get(v, "message") orelse continue;
            const mid = getStr(msg, "id") orelse "";
            const content = get(msg, "content") orelse continue;
            if (acc) |existing| {
                if (!std.mem.eql(u8, existing.id, mid)) try flushClaudeAcc(a, &out, &acc, include_thinking);
            }
            if (acc == null) acc = .{ .id = mid };
            var ac = &acc.?;
            try appendBlockText(a, &ac.text, content, "text", "text");
            try appendBlockText(a, &ac.thinking, content, "thinking", "thinking");
            if (asArray(content)) |arr| {
                for (arr) |b| {
                    if (std.mem.eql(u8, getStr(b, "type") orelse "", "tool_use")) {
                        try ac.tools.append(a, .{
                            .name = getStr(b, "name") orelse "",
                            .input_json = try valueToJson(a, get(b, "input")),
                        });
                    }
                }
            }
            if (getStr(msg, "stop_reason")) |sr| ac.stop = sr;
        } else if (std.mem.eql(u8, kind, "user")) {
            if (get(v, "toolUseResult") != null) {
                var results: std.ArrayList([]const u8) = .empty;
                if (get(v, "message")) |m| if (getArray(m, "content")) |content| {
                    for (content) |b| {
                        if (std.mem.eql(u8, getStr(b, "type") orelse "", "tool_result")) {
                            const text = try contentToText(a, get(b, "content"));
                            try results.append(a, try truncate(a, text, 280));
                        }
                    }
                };
                if (results.items.len > 0) {
                    try out.append(a, .{ .role = .tool, .tool_results = results.items });
                }
            } else {
                const text = if (get(v, "message")) |m|
                    try blockTextAlloc(a, get(m, "content"), "text", "text")
                else
                    "";
                try out.append(a, .{ .role = .user, .text = text });
            }
        }
    }
    try flushClaudeAcc(a, &out, &acc, include_thinking);
    return out.toOwnedSlice(a);
}

// =========================================================================
// Codex adapter
// =========================================================================

/// Classify a codex rollout from its `event_msg` lifecycle events. Keys off the
/// LAST lifecycle event so a fresh `task_started` after a prior `task_complete`
/// reports `running` again. Default is `unknown`, never `idle`.
fn detectCodex(alloc: std.mem.Allocator, data: []const u8) !StateReport {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var last: ?[]const u8 = null;
    var msgs: usize = 0;
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        const v = std.json.parseFromSliceLeaky(std.json.Value, a, line, .{}) catch continue;
        if (!std.mem.eql(u8, getStr(v, "type") orelse "", "event_msg")) continue;
        const payload = get(v, "payload") orelse continue;
        const pt = getStr(payload, "type") orelse continue;
        if (std.mem.eql(u8, pt, "task_started")) last = "task_started";
        if (std.mem.eql(u8, pt, "task_complete")) last = "task_complete";
        if (std.mem.eql(u8, pt, "turn_aborted")) last = "turn_aborted";
        if (std.mem.eql(u8, pt, "user_message")) msgs += 1;
        if (std.mem.eql(u8, pt, "agent_message")) msgs += 1;
    }

    const state: SessionState = blk: {
        const l = last orelse break :blk .unknown;
        if (std.mem.eql(u8, l, "task_complete") or std.mem.eql(u8, l, "turn_aborted")) break :blk .idle;
        if (std.mem.eql(u8, l, "task_started")) break :blk .running;
        break :blk .unknown;
    };
    return finishReport(alloc, state, null, last, msgs, &.{});
}

/// De-noised codex transcript: human prompt (`user_message`) + agent reply
/// (`agent_message`). Synthetic `response_item` developer/user messages and
/// encrypted reasoning are skipped, so injected context never surfaces.
fn denoiseCodex(a: std.mem.Allocator, data: []const u8) ![]const Entry {
    var out: std.ArrayList(Entry) = .empty;
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        const v = std.json.parseFromSliceLeaky(std.json.Value, a, line, .{}) catch continue;
        if (!std.mem.eql(u8, getStr(v, "type") orelse "", "event_msg")) continue;
        const payload = get(v, "payload") orelse continue;
        const pt = getStr(payload, "type") orelse continue;
        if (std.mem.eql(u8, pt, "user_message")) {
            if (codexMessageText(payload)) |t| try out.append(a, .{ .role = .user, .text = t });
        } else if (std.mem.eql(u8, pt, "agent_message")) {
            if (codexMessageText(payload)) |t| try out.append(a, .{ .role = .assistant, .text = t });
        }
    }
    return out.toOwnedSlice(a);
}

fn codexMessageText(payload: std.json.Value) ?[]const u8 {
    if (getStr(payload, "message")) |s| return s;
    if (getStr(payload, "text")) |s| return s;
    return null;
}

// =========================================================================
// pi adapter
// =========================================================================

const PiMsg = struct {
    role: []const u8,
    stop: ?[]const u8,
    err: ?[]const u8,
    tools: []const []const u8,
};

fn parsePiMessages(a: std.mem.Allocator, data: []const u8) ![]const PiMsg {
    var msgs: std.ArrayList(PiMsg) = .empty;
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        const v = std.json.parseFromSliceLeaky(std.json.Value, a, line, .{}) catch continue;
        if (!std.mem.eql(u8, getStr(v, "type") orelse "", "message")) continue;
        const m = get(v, "message") orelse continue;
        var tools: std.ArrayList([]const u8) = .empty;
        if (getArray(m, "content")) |content| {
            for (content) |b| {
                if (std.mem.eql(u8, getStr(b, "type") orelse "", "toolCall")) {
                    try tools.append(a, getStr(b, "name") orelse "");
                }
            }
        }
        try msgs.append(a, .{
            .role = getStr(m, "role") orelse "",
            .stop = getStr(m, "stopReason"),
            .err = getStr(m, "errorMessage"),
            .tools = try tools.toOwnedSlice(a),
        });
    }
    return msgs.toOwnedSlice(a);
}

/// Classify pi from its last `message` record. No message (empty/garbage/lazy
/// no-file) → `unknown`, provably not `idle`.
fn detectPi(alloc: std.mem.Allocator, data: []const u8) !StateReport {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const msgs = try parsePiMessages(a, data);
    if (msgs.len == 0) return finishReport(alloc, .unknown, null, null, 0, &.{});
    const last = msgs[msgs.len - 1];

    var detail: ?[]const u8 = null;
    var pending: []const []const u8 = &.{};
    const state: SessionState = blk: {
        if (std.mem.eql(u8, last.role, "assistant")) {
            const s = last.stop orelse break :blk .running;
            if (std.mem.eql(u8, s, "stop") or std.mem.eql(u8, s, "stop_sequence") or
                std.mem.eql(u8, s, "aborted")) break :blk .idle;
            if (std.mem.eql(u8, s, "toolUse")) {
                pending = last.tools;
                if (pending.len > 0) {
                    const joined = try std.mem.join(a, ", ", pending);
                    detail = try std.fmt.allocPrint(a, "executing: {s}", .{joined});
                }
                break :blk .running;
            }
            if (std.mem.eql(u8, s, "length") or std.mem.eql(u8, s, "max_tokens")) break :blk .truncated;
            if (std.mem.eql(u8, s, "error")) {
                detail = if (last.err) |e| e else null;
                break :blk .unknown;
            }
            break :blk .unknown;
        }
        if (std.mem.eql(u8, last.role, "toolResult")) break :blk .running;
        if (std.mem.eql(u8, last.role, "user")) break :blk .running;
        break :blk .unknown;
    };
    return finishReport(alloc, state, detail, last.stop, msgs.len, pending);
}

/// De-noised pi transcript: one entry per message (pi already writes one record
/// per logical message, so no coalescing).
fn denoisePi(a: std.mem.Allocator, data: []const u8, include_thinking: bool) ![]const Entry {
    var out: std.ArrayList(Entry) = .empty;
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        const v = std.json.parseFromSliceLeaky(std.json.Value, a, line, .{}) catch continue;
        if (!std.mem.eql(u8, getStr(v, "type") orelse "", "message")) continue;
        const m = get(v, "message") orelse continue;
        const content = get(m, "content");
        const role = getStr(m, "role") orelse "";
        if (std.mem.eql(u8, role, "user")) {
            try out.append(a, .{ .role = .user, .text = try blockTextAlloc(a, content, "text", "text") });
        } else if (std.mem.eql(u8, role, "assistant")) {
            const text = try blockTextAlloc(a, content, "text", "text");
            const thinking = try blockTextAlloc(a, content, "thinking", "thinking");
            var tools: std.ArrayList(ToolCall) = .empty;
            if (content) |c| if (asArray(c)) |arr| {
                for (arr) |b| {
                    if (std.mem.eql(u8, getStr(b, "type") orelse "", "toolCall")) {
                        try tools.append(a, .{
                            .name = getStr(b, "name") orelse "",
                            .input_json = try valueToJson(a, get(b, "arguments")),
                        });
                    }
                }
            };
            const stop = getStr(m, "stopReason") orelse "";
            const err = getStr(m, "errorMessage") orelse "";
            const has_thinking = include_thinking and thinking.len > 0;
            if (text.len == 0 and tools.items.len == 0 and !has_thinking and err.len == 0 and stop.len == 0) continue;
            try out.append(a, .{
                .role = .assistant,
                .text = text,
                .thinking = if (has_thinking) thinking else "",
                .tools = tools.items,
                .stop_reason = stop,
                .err = err,
            });
        } else if (std.mem.eql(u8, role, "toolResult")) {
            const text = try blockTextAlloc(a, content, "text", "text");
            try out.append(a, .{
                .role = .tool,
                .tool_name = getStr(m, "toolName") orelse "",
                .tool_results = try a.dupe([]const u8, &.{try truncate(a, text, 280)}),
            });
        }
    }
    return out.toOwnedSlice(a);
}

// =========================================================================
// De-noised entry model + renderers
// =========================================================================

const Role = enum { user, assistant, tool };

const ToolCall = struct {
    name: []const u8,
    /// Tool input, already serialized to compact JSON.
    input_json: []const u8,
};

const Entry = struct {
    role: Role,
    text: []const u8 = "",
    thinking: []const u8 = "",
    tools: []const ToolCall = &.{},
    tool_results: []const []const u8 = &.{},
    tool_name: []const u8 = "",
    stop_reason: []const u8 = "",
    err: []const u8 = "",
};

fn renderJson(alloc: std.mem.Allocator, entries: []const Entry) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.append(alloc, '[');
    for (entries, 0..) |e, i| {
        if (i > 0) try out.append(alloc, ',');
        try out.appendSlice(alloc, "{\"role\":\"");
        try out.appendSlice(alloc, @tagName(e.role));
        try out.append(alloc, '"');
        switch (e.role) {
            .user => {
                try out.appendSlice(alloc, ",\"text\":");
                try appendJsonStr(alloc, &out, e.text);
            },
            .assistant => {
                if (e.text.len > 0) {
                    try out.appendSlice(alloc, ",\"text\":");
                    try appendJsonStr(alloc, &out, e.text);
                }
                if (e.thinking.len > 0) {
                    try out.appendSlice(alloc, ",\"thinking\":");
                    try appendJsonStr(alloc, &out, e.thinking);
                }
                if (e.tools.len > 0) {
                    try out.appendSlice(alloc, ",\"tools\":[");
                    for (e.tools, 0..) |t, j| {
                        if (j > 0) try out.append(alloc, ',');
                        try out.appendSlice(alloc, "{\"name\":");
                        try appendJsonStr(alloc, &out, t.name);
                        try out.appendSlice(alloc, ",\"input\":");
                        try out.appendSlice(alloc, if (t.input_json.len > 0) t.input_json else "null");
                        try out.append(alloc, '}');
                    }
                    try out.append(alloc, ']');
                }
                if (e.stop_reason.len > 0) {
                    try out.appendSlice(alloc, ",\"stop_reason\":");
                    try appendJsonStr(alloc, &out, e.stop_reason);
                }
                if (e.err.len > 0) {
                    try out.appendSlice(alloc, ",\"error\":");
                    try appendJsonStr(alloc, &out, e.err);
                }
            },
            .tool => {
                if (e.tool_name.len > 0) {
                    try out.appendSlice(alloc, ",\"tool\":");
                    try appendJsonStr(alloc, &out, e.tool_name);
                }
                try out.appendSlice(alloc, ",\"results\":[");
                for (e.tool_results, 0..) |r, j| {
                    if (j > 0) try out.append(alloc, ',');
                    try appendJsonStr(alloc, &out, r);
                }
                try out.append(alloc, ']');
            },
        }
        try out.append(alloc, '}');
    }
    try out.appendSlice(alloc, "]\n");
    return out.toOwnedSlice(alloc);
}

fn renderText(alloc: std.mem.Allocator, entries: []const Entry, include_thinking: bool) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (entries, 0..) |e, i| {
        if (i > 0) try out.append(alloc, '\n');
        switch (e.role) {
            .user => {
                try out.appendSlice(alloc, "user:\n");
                try appendIndented(alloc, &out, e.text);
            },
            .assistant => {
                try out.appendSlice(alloc, "assistant:\n");
                if (include_thinking and e.thinking.len > 0) {
                    try out.appendSlice(alloc, "  [thinking]\n");
                    try appendIndented(alloc, &out, e.thinking);
                }
                if (e.text.len > 0) try appendIndented(alloc, &out, e.text);
                for (e.tools) |t| {
                    try out.print(alloc, "  \u{2192} {s} ", .{t.name});
                    try appendTruncated(alloc, &out, t.input_json, 200);
                    try out.append(alloc, '\n');
                }
                if (e.err.len > 0) try out.print(alloc, "  (error: {s})\n", .{e.err});
                if (e.stop_reason.len > 0) try out.print(alloc, "  (stop: {s})\n", .{e.stop_reason});
            },
            .tool => {
                if (e.tool_name.len > 0)
                    try out.print(alloc, "tool[{s}]:\n", .{e.tool_name})
                else
                    try out.appendSlice(alloc, "tool:\n");
                for (e.tool_results) |r| try appendIndented(alloc, &out, r);
            },
        }
    }
    return out.toOwnedSlice(alloc);
}

fn appendIndented(alloc: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        try out.appendSlice(alloc, "  ");
        try out.appendSlice(alloc, line);
        try out.append(alloc, '\n');
    }
}

fn appendTruncated(alloc: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8, max: usize) !void {
    const flat = text;
    if (flat.len <= max) {
        try out.appendSlice(alloc, flat);
    } else {
        try out.appendSlice(alloc, flat[0..utf8Floor(flat, max)]);
        try out.appendSlice(alloc, "\u{2026}");
    }
}

// =========================================================================
// Shared helpers
// =========================================================================

/// Build a StateReport with owned (caller-alloc) strings from arena slices.
fn finishReport(
    alloc: std.mem.Allocator,
    state: SessionState,
    detail: ?[]const u8,
    stop_reason: ?[]const u8,
    messages: usize,
    pending_tools: []const []const u8,
) !StateReport {
    var report: StateReport = .{ .state = state, .messages = messages };
    errdefer report.deinit(alloc);
    if (detail) |d| report.detail = try alloc.dupe(u8, d);
    if (stop_reason) |s| report.stop_reason = try alloc.dupe(u8, s);
    if (pending_tools.len > 0) {
        const owned = try alloc.alloc([]const u8, pending_tools.len);
        for (pending_tools, 0..) |t, i| owned[i] = try alloc.dupe(u8, t);
        report.pending_tools = owned;
    }
    return report;
}

fn get(v: std.json.Value, key: []const u8) ?std.json.Value {
    return switch (v) {
        .object => |o| o.get(key),
        else => null,
    };
}

fn getStr(v: std.json.Value, key: []const u8) ?[]const u8 {
    const child = get(v, key) orelse return null;
    return switch (child) {
        .string => |s| s,
        else => null,
    };
}

fn asArray(v: std.json.Value) ?[]std.json.Value {
    return switch (v) {
        .array => |arr| arr.items,
        else => null,
    };
}

fn getArray(v: std.json.Value, key: []const u8) ?[]std.json.Value {
    const child = get(v, key) orelse return null;
    return asArray(child);
}

/// Concatenate the `field` of content blocks whose `type` == `kind`.
fn appendBlockText(
    a: std.mem.Allocator,
    out: *std.ArrayList(u8),
    content: std.json.Value,
    kind: []const u8,
    field: []const u8,
) !void {
    const arr = asArray(content) orelse {
        // A bare string content (claude user prompts) counts as text.
        if (std.mem.eql(u8, kind, "text")) switch (content) {
            .string => |s| {
                if (out.items.len > 0) try out.append(a, '\n');
                try out.appendSlice(a, s);
            },
            else => {},
        };
        return;
    };
    for (arr) |b| {
        if (std.mem.eql(u8, getStr(b, "type") orelse "", kind)) {
            if (getStr(b, field)) |s| {
                if (out.items.len > 0) try out.append(a, '\n');
                try out.appendSlice(a, s);
            }
        }
    }
}

fn blockTextAlloc(
    a: std.mem.Allocator,
    content: ?std.json.Value,
    kind: []const u8,
    field: []const u8,
) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    if (content) |c| try appendBlockText(a, &out, c, kind, field);
    return out.items;
}

/// A claude tool_result's `content` may be a string or arbitrary JSON.
fn contentToText(a: std.mem.Allocator, content: ?std.json.Value) ![]const u8 {
    const c = content orelse return "";
    return switch (c) {
        .string => |s| s,
        else => try valueToJson(a, c),
    };
}

/// Serialize a (possibly absent) JSON value to compact JSON text.
fn valueToJson(a: std.mem.Allocator, v: ?std.json.Value) ![]const u8 {
    const val = v orelse return "null";
    return std.json.Stringify.valueAlloc(a, val, .{});
}

fn truncate(a: std.mem.Allocator, s: []const u8, max: usize) ![]const u8 {
    if (s.len <= max) return s;
    const cut = utf8Floor(s, max);
    return std.fmt.allocPrint(a, "{s}\u{2026}", .{s[0..cut]});
}

/// Largest index <= max that is a UTF-8 boundary, so truncation never splits a
/// codepoint.
fn utf8Floor(s: []const u8, max: usize) usize {
    if (max >= s.len) return s.len;
    var i = max;
    while (i > 0 and (s[i] & 0xc0) == 0x80) i -= 1;
    return i;
}

fn appendJsonStr(alloc: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
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

/// Look up `--flag value` / `--flag=value` in an argv slice (last wins).
fn scanFlag(argv: []const []const u8, flag: []const u8) ?[]const u8 {
    var found: ?[]const u8 = null;
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], flag)) {
            if (i + 1 < argv.len) found = argv[i + 1];
        } else if (std.mem.startsWith(u8, argv[i], flag) and
            argv[i].len > flag.len and argv[i][flag.len] == '=')
        {
            found = argv[i][flag.len + 1 ..];
        }
    }
    return found;
}

fn containsStr(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |h| {
        if (std.mem.eql(u8, h, needle)) return true;
    }
    return false;
}

/// Mint a v4 UUID string (satisfies claude's --session-id and pi's id regex).
fn mintSessionId(alloc: std.mem.Allocator) ![]u8 {
    var bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant
    const hex = "0123456789abcdef";
    var buf: [36]u8 = undefined;
    var i: usize = 0;
    for (bytes, 0..) |b, bi| {
        if (bi == 4 or bi == 6 or bi == 8 or bi == 10) {
            buf[i] = '-';
            i += 1;
        }
        buf[i] = hex[b >> 4];
        buf[i + 1] = hex[b & 0x0f];
        i += 2;
    }
    return alloc.dupe(u8, buf[0..i]);
}

/// `$HOME/<sub>` (e.g. ".codex").
fn agentRoot(alloc: std.mem.Allocator, sub: []const u8) ![]u8 {
    const home = std.posix.getenv("HOME") orelse return error.NoHome;
    return std.fs.path.join(alloc, &.{ home, sub });
}

fn fileExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn dupeOpt(alloc: std.mem.Allocator, s: ?[]const u8) !?[]u8 {
    return if (s) |v| try alloc.dupe(u8, v) else null;
}

/// Deep-copy a string slice list into owned memory.
fn dupeArgv(alloc: std.mem.Allocator, items: []const []const u8) ![]const []const u8 {
    const out = try alloc.alloc([]const u8, items.len);
    errdefer alloc.free(out);
    var n: usize = 0;
    errdefer for (out[0..n]) |s| alloc.free(s);
    for (items, 0..) |s, i| {
        out[i] = try alloc.dupe(u8, s);
        n = i + 1;
    }
    return out;
}

fn dupeArgvList(alloc: std.mem.Allocator, items: []const []const u8) !std.ArrayList([]const u8) {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer freeArgvList(alloc, &list);
    for (items) |s| try list.append(alloc, try alloc.dupe(u8, s));
    return list;
}

/// `user_cmd` when non-empty, else `default`, as an owned mutable list.
fn baseArgv(
    alloc: std.mem.Allocator,
    user_cmd: []const []const u8,
    default: []const []const u8,
) !std.ArrayList([]const u8) {
    return dupeArgvList(alloc, if (user_cmd.len > 0) user_cmd else default);
}

fn freeArgv(alloc: std.mem.Allocator, argv: []const []const u8) void {
    for (argv) |s| alloc.free(s);
    alloc.free(argv);
}

fn freeArgvList(alloc: std.mem.Allocator, list: *std.ArrayList([]const u8)) void {
    for (list.items) |s| alloc.free(s);
    list.deinit(alloc);
}

// =========================================================================
// Tests
// =========================================================================

const testing = std.testing;
const real_codex = @embedFile("testdata/codex-rollout.real.jsonl");
const real_pi = @embedFile("testdata/pi-session.real.jsonl");

fn claudeRec(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, id: []const u8, stop: []const u8, block: []const u8) !void {
    try buf.print(alloc, "{{\"type\":\"assistant\",\"message\":{{\"id\":\"{s}\",\"role\":\"assistant\",\"stop_reason\":\"{s}\",\"content\":[{s}]}}}}", .{ id, stop, block });
}

test "agent registry resolves ids" {
    try testing.expectEqual(Agent.claude, Agent.fromId("claude").?);
    try testing.expectEqual(Agent.claude, Agent.fromId("claude-code").?);
    try testing.expectEqual(Agent.codex, Agent.fromId("codex").?);
    try testing.expectEqual(Agent.pi, Agent.fromId("pi").?);
    try testing.expectEqual(Agent.raw, Agent.fromId("raw").?);
    try testing.expectEqual(Agent.bash, Agent.fromId("bash").?);
    try testing.expect(Agent.fromId("nope") == null);
}

test "session state names and stopped set" {
    try testing.expectEqualStrings("waiting_for_input", SessionState.waiting_for_input.asStr());
    try testing.expect(SessionState.idle.isStopped());
    try testing.expect(!SessionState.running.isStopped());
    try testing.expect(!SessionState.unknown.isStopped());
}

test "prepare pins a claude session id and is reusable" {
    const alloc = testing.allocator;
    const p = try Agent.claude.prepare(alloc, &.{}, "/tmp/store");
    defer p.deinit(alloc);
    try testing.expectEqualStrings("claude", p.argv[0]);
    const sid = p.session_id.?;
    const pos = indexOfArg(p.argv, "--session-id").?;
    try testing.expectEqualStrings(sid, p.argv[pos + 1]);
    // v4 uuid: alphanumeric start/end.
    try testing.expect(std.ascii.isAlphanumeric(sid[0]));
    try testing.expect(std.ascii.isAlphanumeric(sid[sid.len - 1]));
}

test "prepare reuses an explicit claude session id" {
    const alloc = testing.allocator;
    const cmd = [_][]const u8{ "claude", "--session-id", "fixed-id" };
    const p = try Agent.claude.prepare(alloc, &cmd, "/tmp/store");
    defer p.deinit(alloc);
    try testing.expectEqualStrings("fixed-id", p.session_id.?);
    // not duplicated
    var count: usize = 0;
    for (p.argv) |a| {
        if (std.mem.eql(u8, a, "--session-id")) count += 1;
    }
    try testing.expectEqual(@as(usize, 1), count);
}

test "prepare pins pi session id and session-dir" {
    const alloc = testing.allocator;
    const p = try Agent.pi.prepare(alloc, &.{}, "/tmp/pistore");
    defer p.deinit(alloc);
    try testing.expect(p.session_id != null);
    const dpos = indexOfArg(p.argv, "--session-dir").?;
    try testing.expectEqualStrings("/tmp/pistore", p.argv[dpos + 1]);
    // interactive only — no print/rpc flags
    try testing.expect(indexOfArg(p.argv, "--print") == null);
    try testing.expect(indexOfArg(p.argv, "-p") == null);
    try testing.expect(indexOfArg(p.argv, "--mode") == null);
    // no injected --model (pi uses its configured defaults)
    try testing.expect(indexOfArg(p.argv, "--model") == null);
}

test "codex default command is the interactive tui" {
    const alloc = testing.allocator;
    const p = try Agent.codex.prepare(alloc, &.{}, "/tmp/store");
    defer p.deinit(alloc);
    try testing.expectEqualStrings("codex", p.argv[0]);
    try testing.expect(indexOfArg(p.argv, "exec") == null);
    try testing.expect(p.session_id == null);
}

test "bash payload runs as a shell command" {
    const alloc = testing.allocator;
    const cmd = [_][]const u8{ "echo", "hi" };
    const p = try Agent.bash.prepare(alloc, &cmd, "/tmp/store");
    defer p.deinit(alloc);
    try testing.expectEqual(@as(usize, 3), p.argv.len);
    try testing.expectEqualStrings("bash", p.argv[0]);
    try testing.expectEqualStrings("-lc", p.argv[1]);
    try testing.expectEqualStrings("echo hi", p.argv[2]);
}

fn indexOfArg(argv: []const []const u8, want: []const u8) ?usize {
    for (argv, 0..) |a, i| {
        if (std.mem.eql(u8, a, want)) return i;
    }
    return null;
}

// -- claude detect/dump ---------------------------------------------------

test "claude end_turn is idle" {
    const alloc = testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try claudeRec(&buf, alloc, "m1", "end_turn", "{\"type\":\"text\",\"text\":\"done\"}");
    var r = try Agent.claude.detect(alloc, buf.items);
    defer r.deinit(alloc);
    try testing.expectEqual(SessionState.idle, r.state);
}

test "claude unanswered AskUserQuestion waits with detail" {
    const alloc = testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try claudeRec(&buf, alloc, "m1", "tool_use", "{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"AskUserQuestion\",\"input\":{\"questions\":[{\"header\":\"A\",\"question\":\"Pick one?\"}]}}");
    var r = try Agent.claude.detect(alloc, buf.items);
    defer r.deinit(alloc);
    try testing.expectEqual(SessionState.waiting_for_input, r.state);
    try testing.expect(std.mem.indexOf(u8, r.detail.?, "Pick one?") != null);
}

test "claude answered question is running" {
    const alloc = testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try claudeRec(&buf, alloc, "m1", "tool_use", "{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"AskUserQuestion\",\"input\":{}}");
    try buf.append(alloc, '\n');
    try buf.appendSlice(alloc, "{\"type\":\"user\",\"toolUseResult\":{},\"message\":{\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"toolu_1\",\"content\":\"answered\"}]}}");
    var r = try Agent.claude.detect(alloc, buf.items);
    defer r.deinit(alloc);
    try testing.expectEqual(SessionState.running, r.state);
}

test "claude user prompt without reply is running" {
    const alloc = testing.allocator;
    const s = "{\"type\":\"user\",\"message\":{\"content\":\"do work\"}}";
    var r = try Agent.claude.detect(alloc, s);
    defer r.deinit(alloc);
    try testing.expectEqual(SessionState.running, r.state);
}

test "claude pending normal tool is running" {
    const alloc = testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try claudeRec(&buf, alloc, "m1", "tool_use", "{\"type\":\"tool_use\",\"id\":\"toolu_9\",\"name\":\"Bash\",\"input\":{}}");
    var r = try Agent.claude.detect(alloc, buf.items);
    defer r.deinit(alloc);
    try testing.expectEqual(SessionState.running, r.state);
    try testing.expectEqualStrings("Bash", r.pending_tools[0]);
}

test "claude empty and garbage are unknown" {
    const alloc = testing.allocator;
    var r1 = try Agent.claude.detect(alloc, "");
    defer r1.deinit(alloc);
    try testing.expectEqual(SessionState.unknown, r1.state);
    var r2 = try Agent.claude.detect(alloc, "not json\n{}\n");
    defer r2.deinit(alloc);
    try testing.expectEqual(SessionState.unknown, r2.state);
}

test "claude split message coalesces in dump" {
    const alloc = testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try claudeRec(&buf, alloc, "m1", "end_turn", "{\"type\":\"thinking\",\"thinking\":\"hmm\"}");
    try buf.append(alloc, '\n');
    try claudeRec(&buf, alloc, "m1", "end_turn", "{\"type\":\"text\",\"text\":\"Hello\"}");
    const dump = try Agent.claude.dumpJson(alloc, buf.items, false);
    defer alloc.free(dump);
    // one entry, text only, no thinking
    try testing.expect(std.mem.indexOf(u8, dump, "Hello") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "thinking") == null);
    try testing.expect(std.mem.indexOf(u8, dump, "hmm") == null);
    // exactly one object
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, dump, "\"role\":\"assistant\""));
}

test "claude gating tool detected across split records" {
    const alloc = testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try claudeRec(&buf, alloc, "m1", "tool_use", "{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"AskUserQuestion\",\"input\":{\"questions\":[{\"header\":\"H\",\"question\":\"Q?\"}]}}");
    try buf.append(alloc, '\n');
    try claudeRec(&buf, alloc, "m1", "tool_use", "{\"type\":\"text\",\"text\":\"choosing\"}");
    var r = try Agent.claude.detect(alloc, buf.items);
    defer r.deinit(alloc);
    try testing.expectEqual(SessionState.waiting_for_input, r.state);
}

test "claude trailing user prompt after end_turn is running" {
    // A human follow-up appended after a finished turn means the agent owes a
    // reply — it must not read as idle.
    const alloc = testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try claudeRec(&buf, alloc, "m1", "end_turn", "{\"type\":\"text\",\"text\":\"answer1\"}");
    try buf.append(alloc, '\n');
    try buf.appendSlice(alloc, "{\"type\":\"user\",\"message\":{\"content\":\"second question\"}}");
    var r = try Agent.claude.detect(alloc, buf.items);
    defer r.deinit(alloc);
    try testing.expectEqual(SessionState.running, r.state);
}

test "claude split message uses last non-null stop" {
    // A logical message split across records where the trailing block carries a
    // null stop_reason must still classify by the message's real terminator.
    const alloc = testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try claudeRec(&buf, alloc, "m1", "end_turn", "{\"type\":\"text\",\"text\":\"done\"}");
    try buf.append(alloc, '\n');
    try buf.appendSlice(alloc, "{\"type\":\"assistant\",\"message\":{\"id\":\"m1\",\"role\":\"assistant\",\"stop_reason\":null,\"content\":[{\"type\":\"text\",\"text\":\"more\"}]}}");
    var r = try Agent.claude.detect(alloc, buf.items);
    defer r.deinit(alloc);
    try testing.expectEqual(SessionState.idle, r.state);
}

test "claude max_tokens is truncated" {
    const alloc = testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try claudeRec(&buf, alloc, "m1", "max_tokens", "{\"type\":\"text\",\"text\":\"cut off\"}");
    var r = try Agent.claude.detect(alloc, buf.items);
    defer r.deinit(alloc);
    try testing.expectEqual(SessionState.truncated, r.state);
}

test "pi length stop is truncated" {
    const alloc = testing.allocator;
    const s = "{\"type\":\"message\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"cut\"}],\"stopReason\":\"length\"}}";
    var r = try Agent.pi.detect(alloc, s);
    defer r.deinit(alloc);
    try testing.expectEqual(SessionState.truncated, r.state);
}

// -- codex detect/dump (real fixture) -------------------------------------

test "codex fixture detects idle" {
    const alloc = testing.allocator;
    var r = try Agent.codex.detect(alloc, real_codex);
    defer r.deinit(alloc);
    try testing.expectEqual(SessionState.idle, r.state);
    try testing.expectEqualStrings("task_complete", r.stop_reason.?);
    try testing.expect(r.messages >= 2);
}

test "codex mid-turn detects running" {
    const alloc = testing.allocator;
    // Drop terminal task_complete/turn_aborted lines.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var it = std.mem.splitScalar(u8, real_codex, '\n');
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, "\"task_complete\"") != null) continue;
        if (std.mem.indexOf(u8, line, "\"turn_aborted\"") != null) continue;
        try buf.appendSlice(alloc, line);
        try buf.append(alloc, '\n');
    }
    var r = try Agent.codex.detect(alloc, buf.items);
    defer r.deinit(alloc);
    try testing.expectEqual(SessionState.running, r.state);
    try testing.expectEqualStrings("task_started", r.stop_reason.?);
}

test "codex empty and pre-turn are unknown not idle" {
    const alloc = testing.allocator;
    var r1 = try Agent.codex.detect(alloc, "");
    defer r1.deinit(alloc);
    try testing.expectEqual(SessionState.unknown, r1.state);
    // pre-turn slice (before task_started)
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var it = std.mem.splitScalar(u8, real_codex, '\n');
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, "\"task_started\"") != null) break;
        try buf.appendSlice(alloc, line);
        try buf.append(alloc, '\n');
    }
    var r2 = try Agent.codex.detect(alloc, buf.items);
    defer r2.deinit(alloc);
    try testing.expectEqual(SessionState.unknown, r2.state);
}

test "codex multi-turn reports running again" {
    const alloc = testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, real_codex);
    try buf.append(alloc, '\n');
    try buf.appendSlice(alloc, "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\",\"turn_id\":\"t2\"}}");
    var r = try Agent.codex.detect(alloc, buf.items);
    defer r.deinit(alloc);
    try testing.expectEqual(SessionState.running, r.state);
}

test "codex dump de-noises to user and assistant" {
    const alloc = testing.allocator;
    const dump = try Agent.codex.dumpJson(alloc, real_codex, false);
    defer alloc.free(dump);
    try testing.expect(std.mem.indexOf(u8, dump, "\"role\":\"user\"") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "\"role\":\"assistant\"") != null);
    // The fixture plants a synthetic developer marker that must not surface.
    try testing.expect(std.mem.indexOf(u8, dump, "SYNTHDEV_MARKER") == null);
}

// -- pi detect/dump (real fixture) ----------------------------------------

test "pi fixture detects idle" {
    const alloc = testing.allocator;
    var r = try Agent.pi.detect(alloc, real_pi);
    defer r.deinit(alloc);
    try testing.expectEqual(SessionState.idle, r.state);
    try testing.expectEqualStrings("stop", r.stop_reason.?);
    try testing.expect(r.messages >= 3);
}

test "pi missing file is unknown not idle" {
    const alloc = testing.allocator;
    var r = try Agent.pi.detect(alloc, "");
    defer r.deinit(alloc);
    try testing.expectEqual(SessionState.unknown, r.state);
    try testing.expect(r.state != .idle);
}

test "pi error is unknown not idle with detail" {
    const alloc = testing.allocator;
    const s = "{\"type\":\"message\",\"message\":{\"role\":\"assistant\",\"content\":[],\"stopReason\":\"error\",\"errorMessage\":\"403 denied\"}}";
    var r = try Agent.pi.detect(alloc, s);
    defer r.deinit(alloc);
    try testing.expectEqual(SessionState.unknown, r.state);
    try testing.expect(std.mem.indexOf(u8, r.detail.?, "403") != null);
}

test "pi toolUse is running" {
    const alloc = testing.allocator;
    const s = "{\"type\":\"message\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"toolCall\",\"name\":\"bash\"}],\"stopReason\":\"toolUse\"}}";
    var r = try Agent.pi.detect(alloc, s);
    defer r.deinit(alloc);
    try testing.expectEqual(SessionState.running, r.state);
    try testing.expectEqualStrings("bash", r.pending_tools[0]);
}

test "pi dump includes thinking only when requested" {
    const alloc = testing.allocator;
    const without = try Agent.pi.dumpJson(alloc, real_pi, false);
    defer alloc.free(without);
    try testing.expect(std.mem.indexOf(u8, without, "\"thinking\"") == null);
    const with = try Agent.pi.dumpJson(alloc, real_pi, true);
    defer alloc.free(with);
    try testing.expect(std.mem.indexOf(u8, with, "\"thinking\"") != null);
}

test "pi dump renders final reply and tool call" {
    const alloc = testing.allocator;
    const dump = try Agent.pi.dumpJson(alloc, real_pi, false);
    defer alloc.free(dump);
    try testing.expect(std.mem.indexOf(u8, dump, "echo hello-pi-fixture") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "\"role\":\"tool\"") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "DONE") != null);
}

test "pi dump text is human readable" {
    const alloc = testing.allocator;
    const text = try Agent.pi.dumpText(alloc, real_pi, false);
    defer alloc.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "user:") != null);
    try testing.expect(std.mem.indexOf(u8, text, "assistant:") != null);
}

// -- sidecar round trip ---------------------------------------------------

test "sidecar round trips through json" {
    const alloc = testing.allocator;
    const sc: Sidecar = .{
        .agent = .codex,
        .session_id = "abc-123",
        .session_store = "/tmp/store",
        .cwd = "/work",
    };
    const json = try sc.toJson(alloc);
    defer alloc.free(json);
    const back = try Sidecar.fromJson(alloc, json);
    defer back.deinit(alloc);
    try testing.expectEqual(Agent.codex, back.agent);
    try testing.expectEqualStrings("abc-123", back.session_id.?);
    try testing.expectEqualStrings("/tmp/store", back.session_store.?);
    try testing.expectEqualStrings("/work", back.cwd.?);
}

test "pi transcriptPath matches the session suffix and tolerates absence" {
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir);
    const sc: Sidecar = .{ .agent = .pi, .session_id = "abc-1", .session_store = dir };

    // Lazy no-file window → null.
    try testing.expect((try Agent.pi.transcriptPath(alloc, sc)) == null);
    // Another session's transcript must not match.
    try tmp.dir.writeFile(.{ .sub_path = "1700_other.jsonl", .data = "{}" });
    try testing.expect((try Agent.pi.transcriptPath(alloc, sc)) == null);
    // This session's transcript matches.
    try tmp.dir.writeFile(.{ .sub_path = "1700_abc-1.jsonl", .data = "{}" });
    const p = (try Agent.pi.transcriptPath(alloc, sc)).?;
    defer alloc.free(p);
    try testing.expect(std.mem.endsWith(u8, p, "1700_abc-1.jsonl"));
}

test "codex transcriptPath globs the rollout under the store, ignoring noise" {
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(home);
    const sc: Sidecar = .{ .agent = .codex, .session_store = home };

    // No rollout yet → null, no panic on a missing sessions/ tree.
    try testing.expect((try Agent.codex.transcriptPath(alloc, sc)) == null);
    try tmp.dir.makePath("sessions/2026/06/15");
    try tmp.dir.writeFile(.{ .sub_path = "sessions/2026/06/15/notes.txt", .data = "x" });
    try tmp.dir.writeFile(.{ .sub_path = "sessions/2026/06/15/rollout-1.jsonl", .data = "{}" });
    const p = (try Agent.codex.transcriptPath(alloc, sc)).?;
    defer alloc.free(p);
    try testing.expect(std.mem.endsWith(u8, p, "rollout-1.jsonl"));
}

test "scanFlag finds both spellings, last wins" {
    const a1 = [_][]const u8{ "pi", "--session-id", "x1" };
    try testing.expectEqualStrings("x1", scanFlag(&a1, "--session-id").?);
    const a2 = [_][]const u8{ "pi", "--session-id=y2" };
    try testing.expectEqualStrings("y2", scanFlag(&a2, "--session-id").?);
    const a3 = [_][]const u8{"pi"};
    try testing.expect(scanFlag(&a3, "--session-id") == null);
}

test "uuid is v4 shaped" {
    const alloc = testing.allocator;
    const id = try mintSessionId(alloc);
    defer alloc.free(id);
    try testing.expectEqual(@as(usize, 36), id.len);
    try testing.expectEqual(@as(u8, '4'), id[14]); // version nibble
    try testing.expectEqual(@as(u8, '-'), id[8]);
}
