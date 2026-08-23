#!/usr/bin/env bash
#
# Dev shortcut: build + launch with a sample file in one go.
#
# Usage:
#   ./dev-run.sh                        # opens samples/commonmark.md
#   ./dev-run.sh path/to/some.md        # opens whatever you pass
#
# Why this exists: launching from Xcode (Cmd+R) goes through an
# NSOpenPanel that on multi-monitor / non-frontmost-app setups can
# end up behind Xcode and look like "the app didn't open". Using
# `open -a APP file` ships the file to the app via an Apple Event,
# which skips the panel entirely and brings the doc window straight up.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET=""
if [ $# -gt 0 ]; then
  TARGET="$1"
  if [ ! -f "$TARGET" ]; then
    echo "❌ file not found: $TARGET" >&2
    exit 1
  fi
fi

cd "$REPO_ROOT"

# Make sure project is up-to-date (xcodegen is cheap; no-op if nothing changed).
if command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate >/dev/null
fi

echo "→ Building..."
xcodebuild \
  -project donemd.xcodeproj \
  -scheme donemd \
  -configuration Debug \
  -destination 'platform=macOS' \
  build 2>&1 | tail -3

# Wipe stale debug log so cat /tmp/donemd-debug.log is unambiguous.
rm -f /tmp/donemd-debug.log

# Kill any running instance so we know we're testing the just-built binary.
pkill -9 -f "donemd\.app/Contents/MacOS/donemd" 2>/dev/null || true
sleep 0.3

APP="$(ls -dt "$HOME/Library/Developer/Xcode/DerivedData/donemd-"*/Build/Products/Debug/*.app | head -1)"
echo "→ Launching: $APP"
if [ -n "$TARGET" ]; then
  echo "→ Opening:   $TARGET"
  open -a "$APP" "$TARGET"
else
  echo "→ Opening:   (no file — open dialog will appear)"
  open -a "$APP"
fi
