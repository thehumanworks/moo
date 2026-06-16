//! All user-facing help text: the overview, per-command help, and
//! topic pages. Kept in one place so the CLI surface reads as a whole
//! and stays consistent.

pub const Entry = struct {
    /// Primary command or topic name.
    name: []const u8,
    /// Optional short alias (e.g. `at` for `attach`).
    alias: ?[]const u8 = null,
    /// Full help text printed by `moo help <name>`.
    body: []const u8,
};

pub const overview =
    \\moo: sessions that haunt your terminal
    \\
    \\A terminal multiplexer in the spirit of GNU screen, built on
    \\libghostty. Sessions keep running when you disconnect; reattach
    \\and the screen, scrollback, and title come back exactly as a
    \\human would see them.
    \\
    \\usage:
    \\  moo <command> [arguments]
    \\
    \\commands:
    \\
    \\  Session Management
    \\    new [name] [-d] [--agent <a>] [-- cmd...]
    \\                                 start a session (attach unless -d)
    \\    attach, at, a <name>         attach a session (steals politely)
    \\    ui, i                        manage sessions in a full-screen UI
    \\    ls [--json]                  list sessions
    \\
    \\  Interaction
    \\    send <name> [flags]          type into a session
    \\    peek <name>                  print the session's screen
    \\    read <name>                  read an agent session's transcript
    \\    wait <name>                  block until output matches or settles
    \\
    \\  Administration
    \\    kill <name | --all>          end a session, or all of them
    \\    rename <name> <new-name>     rename a session
    \\
    \\  Information
    \\    version                      print the version
    \\    help [page]                  this overview, or detailed help
    \\
    \\Run 'moo help <command>' for flags and examples, 'moo help keys'
    \\for the key bindings inside a session, 'moo help automation' for
    \\driving moo from scripts, 'moo help agents' for wrapping coding
    \\agents, or 'moo help --all' for every page.
    \\
    \\session selection:
    \\  Commands taking <name> accept a unique prefix of the session
    \\  name (e.g. 'moo attach bu' for "build").
    \\
    \\environment:
    \\  MOO_DIR  socket directory
    \\           (default: $XDG_RUNTIME_DIR/moo, else /tmp/moo-<uid>)
    \\  MOO_LOG  append daemon logs to this file (debugging)
    \\
;

