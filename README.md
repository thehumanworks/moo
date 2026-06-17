<div align="center">
<pre>
 __  __   ___   ___ 
|  \/  | / _ \ / _ \
| |\/| || (_) | (_) |
|_|  |_||\___/ \___/ 

        \   ^__^
         \  (oo)\_______
            (__)\       )\/\
                ||----w |
                ||     ||
</pre>

Sessions that haunt your terminal.

</div>

A GNU `screen` style terminal multiplexer based on coder/boo, built on
libghostty
(`libghostty-vt`), written in Zig.

Every session's output is parsed through Ghostty's terminal emulation
core, so moo always knows the exact screen state of every session:
contents, styles, cursor, scrollback, and terminal modes. That state is
used to rehydrate your terminal on attach, to answer terminal queries
for detached sessions, and to let scripts and AI agents read the screen
exactly as a human would see it.

## Features

- Sessions that survive disconnects: detach with `Ctrl-A d`, reattach with `moo attach`.
- A full-screen session manager: `moo ui` lists sessions in a sidebar and resumes
  the same UI after a phone or SSH reconnect.
- Faithful redraws from libghostty terminal state, including SGR styles, cursor position, scrolling regions, window title, and terminal modes.
- Agent-friendly automation primitives: `send`, `peek`, `wait`, and `--json` output, all usable without a TTY.
- Coding-agent harnesses: `--agent claude|codex|pi` wraps an agent so `moo read` can de-noise its transcript and report whether it is idle, working, or waiting on you.

## Install

For Linux and macOS:

```sh
./install.sh
```

Pre-built binaries are published on the releases page. Set `MOO_VERSION` to pin a release and `MOO_INSTALL_DIR` to change the
install location (default: `/usr/local/bin` when writable, otherwise
`~/.local/bin`).

## Usage

```sh
moo new                    # new session running $SHELL, attached
moo new work               # named session
moo new work -d -- make    # create detached, running a command
moo ui                     # manage sessions in a resumable full-screen UI (alias: i)
moo ls                     # list sessions
moo attach work            # reattach (alias: at, a)
moo rename work api        # rename a session
moo kill work              # end a session
moo kill --all             # end every session
```

With no name, `moo new` names the session after the current directory,
falling back to the process id when that name is taken or unusable.

Run `moo help` for the full overview, `moo help <command>` for flags
and examples, and `moo help --all` to print every help page at once.

### Key bindings (prefix `Ctrl-a`)

Bindings follow GNU screen's defaults, including the `C-x` variants
(`C-a C-d` detaches just like `C-a d`).

| Keys      | Action                              |
|-----------|-------------------------------------|
| `C-a d`, `C-a C-d` | detach                     |
| `C-a l`, `C-a C-l` | redraw                     |
| `C-a a`   | send a literal `C-a`                |

`moo ui` adds additional keybinds for switching, resizing and hiding the sidebar, creating sessions, and killing them.

### Automation

Everything except `attach` works without a terminal, which makes moo a
natural sandbox for scripts and AI agents driving interactive programs.
The canonical loop:

```sh
moo new build -d -- bash               # 1. headless session
moo send build --text 'make' --enter   # 2. type into it
moo wait build --idle                  # 3. let output settle
moo peek build --scrollback            # 4. read the screen
moo kill build                         # 5. clean up
```

- **Reading state**: `peek` prints the rendered screen reconstructed
  from terminal state, not a raw byte log: ordered, fully redrawn, and
  stable. `--scrollback` includes history; `--json` adds size, cursor,
  and title.
- **Waiting**: `wait --text <text>` blocks until the screen contains
  the text; `wait --idle` until output has been quiet for 2 seconds;
  `--timeout <dur>` exits 4 instead of hanging forever (durations:
  `500ms`, `2s`, `1m`, `4h`, `1d`). No more sleep-and-poll loops.
- **Sending input**: `send --text` is literal: no escape processing, no
  implicit newline, no quoting layer to fight. `--enter` submits,
  `--key Enter,C-c,Up` names control keys, and stdin mode is binary
  safe.
- **Machine-readable output**: `ls --json` and `peek --json`.
- **Exit codes**: `0` success, `1` error, `2` usage error, `3` no such
  session, `4` wait timed out.

See `moo help automation` for the full page.

### Agents

moo can wrap a coding agent (Claude Code, `codex`, `pi`) so you can read its
*transcript*, not just its screen. `--agent` launches the agent's interactive
TUI, augments the command so the transcript is locatable (a pinned session id,
or an isolated home), and records a small sidecar next to the session socket.
`moo read` then turns that transcript into a de-noised conversation plus a
one-line status of what the agent is doing.

```sh
moo new bot --agent claude -d              # wrap Claude Code, detached
moo send bot --text 'fix the build' --enter
moo wait bot --idle                        # coarse wait: output settles
moo read bot                               # status + de-noised conversation
moo read bot --json | jq .state            # or structured, for scripts
moo kill bot                               # ends it; drops the sidecar
```

`wait --idle` watches the rendered screen and fires once output has been quiet
for two seconds, a convenient but coarse proxy. For an authoritative
turn-completion signal, poll the transcript state instead, e.g. until
`moo read bot --json | jq -r .state` reports `idle`.

