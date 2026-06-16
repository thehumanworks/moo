# moo task runner. Run `just` to list recipes.
#
# Builds go through `nix develop` so they use the pinned Zig 0.15.2 toolchain
# (the project requires 0.15.2; a host Zig 0.16 is rejected by ghostty). If you
# have a native Zig 0.15.2 on PATH, override: `just zig=zig build`.
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
build:
    {{zig}} build -Doptimize=ReleaseSafe

# Build an unoptimized debug binary.
build-debug:
    {{zig}} build

# Run unit tests (no TTY required).
test:
    {{zig}} build test

# Run unit + PTY integration tests.
test-all:
    {{zig}} build test-all

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
    if [ "$(uname)" = "Darwin" ]; then
        codesign --force --sign - "{{bindir}}/{{binname}}"
    fi
    echo "installed: $("{{bindir}}/{{binname}}" version) -> {{bindir}}/{{binname}}"

# Re-sign the already-installed binary (macOS), without rebuilding.
sign:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ "$(uname)" = "Darwin" ]; then
        codesign --force --sign - "{{bindir}}/{{binname}}"
        echo "re-signed {{bindir}}/{{binname}}"
    else
        echo "codesign is macOS-only; nothing to do on $(uname)"
    fi

# Remove the installed binary.
uninstall:
    rm -f "{{bindir}}/{{binname}}"

# Remove build artifacts.
clean:
    rm -rf zig-out .zig-cache