pub const commands = [_]Entry{
    .{
        .name = "new",
        .body =
        \\usage: moo new [name] [-d|--detached] [--agent <agent>] [-- cmd...]
        \\
        \\Start a session running cmd (default: $SHELL) and attach to
        \\it. The session keeps running after you detach (C-a d) or
        \\lose the connection.
        \\
        \\Names may contain letters, digits, '.', '_', and '-'. The
        \\default name is the name of the current directory, or the
        \\process id when that name is taken or unusable. Everything
        \\after '--' is the command to run in the session.
        \\
        \\flags:
        \\  -d, --detached   start without attaching and print the
        \\                   session name on stdout
        \\  --agent <agent>  wrap a coding agent so its transcript can be
        \\                   read with 'moo read'. One of: claude, codex,
        \\                   pi, raw, bash, zsh. The launch command is
        \\                   augmented (e.g. a pinned session id) and a
        \\                   sidecar records where the transcript lives.
        \\                   A command after '--' overrides the default.
        \\
        \\examples:
        \\  moo new                      interactive shell, attach now
        \\  moo new work                 named session
        \\  moo new build -d -- make -j  background a build
        \\  moo new bot --agent claude   wrap Claude Code, attach now
        \\  moo new cx -d --agent codex  background codex; read it later
        \\
        ,
    },
    .{
        .name = "attach",
        .alias = "at",
        .body =
        \\usage: moo attach <name>
        \\       moo at <name>
        \\       moo a <name>
        \\
        \\Attach this terminal to a session. The screen, scrollback,
        \\cursor, and title are restored from terminal state. If the
        \\session is attached elsewhere, the other client is detached
        \\(the session is stolen).
        \\
        \\A unique prefix of the name is accepted.
        \\
        \\Inside the session, press C-a d to detach. See 'moo help
        \\keys' for all bindings.
        \\
        \\examples:
        \\  moo attach build     reattach "build"
        \\  moo at bu            the same, by prefix
        \\
        ,
    },
    .{
        .name = "ui",
        .alias = "i",
        .body =
        \\usage: moo ui
        \\       moo i
        \\
        \\Manage sessions in a full-screen interface: a sidebar lists
        \\every session (window title underneath) and the focused
        \\session runs in a viewport on the right, rendered live from
        \\terminal state.
        \\
        \\mouse:
        \\  click a session     focus it (steals politely, like attach)
        \\  click its 'x'       kill it (asks for confirmation)
        \\  scroll the sidebar  scroll the session list
        \\  wheel in viewport   scroll the session's history; wheel
        \\                      back down or press esc to return to
        \\                      live output (full-screen applications
        \\                      receive arrow keys instead)
        \\  in the viewport     forwarded to the application when it
        \\                      asked for mouse reporting; otherwise
        \\                      dragging selects text and copies it on
        \\                      release (OSC 52)
        \\
        \\keys (prefix C-a, control variants match GNU screen):
        \\  C-a c   create a session and focus it
        \\  C-a k   kill the focused session (asks y/n)
        \\  C-a r   rename the focused session
        \\  C-a g   go to a session by name (best match)
        \\  C-a n   focus the next session
        \\  C-a p   focus the previous session
        \\  C-a Up, C-a Down
        \\          browse the session list without attaching:
        \\          Up/Down move the selection, Enter attaches it,
        \\          Esc returns to the focused session
        \\  C-a Left, C-a Right
        \\          resize the sidebar: Left/Right adjust the width,
        \\          Enter keeps it, Esc restores the previous width
        \\  C-a s   show or hide the sidebar; the viewport takes the
        \\          full width while it is hidden
        \\  C-a C-a focus the previously focused session
        \\  C-a d   quit the UI (sessions keep running)
        \\  C-a l   redraw
        \\  C-a a   send a literal C-a to the application
        \\  C-a Esc cancel the armed prefix
        \\
        \\Pressing C-a alone lists these bindings in the bottom bar.
        \\
        \\Everything else is typed into the focused session. Unlike a
        \\plain attach, pasted text may contain C-a bytes safely
        \\(bracketed paste).
        \\
        ,
    },
    .{
        .name = "ls",
        .alias = "list",
        .body =
        \\usage: moo ls [--json]
        \\
        \\List sessions: name, attach state, idle time (time since the
        \\last output or client input), and the session's title. Stale
        \\sockets left by crashed daemons are cleaned up.
        \\
        \\flags:
        \\  --json  emit a JSON array:
        \\          [{"name","attached","idle_ms","title"}]
        \\
        ,
    },
    .{
        .name = "send",
        .body =
        \\usage: moo send <name> [--text <text>] [--key <list>] [flags]
        \\
        \\Type into a session, exactly as if the text had been typed
        \\at the keyboard. --text is sent literally: no escape
        \\processing and no implicit newline, so there is never a
        \\quoting layer to fight. With neither --text nor --key,
        \\bytes are read from stdin (binary safe, NUL excluded).
        \\
        \\flags:
        \\  --text <text>  the text to type
        \\  --enter        append Enter after everything else
        \\  --key <list>   send named keys, comma separated:
        \\                 Enter, Tab, Escape, Space, Backspace,
        \\                 Up, Down, Left, Right, Home, End, C-a..C-z.
        \\                 Cannot be combined with --text; use two calls.
        \\  --stdin        force reading from stdin
        \\
        \\examples:
        \\  moo send build --text 'make test' --enter   run a command
        \\  moo send build --key C-c                    interrupt it
        \\  printf 'y\n' | moo send build               pipe bytes in
        \\
        ,
    },
    .{
        .name = "peek",
        .body =
        \\usage: moo peek <name> [--scrollback] [--json]
        \\
        \\Print the session's rendered screen: what a human attached
        \\right now would see, reconstructed from terminal state (not
        \\a raw byte log). Safe to run while attached.
        \\
        \\flags:
        \\  --scrollback  include the full scrollback history
        \\  --json        emit {"session","title","rows","cols",
        \\                "cursor":{"row","col"},"screen"}
        \\
        \\examples:
        \\  moo peek build | tail -20
        \\  moo peek build --scrollback | grep -n error
        \\
        ,
    },
    .{
        .name = "read",
        .body =
        \\usage: moo read <name> [--json] [--thinking]
        \\       moo read --agent <agent> <file> [--json] [--thinking]
        \\
        \\Read a coding agent's transcript, de-noised: the human prompts,
        \\the agent's replies, and its tool calls, with injected and
        \\internal records dropped. Unlike 'peek' (which prints the
        \\rendered screen) this reads the agent's own JSONL log, so it is
        \\stable regardless of what the TUI is showing.
        \\
        \\With a session name, the session must have been started with
        \\'--agent'; a one-line status header reports what the agent is
        \\doing (idle, running, waiting_for_input, ...). With '--agent
        \\<agent>' and a file path, any saved transcript is de-noised
        \\directly, no session required.
        \\
        \\flags:
        \\  --json       emit structured JSON instead of text. Session
        \\               form: {"session","agent","state","messages",
        \\               "transcript":[...]}. File form: just the array.
        \\  --thinking   include the agent's reasoning blocks (omitted by
        \\               default; never available for codex)
        \\  --agent <a>  read a transcript file directly (claude, codex,
        \\               pi); pass the path positionally or via --file
        \\  --file <p>   the transcript file (alternative to positional)
        \\
        \\Agent state is read from the transcript, so a permission or
        \\approval prompt that never reaches disk reads as 'running'.
        \\Only Claude's native question/plan tools surface as
        \\'waiting_for_input'. See 'moo help agents'.
        \\
        \\examples:
        \\  moo read bot                 status + conversation, as text
        \\  moo read bot --json | jq .   structured, for scripts
        \\  moo read cx --thinking       include reasoning
        \\  moo read --agent codex rollout.jsonl   dump a saved log
        \\
        ,
    },
    .{
        .name = "wait",
        .body =
        \\usage: moo wait <name> (--text <text> | --idle) [--timeout <dur>]
        \\
        \\Block until something happens in the session, then exit 0.
        \\Replaces sleep-and-poll loops in scripts.
        \\
        \\flags:
        \\  --text <text>    until the rendered screen contains <text>
        \\                   (plain substring match)
        \\  --idle           until the session has produced no output
        \\                   for 2 seconds
        \\  --timeout <dur>  give up and exit 4 (default: 30s)
        \\
        \\Durations are an integer with a unit: 500ms, 2s, 1m, 4h
        \\(or 4hr), 1d. Flags also accept --flag=value.
        \\
        \\examples:
        \\  moo wait build --text 'PASS' --timeout 2m
        \\  moo wait build --idle && moo peek build
        \\
        ,
    },
    .{
        .name = "kill",
        .body =
        \\usage: moo kill <name | --all>
        \\
        \\End a session: its process receives SIGHUP and the daemon
        \\exits. --all ends every session and sweeps stale sockets.
        \\
        \\examples:
        \\  moo kill build
        \\  moo kill --all
        \\
        ,
    },
    .{
        .name = "rename",
        .body =
        \\usage: moo rename <name> <new-name>
        \\
        \\Rename a session. The running program is unaffected and an
        \\attached client stays attached. The old name accepts a
        \\unique prefix, like attach.
        \\
        \\example:
        \\  moo rename work api-server
        \\
        ,
    },
    .{
        .name = "version",
        .body =
        \\usage: moo version
        \\
        \\Print the moo version. Also available as -V or --version.
        \\
        ,
    },
    .{
        .name = "help",
        .body =
        \\usage: moo help [page] [--all]
        \\
        \\Show the overview or a detailed page. There is a page for
        \\every command, plus 'keys' (the C-a bindings inside a
        \\session) and 'automation' (driving moo from scripts and AI
        \\agents). --all prints every page in one pass, which is handy
        \\for piping into a pager or for tools that want to learn the
        \\whole CLI in one call.
        \\
        ,
    },
};