- **Reading the transcript**: `read` classifies the session from the agent's
  own JSONL log, independent of what the TUI is drawing: `idle` (turn finished),
  `running` (generating or running tools), `waiting_for_input` (Claude asked via
  a native question/plan tool), `truncated`, or `unknown` (no transcript yet).
  The conversation is de-noised down to human prompts, agent replies, and tool
  calls; `--thinking` adds reasoning blocks; `--json` emits structured output.
- **Reading a saved log**: `moo read --agent <agent> <file>` de-noises any
  transcript file directly, no session required.

| capability          | claude | codex | pi  |
|---------------------|:------:|:-----:|:---:|
| read transcript     |  yes   |  yes  | yes |
| thinking blocks     |  yes   |  no   | yes |
| `waiting_for_input` |  yes   |  no   | no  |

Approvals and permission prompts that never reach disk read as `running` rather
than a dedicated waiting state. See `moo help agents` for the full page.

### Workspaces

A *workspace* is a named, isolated group of sessions. By default every
command shares one namespace; `-w/--workspace <name>` (or the
`MOO_WORKSPACE` environment variable) scopes a command to a workspace so it
sees only that workspace's sessions. Unrelated projects no longer collide:
the same session name can exist independently in two workspaces.

```sh
moo new api -w proj -d -- bash   # a session in the "proj" workspace
moo ls -w proj                   # list only "proj" sessions
moo new api -d -- bash           # a separate "api" in the default workspace
moo ws                           # all workspaces, with live session counts
moo kill --all -w proj           # end only "proj"; the default is untouched
```

Every session command takes `-w/--workspace` (`new`, `attach`, `ui`, `ls`,
`send`, `peek`, `read`, `wait`, `kill`, `rename`); both `-w proj` and
`--workspace=proj` work. The flag wins over `MOO_WORKSPACE`, which wins over
the default (unnamed) workspace.

- **Isolation by directory**: the socket directory is the default
  workspace, and a named workspace is just a `ws/<name>/` subdirectory of
  it (mode `0700`) with its own sockets. Because each command resolves a
  single directory, `ls`, `new`, and `kill --all` physically cannot see or
  touch another workspace's sessions.
- **Confining an orchestrator**: the daemon exports `MOO_WORKSPACE=<name>`
  into each workspace session's environment. A process running *inside* a
  workspace session inherits it, so every `moo` command that process runs
  is automatically confined to the same workspace. A coding agent driving
  moo from inside `proj` therefore cannot enumerate or kill sessions in
  other projects. A default (unnamed) session leaves `MOO_WORKSPACE` unset.

See `moo help workspaces` for the full page.

## Why moo?

GNU screen works the same way moo does, architecturally: it parses all
output through its own built-in terminal emulator and redraws from
that state on reattach. But that emulator is decades old and lags far
behind what modern programs emit. Whatever it doesn't understand gets
dropped or mangled on redraw. moo swaps that layer for `libghostty-vt`,
Ghostty's VT core, so the saved state matches what your terminal would
actually display, and terminal queries are answered while detached so
TUIs don't hang unattended.

Scripting is the other win: `send`, `peek --json`, and
`wait --text`/`--idle` instead of `-X stuff`, hardcopy files, and
sleep loops.

tmux is great, it just solves a different problem. moo keeps screen's
model by design: sessions, a prefix key, and nothing else to learn.
One session per task, with `moo ui` to juggle them.

## Contributing

Requires Zig 0.15.2.

```sh
zig build                       # binary in zig-out/bin/moo
zig build test                  # unit tests
zig build test-integration     # end-to-end tests on a real PTY
zig build test-all             # everything
```

The libghostty dependency is fetched and built from source
automatically (pinned in `build.zig.zon`).

The repo is laid out as a small monorepo:

```
packages/moo-cli/              # Zig persistence engine and CLI
apps/macos/MooDeck/            # SwiftUI macOS terminal workspace app
```

The root `build.zig` continues to build the CLI package. The macOS app can be
built and launched with `just app-run`, or verified with `just app-check`.

With Nix, `nix develop` opens a shell with the right Zig version, and
`nix build` builds the package to `./result/bin/moo`.

## Architecture

```
your terminal <-(raw tty)-> moo client <-(unix socket)-> session daemon
                                                         `- PTY + ghostty-vt Terminal
```

- The **client** puts your TTY in raw mode and shuttles bytes over a
  framed Unix-socket protocol (`packages/moo-cli/src/protocol.zig`).
- The **daemon** (forked on session creation) owns the session's
  command: a PTY-attached child whose output feeds a persistent
  `ghostty-vt` `TerminalStream` (`packages/moo-cli/src/window.zig`).
- While attached, output is passed through to your terminal byte for
  byte. On attach the daemon sanitizes your terminal and replays the
  screen from libghostty state using its VT `TerminalFormatter`.
- Terminal queries (DSR, DA, XTWINOPS, ...) while detached are answered
  by libghostty's stream handler; while attached your real terminal
  answers, avoiding double replies.

## Caveats

This is a young project, not a drop-in GNU screen replacement:

- One attached client per session (attaching steals); no `-x` sharing.
- One window per session: no splits or tabs inside a session. Run one
  session per task and juggle them with `moo ui`.
- The `C-a` prefix is not yet configurable, and pasted bytes containing
  `0x01` are interpreted as the prefix (GNU screen has the same quirk;
  `moo ui` is immune thanks to bracketed paste).
- Sessions run with `TERM=xterm-256color`.

## Support

Feel free to open an issue if you have questions, run into bugs, or have a feature request.

## License

MIT. Ghostty itself is MIT licensed.
