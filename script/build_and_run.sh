#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="MooDeck"
BUNDLE_ID="dev.moo.MooDeck"
MIN_SYSTEM_VERSION="14.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PACKAGE="$ROOT_DIR/apps/macos/MooDeck"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode-beta.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
fi

usage() {
  echo "usage: $0 [run|--build-only|--verify|--debug|--logs|--telemetry]" >&2
}

build_moo_cli() {
  if command -v nix >/dev/null 2>&1; then
    (cd "$ROOT_DIR" && nix develop --command zig build)
  else
    (cd "$ROOT_DIR" && zig build)
  fi
}

build_app_bundle() {
  swift build --package-path "$APP_PACKAGE"
  local build_dir
  build_dir="$(swift build --package-path "$APP_PACKAGE" --show-bin-path)"
  local build_binary="$build_dir/$APP_NAME"

  rm -rf "$APP_BUNDLE"
  mkdir -p "$APP_MACOS" "$APP_CONTENTS/Resources"
  cp "$build_binary" "$APP_BINARY"
  chmod +x "$APP_BINARY"

  # Copy SwiftPM resource bundles (e.g. SwiftTerm's Metal shaders) next to the
  # executable so Bundle.module resolves them at runtime.
  for resource_bundle in "$build_dir"/*.bundle; do
    [ -e "$resource_bundle" ] || continue
    cp -R "$resource_bundle" "$APP_MACOS/"
  done

  cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

  if command -v codesign >/dev/null 2>&1; then
    codesign --force --sign - "$APP_BINARY" >/dev/null
  fi
}

open_app() {
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  /usr/bin/open -n "$APP_BUNDLE"
}

verify_running() {
  for _ in {1..30}; do
    if pgrep -x "$APP_NAME" >/dev/null; then
      echo "verified: $APP_NAME is running from $APP_BUNDLE"
      return 0
    fi
    sleep 0.5
  done

  echo "error: $APP_NAME did not start" >&2
  return 1
}

case "$MODE" in
  run|--build-only|build)
    build_moo_cli
    build_app_bundle
    if [[ "$MODE" != "--build-only" && "$MODE" != "build" ]]; then
      open_app
    fi
    ;;
  --verify|verify)
    build_moo_cli
    build_app_bundle
    open_app
    verify_running
    ;;
  --debug|debug)
    build_moo_cli
    build_app_bundle
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    build_moo_cli
    build_app_bundle
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    build_moo_cli
    build_app_bundle
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  *)
    usage
    exit 2
    ;;
esac
