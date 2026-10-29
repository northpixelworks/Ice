#!/usr/bin/env bash
# Xcode registers every built Ice.app with Launch Services (and running the
# tests launches the Debug app, which registers it again), so build copies
# show up next to /Applications/Ice.app in Accessibility, Login Items and
# Open With. Run from the Ice scheme's build and test post-actions.
set -uo pipefail

LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
PRODUCTS_DIR="${BUILD_DIR:-${1:-}}"

[[ -n "$PRODUCTS_DIR" && -d "$PRODUCTS_DIR" ]] || exit 0

# Covers Ice.app in every configuration plus nested helpers (Sparkle's Updater.app).
find "$PRODUCTS_DIR" -type d -name '*.app' -print0 |
  xargs -0 -n 1 "$LSREGISTER" -u 2>/dev/null
exit 0
