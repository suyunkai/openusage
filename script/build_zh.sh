#!/usr/bin/env bash
# Builds this fork (Chinese localization + Claude Code CLI login) as the real OpenUsage bundle id, so it
# keeps the installed app's settings and accounts, with no Sparkle feed (never auto-updates) and no
# telemetry. Signs with a stable local identity so Keychain "Always Allow" survives rebuilds.
#
# Usage: script/build_zh.sh            # build dist/OpenUsage.app
#        script/build_zh.sh install    # build, back up /Applications/OpenUsage.app once, replace, launch
# Env:   CODESIGN_IDENTITY  defaults to "OpenUsage Local Signing" when that certificate exists
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-build}"

if [ -z "${CODESIGN_IDENTITY:-}" ] && /usr/bin/security find-certificate -c "OpenUsage Local Signing" >/dev/null 2>&1; then
  export CODESIGN_IDENTITY="OpenUsage Local Signing"
fi
# Without Xcode the SwiftUI macro plugins are missing; build KeyboardShortcuts from a patched, editable copy.
if [ ! -d "$(xcode-select -p 2>/dev/null)/Platforms" ]; then
  ( cd "$ROOT_DIR"
    [ -d Packages/KeyboardShortcuts ] || swift package edit KeyboardShortcuts
    python3 script/patch_deps_for_clt.py Packages/KeyboardShortcuts
    git checkout -q -- Package.resolved 2>/dev/null || true )
fi
export BUNDLE_ID="com.robinebers.openusage"
export SIGN_ENTITLEMENTS="$ROOT_DIR/script/OpenUsage.zh.entitlements.plist"
export APP_VERSION="${APP_VERSION:-0.8.0-zh ($(git -C "$ROOT_DIR" rev-parse --short HEAD))}"
"$ROOT_DIR/script/build_and_run.sh" build

if [ "$MODE" = "install" ]; then
  APP="/Applications/OpenUsage.app"
  BACKUP="/Applications/OpenUsage-0.8.0-official.app"
  osascript -e 'tell application id "com.robinebers.openusage" to quit' >/dev/null 2>&1 || true
  pkill -x OpenUsage >/dev/null 2>&1 || true
  sleep 1
  if [ -d "$APP" ] && [ ! -d "$BACKUP" ]; then
    echo "==> backing up the installed app to $BACKUP"
    mv "$APP" "$BACKUP"
  else
    rm -rf "$APP"
  fi
  ditto "$ROOT_DIR/dist/OpenUsage.app" "$APP"
  xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
  open "$APP"
  echo "==> installed $APP"
fi
