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
    \\    slash <name> <cmd> [flags]   send an agent harness slash command
    \\    peek <name>                  print the session's screen
    \\    read <name>                  read an agent session's transcript
    \\    wait <name>                  block until output matches or settles
    \\
    \\  Administration
    \\    kill <name | --all>          end a session, or all of them
    \\    rename <name> <new-name>     rename a session
    \\    serve [--addr host:port]     expose the localhost REST API
    \\    mcp                          run the bundled stdio MCP server
    \\
    \\  Information
    \\    workspace [list|create|remove] list, create, or remove workspaces (alias: ws)
    \\    version                      print the version
    \\    help [page]                  this overview, or detailed help
    \\
    \\Run 'moo help <command>' for flags and examples, 'moo help keys'
    \\for the key bindings inside a session, 'moo help automation' for
    \\driving moo from scripts, 'moo help agents' for wrapping coding
    \\agents, 'moo help workspaces' for isolating sessions by project,
    \\or 'moo help --all' for every page.
    \\
    \\session selection:
    \\  Commands taking <name> accept a unique prefix of the session
    \\  name (e.g. 'moo attach bu' for "build").
    \\
    \\workspaces:
    \\  -w/--workspace <name> (or $MOO_WORKSPACE) scopes a command to a
    \\  named workspace whose sessions are isolated from every other
    \\  workspace's. See 'moo help workspaces'.
    \\
    \\environment:
    \\  MOO_DIR        socket directory
    \\                 (default: $XDG_RUNTIME_DIR/moo, else /tmp/moo-<uid>)
    \\  MOO_WORKSPACE  default workspace for commands run without -w;
    \\                 exported into each workspace session (see
    \\                 'moo help workspaces')
    \\  MOO_LOG        append daemon logs to this file (debugging)
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
        \\  -w, --workspace <name>
        \\                   create the session in a named workspace,
        \\                   isolated from sessions in other workspaces
        \\                   (see 'moo help workspaces')
        \\
        \\examples:
        \\  moo new                      interactive shell, attach now
        \\  moo new work                 named session
        \\  moo new build -d -- make -j  background a build
        \\  moo new bot --agent claude   wrap Claude Code, attach now
        \\  moo new cx -d --agent codex  background codex; read it later
        \\  moo new api -w proj -d -- bash   in the "proj" workspace
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
        \\flags:
        \\  -w, --workspace <name>   attach a session in a named
        \\                           workspace (see 'moo help workspaces')
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
        \\The UI manager is resumable: if a phone or SSH connection
        \\drops, running 'moo ui' again reconnects to the same focused
        \\session and sidebar state.
        \\
        \\flags:
        \\  -w, --workspace <name>   manage a named workspace's sessions
        \\                           (see 'moo help workspaces')
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
        \\  -w, --workspace <name>
        \\          list only the named workspace's sessions
        \\          (see 'moo help workspaces')
        \\
        ,
    },
    .{
        .name = "workspace",
        .alias = "ws",
        .body =
        \\usage: moo workspace [list|ls] [--json]
        \\       moo workspace create <name> [--cwd <path>]
        \\       moo workspace rm <workspace|@default>
        \\       moo workspace remove <workspace|@default>
        \\       moo workspace rm --all
        \\       moo ws ...                    short alias for workspace
        \\
        \\List, create, or remove workspaces. With no subcommand, 'moo workspace'
        \\behaves like 'moo workspace list': it lists every workspace and how many live
        \\sessions each holds. The default workspace (sessions created
        \\without -w) is listed first as "(default)", followed by every
        \\named workspace in name order. Each existing workspace appears
        \\even when its count is 0, so a workspace you created but later
        \\emptied is still visible.
        \\
        \\'moo workspace create <name>' creates a named workspace directory without
        \\starting a session. Optional --cwd sets the working directory for every
        \\session created in that workspace; the path is stored as an absolute
        \\path in .workspace.json after validation.
        \\
        \\'moo workspace rm <workspace>' terminates that workspace's sessions,
        \\stops its UI manager state, and removes the named workspace
        \\directory. Use '@default' to target the default workspace; the
        \\default runtime directory itself is left in place. 'moo workspace
        \\rm --all' performs the same cleanup for every workspace.
        \\
        \\Unlike the session commands, 'workspace' is global: it does not take a
        \\-w/--workspace flag and is unaffected by $MOO_WORKSPACE.
        \\
        \\flags:
        \\  --json  emit a JSON array: [{"workspace","sessions","cwd"?}], default
        \\          first. The default workspace is reported with the
        \\          empty-string name "" (a real workspace name can never
        \\          be empty), so scripts can distinguish it from a named
        \\          one without matching the "(default)" label. cwd is included
        \\          when configured for the workspace.
        \\
        \\examples:
        \\  moo workspace                a WORKSPACE / SESSIONS table
        \\  moo workspace create proj --cwd ~/src/myapp
        \\  moo workspace list --json | jq .   per-workspace counts, for scripts
        \\  moo workspace rm proj        remove one workspace
        \\  moo workspace remove --all   terminate and remove all workspaces
        \\
        ,
    },
    .{
        .name = "serve",
        .body =
        \\usage: moo serve [--addr <host:port>] [--token-env <name>]
        \\
        \\Start the v1 HTTP REST API for remote-safe automation of detached
        \\sessions. The server is localhost-first: the default address is
        \\127.0.0.1:0, and binding outside loopback requires bearer-token
        \\authentication through --token-env.
        \\
        \\The API reuses the same session daemons and libghostty-rendered
        \\terminal state as the CLI. It does not attach to sessions or steal
        \\interactive clients.
        \\
        \\workspace ids:
        \\  @default                  the default workspace
        \\  <name>                    a named workspace
        \\
        \\flags:
        \\  --addr <host:port>        bind address; default 127.0.0.1:0
        \\  --token-env <name>        environment variable containing the
        \\                            bearer token required for API requests
        \\
        \\examples:
        \\  moo serve
        \\  MOO_API_TOKEN=secret moo serve --addr 0.0.0.0:8765 --token-env MOO_API_TOKEN
        \\  curl http://127.0.0.1:8765/v1/health
        \\
        ,
    },
    .{
        .name = "mcp",
        .body =
        \\usage: moo mcp
        \\
        \\Run the bundled stdio MCP server. The server exposes moo's HTTP
        \\API endpoints as MCP tools using @modelcontextprotocol/sdk.
        \\
        \\If MOO_API_URL is set, the MCP server connects to that existing
        \\API instance and uses MOO_API_TOKEN as a bearer token when set.
        \\Otherwise it starts a private `moo serve --addr 127.0.0.1:0`
        \\child process and stops it when the MCP process exits.
        \\
        \\environment:
        \\  MOO_API_URL          use an already-running moo HTTP API
        \\  MOO_API_TOKEN        bearer token for MOO_API_URL
        \\  MOO_BIN              moo binary used when auto-starting the API
        \\  MOO_MCP_SERVER_BIN   override the bundled MCP server executable
        \\
        \\examples:
        \\  moo mcp
        \\  MOO_API_URL=http://127.0.0.1:8765 moo mcp
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
        \\processing and no quoting layer to fight. Enter is appended
        \\after --text by default (--no-enter to suppress). With neither
        \\--text nor --key, bytes are read from stdin (binary safe, NUL
        \\excluded; no implicit Enter).
        \\
        \\flags:
        \\  --text <text>  the text to type (Enter is appended by default)
        \\  --no-enter     do not append Enter after --text
        \\  --force        send even when unsubmitted prompt text is detected
        \\  --key <list>   send named keys, comma separated:
        \\                 Enter, Tab, Escape, Space, Backspace,
        \\                 Up, Down, Left, Right, Home, End, C-a..C-z.
        \\                 Cannot be combined with --text; use two calls.
        \\  --stdin        force reading from stdin
        \\  -w, --workspace <name>   target a session in a named workspace
        \\                 (see 'moo help workspaces')
        \\
        \\examples:
        \\  moo send build --text 'make test'           run a command
        \\  moo send build --text 'partial' --no-enter type without submitting
        \\  moo send build --key C-c                    interrupt it
        \\  printf 'y\n' | moo send build               pipe bytes in
        \\
        ,
    },
    .{
        .name = "slash",
        .body =
        \\usage: moo slash <name> <compact|clear|goal> [--prompt <text>] [--clear] [flags]
        \\
        \\Send an agent harness slash command into a session. The composed
        \\line is typed literally and Enter is appended automatically.
        \\
        \\commands:
        \\  compact [--prompt <text>]   send /compact or /compact <prompt>
        \\  clear                       send /clear
        \\  goal --prompt <text>        send /goal <prompt>
        \\  goal --clear                send /goal clear
        \\
        \\flags:
        \\  --prompt <text>  optional focus text (compact) or goal text (goal)
        \\  --clear          clear the current goal (goal only)
        \\  --force          send even when unsubmitted prompt text is detected
        \\  -w, --workspace <name>   target a session in a named workspace
        \\                 (see 'moo help workspaces')
        \\
        \\examples:
        \\  moo slash bot compact --prompt 'focus on tests'
        \\  moo slash bot clear
        \\  moo slash bot goal --prompt 'ship the feature'
        \\  moo slash bot goal --clear
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
        \\  -w, --workspace <name>   target a session in a named workspace
        \\                (see 'moo help workspaces')
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
        \\usage: moo read <name> [--agent <agent>] [--history|--current] [--json] [--thinking]
        \\       moo read --file <path> --agent <agent> [--json] [--thinking]
        \\
        \\Read a coding agent's transcript, de-noised: the human prompts,
        \\the agent's replies, and its tool calls, with injected and
        \\internal records dropped. Unlike 'peek' (which prints the
        \\rendered screen) this reads the agent's own JSONL log, so it is
        \\stable regardless of what the TUI is showing.
        \\
        \\With a session name, moo uses launch sidecars, run history,
        \\live process detection, and bounded transcript-store scans to
        \\find the active agent transcript. '--agent <agent>' is an
        \\explicit session override for handoffs or sessions not
        \\started with 'moo new --agent'.
        \\
        \\flags:
        \\  --json       emit structured JSON instead of text. Session
        \\               form: {"session","agent","state","messages",
        \\               "transcript":[...]}. File form: just the array.
        \\  --thinking   include the agent's reasoning blocks (omitted by
        \\               default; never available for codex)
        \\  --agent <a>  session form: force claude, codex, or pi
        \\               discovery. File form: transcript kind.
        \\  --history    include all known agent runs for the session
        \\  --current    include only the selected/current run
        \\  --file <p>   read a saved transcript file directly
        \\  -w, --workspace <name>   target a session in a named workspace
        \\               (see 'moo help workspaces')
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
        \\  moo read bot --agent codex   force Codex discovery
        \\  moo read bot --history --json  include handoff runs
        \\  moo read --file rollout.jsonl --agent codex   dump a saved log
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
        \\  -w, --workspace <name>   target a session in a named workspace
        \\                   (see 'moo help workspaces')
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
        \\flags:
        \\  -w, --workspace <name>   act within a named workspace; --all
        \\                           then ends only that workspace's
        \\                           sessions (see 'moo help workspaces')
        \\
        \\examples:
        \\  moo kill build
        \\  moo kill --all
        \\  moo kill --all -w proj   end only the "proj" workspace
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
        \\flags:
        \\  -w, --workspace <name>   rename a session in a named workspace
        \\                           (see 'moo help workspaces')
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
        \\session), 'automation' (driving moo from scripts and AI
        \\agents), 'agents' (wrapping coding agents), and 'workspaces'
        \\(isolating sessions by project). --all prints every page in
        \\one pass, which is handy for piping into a pager or for tools
        \\that want to learn the whole CLI in one call.
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
        \\  moo send build --text 'make'           # 2. type into it
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
        \\  send is literal: no escapes, no quoting layer. --text
        \\  appends Enter by default (--no-enter to suppress); --key
        \\  Enter,C-c,Up names control keys; stdin mode is binary safe.
        \\
        \\agent slash commands:
        \\  moo slash <name> compact [--prompt <text>]   /compact [prompt]
        \\  moo slash <name> clear                       /clear
        \\  moo slash <name> goal --prompt <text>        /goal <text>
        \\  moo slash <name> goal --clear                /goal clear
        \\  Enter is always appended. The HTTP API exposes the same
        \\  commands at POST .../sessions/{session}/slash.
        \\
        \\machine-readable output:
        \\  moo ls --json    [{"name","attached","idle_ms","title"}]
        \\  moo peek --json  {"session","title","rows","cols",
        \\                    "cursor":{"row","col"},"screen"}
        \\
        \\exit codes:
        \\  0 success    1 error    2 usage error
        \\  3 no such session       4 wait timed out
        \\  5 unsubmitted prompt text (use --force on send/slash)
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
        \\  moo send bot --text 'fix the build'
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
        \\    or saved log use 'moo read --file <path> --agent <agent>'.
        \\
        ,
    },
    .{
        .name = "workspaces",
        .body =
        \\Isolating sessions by project with workspaces
        \\
        \\A workspace is a named, isolated group of sessions. Without one,
        \\every 'moo' command shares a single default namespace; with one,
        \\commands see only that workspace's sessions. This keeps unrelated
        \\projects from colliding: the same session name (say "build") can
        \\exist independently in two workspaces, and 'ls', 'kill --all', and
        \\'new' in one workspace physically cannot see or touch the other.
        \\
        \\selecting a workspace:
        \\  -w, --workspace <name>   scope this command to <name>
        \\  $MOO_WORKSPACE           default workspace when -w is absent
        \\
        \\  The flag wins; otherwise $MOO_WORKSPACE is used; with neither,
        \\  the command targets the default (unnamed) workspace, exactly as
        \\  moo behaved before workspaces existed. Both spellings (-w,
        \\  --workspace) and both forms (-w proj, --workspace=proj) work.
        \\  Every session command accepts it: new, attach, ui, ls, send,
        \\  peek, read, wait, kill, rename. The 'workspace' command itself
        \\  is global and takes no -w.
        \\
        \\  Workspace names use the same character set as session names:
        \\  letters, digits, '.', '_', '-', no leading '.' or '-'. An
        \\  invalid name is a usage error (exit 2).
        \\
        \\listing and removing them:
        \\  moo workspace                a WORKSPACE / SESSIONS table, default first
        \\  moo workspace list --json    [{"workspace","sessions"}]; default is ""
        \\  moo workspace rm proj        terminate sessions and remove proj
        \\  moo workspace remove --all   terminate and remove every workspace
        \\
        \\on disk:
        \\  The socket directory ($MOO_DIR, else $XDG_RUNTIME_DIR/moo, else
        \\  /tmp/moo-<uid>) is the default workspace. A named workspace is
        \\  just a subdirectory of it, "<dir>/ws/<name>" (mode 0700), with
        \\  its own sockets. Default (unnamed) sessions stay at the top
        \\  level, untouched. Isolation is structural: each command resolves
        \\  one directory and looks no further.
        \\
        \\confining an orchestrator:
        \\  When a session belongs to a workspace, the daemon exports
        \\  MOO_WORKSPACE=<name> into that session's environment. So a
        \\  process running inside the session inherits it, and every 'moo'
        \\  command that process runs is automatically confined to the same
        \\  workspace. A coding agent driving moo from inside a workspace
        \\  session therefore cannot enumerate or kill sessions belonging to
        \\  other projects. A default (unnamed) session leaves MOO_WORKSPACE
        \\  unset.
        \\
        \\example:
        \\  moo new api -w proj -d -- bash   # a session in "proj"
        \\  moo ls -w proj                   # only "proj" sessions
        \\  moo new api -d -- bash           # a separate "api" in default
        \\  moo workspace                    # see both, with counts
        \\  moo kill --all -w proj           # end only "proj"
        \\  moo workspace rm --all           # end and remove all workspaces
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