pub const topics = [_]Entry{
    .{
        .name = "keys",
        .body =
        \\Key bindings inside an attached session (prefix C-a)
        \\
        \\  C-a d   detach
        \\  C-a l   redraw
        \\  C-a a   send a literal C-a
        \\
        \\Control variants match GNU screen: C-a C-d detaches and
        \\C-a C-l redraws. Detaching leaves the session running;
        \\'moo attach' brings it back.
        \\
        \\'moo ui' adds bindings for managing sessions; see
        \\'moo help ui'.
        \\
        ,
    },
    .{
        .name = "automation",
        .body =
        \\Driving moo from scripts and AI agents
        \\
        \\Everything except 'attach' works without a terminal. The
        \\canonical loop:
        \\
        \\  moo new build -d -- bash               # 1. headless session
        \\  moo send build --text 'make' --enter   # 2. type into it
        \\  moo wait build --idle                  # 3. let output settle
        \\  moo peek build --scrollback            # 4. read the screen
        \\  moo kill build                         # 5. clean up
        \\
        \\reading state:
        \\  peek prints the rendered screen, not a raw byte stream:
        \\  ordered, fully redrawn, and stable. --scrollback includes
        \\  history; --json adds size, cursor, and title.
        \\
        \\waiting (instead of sleep):
        \\  moo wait <name> --text <text>   screen contains <text>
        \\  moo wait <name> --idle          output quiet for 2 seconds
        \\  moo wait <name> ... --timeout <dur>   exit 4 on timeout
        \\
        \\sending input:
        \\  send is literal: no escapes, no implicit newline, no
        \\  quoting layer. --enter submits; --key Enter,C-c,Up names
        \\  control keys; stdin mode is binary safe.
        \\
        \\machine-readable output:
        \\  moo ls --json    [{"name","attached","idle_ms","title"}]
        \\  moo peek --json  {"session","title","rows","cols",
        \\                    "cursor":{"row","col"},"screen"}
        \\
        \\exit codes:
        \\  0 success    1 error    2 usage error
        \\  3 no such session       4 wait timed out
        \\
        \\tips:
        \\  - Sessions are cheap; use one session per task.
        \\  - 'moo new -d' prints the session name on stdout.
        \\  - Pick unique session names so [name] prefixes stay
        \\    unambiguous.
        \\
        ,
    },
    .{
        .name = "agents",
        .body =
        \\Wrapping coding agents
        \\
        \\moo can run any program, but coding agents (Claude Code, codex,
        \\pi) each keep a structured JSONL transcript on disk. '--agent'
        \\launches one so moo knows where that transcript is, and 'moo
        \\read' turns it into a de-noised conversation plus a one-line
        \\status of what the agent is doing.
        \\
        \\  moo new bot --agent claude -d   # 1. wrap Claude Code
        \\  moo send bot --text 'fix the build' --enter
        \\  moo wait bot --idle             # 2. coarse wait: output settles
        \\  moo read bot                    # 3. read the conversation
        \\  moo kill bot                    # 4. clean up (drops sidecar)
        \\
        \\'wait --idle' watches the screen (output quiet for 2s), a coarse
        \\proxy. For an authoritative turn-complete signal, poll the
        \\transcript state until 'moo read <name> --json' reports
        \\state "idle".
        \\
        \\what --agent does:
        \\  - augments the launch command so the transcript is locatable
        \\    (claude/pi get a pinned --session-id; codex gets a private
        \\    CODEX_HOME so its rollout is unambiguous)
        \\  - writes a sidecar beside the socket ("<name>.agent") and an
        \\    isolated store ("<name>.store") where needed; both are
        \\    removed by 'moo kill'
        \\  - a command after '--' overrides the agent's default; the
        \\    interactive TUI is always launched (never a one-shot mode)
        \\
        \\read states (from the transcript):
        \\  idle               turn finished, sitting at the prompt
        \\  running            generating a reply or running tools
        \\  waiting_for_input  Claude asked via a native question/plan
        \\                     tool (Claude only)
        \\  truncated          last turn hit the token cap
        \\  unknown            no transcript yet, or not classifiable
        \\
        \\capability matrix:
        \\                      claude   codex   pi
        \\  read transcript       yes     yes    yes
        \\  thinking blocks       yes     no     yes
        \\  waiting_for_input     yes     no     no
        \\
        \\limitations:
        \\  - Permission/approval prompts that never reach disk read as
        \\    'running', not a waiting state (true for all three).
        \\  - codex encrypts its reasoning, so --thinking is a no-op there.
        \\  - 'moo read <name>' needs a live session; to read a finished
        \\    or saved log use 'moo read --agent <agent> <file>'.
        \\
        ,
    },
};

pub fn find(name: []const u8) ?*const Entry {
    const eql = @import("std").mem.eql;
    for (&commands) |*entry| {
        if (eql(u8, entry.name, name)) return entry;
        if (entry.alias) |alias| {
            if (eql(u8, alias, name)) return entry;
        }
    }
    for (&topics) |*entry| {
        if (eql(u8, entry.name, name)) return entry;
    }
    return null;
}
