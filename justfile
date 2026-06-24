# moo task runner. Run `just` to list recipes.
#
# Builds go through `nix develop` so they use the pinned Zig 0.15.2 toolchain
# (the project requires 0.15.2; a host Zig 0.16 is rejected by ghostty) and Bun
# for the bundled MCP server. If you have native tools on PATH, override:
# `just zig=zig build`.
#
# `install` always re-signs the binary: on macOS, overwriting a previously-run
# binary invalidates its ad-hoc code signature and the kernel then kills it on
# exec ("Killed: 9" / exit 137). Re-signing keeps the installed copy runnable.

# Zig invocation (pinned toolchain via the flake dev shell).
zig := "nix develop --command zig"

# Where `install` puts the binary (override with MOO_INSTALL_DIR).
bindir := env_var_or_default("MOO_INSTALL_DIR", env_var("HOME") / ".local" / "bin")
binname := "moo"

# List available recipes.
default:
    @just --list

# Build the release binary to zig-out/bin/moo.
build: mcp-deps
    {{zig}} build -Doptimize=ReleaseSafe

# Build an unoptimized debug binary.
build-debug: mcp-deps
    {{zig}} build

# Install JavaScript workspace dependencies.
mcp-deps:
    bun install --frozen-lockfile

# Type-check the TypeScript MCP server.
mcp-typecheck: mcp-deps
    bun run typecheck

# Run MCP server unit tests.
mcp-test: mcp-deps
    bun run test:mcp

# Compile the MCP server executable with bun build --compile.
mcp-build: mcp-deps
    bun run build:mcp

# Run unit tests (no TTY required).
test:
    {{zig}} build test

# Run unit + PTY integration tests.
test-all:
    {{zig}} build test-all

# Check formatting without writing (CI parity).
fmt-check:
    {{zig}} fmt --check build.zig build.zig.zon packages/moo-cli/src packages/moo-cli/test packages/moo-cli/bench

# Apply formatting in place.
fmt:
    {{zig}} fmt build.zig build.zig.zon packages/moo-cli/src packages/moo-cli/test packages/moo-cli/bench

# Full local gate: format check + build + unit + PTY integration tests.
# This is the per-task "definition of done" check; mirrors what CI enforces.
check: fmt-check mcp-typecheck mcp-test build test-all

# Stricter gate under ReleaseSafe (CI runs this too); use before merge.
check-release: fmt-check mcp-typecheck mcp-test
    {{zig}} build test-all -Doptimize=ReleaseSafe

# Build and run moo, forwarding any extra args (e.g. `just run -- ls`).
run *args:
    {{zig}} build run -- {{args}}

# Build, install to {{bindir}}/{{binname}}, and ad-hoc re-sign so it runs.
install: build
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p "{{bindir}}"
    # Remove first: cp over a previously-run binary can leave a stale,
    # signature-invalid inode that macOS refuses to exec.
    rm -f "{{bindir}}/{{binname}}"
    cp zig-out/bin/moo "{{bindir}}/{{binname}}"
    chmod +x "{{bindir}}/{{binname}}"
    cp zig-out/bin/moo-mcp-server "{{bindir}}/moo-mcp-server"
    chmod +x "{{bindir}}/moo-mcp-server"
    if [ "$(uname)" = "Darwin" ]; then
        codesign --force --sign - "{{bindir}}/{{binname}}"
        codesign --force --sign - "{{bindir}}/moo-mcp-server"
    fi
    echo "installed: $("{{bindir}}/{{binname}}" version) -> {{bindir}}/{{binname}}"

# Re-sign the already-installed binary (macOS), without rebuilding.
sign:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ "$(uname)" = "Darwin" ]; then
        codesign --force --sign - "{{bindir}}/{{binname}}"
        if [ -f "{{bindir}}/moo-mcp-server" ]; then
            codesign --force --sign - "{{bindir}}/moo-mcp-server"
        fi
        echo "re-signed {{bindir}}/{{binname}}"
    else
        echo "codesign is macOS-only; nothing to do on $(uname)"
    fi

# Remove the installed binary.
uninstall:
    rm -f "{{bindir}}/{{binname}}"
    rm -f "{{bindir}}/moo-mcp-server"

# Remove build artifacts.
clean:
    rm -rf zig-out .zig-cache
