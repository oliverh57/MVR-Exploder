#!/bin/bash
#
# Installs or updates LX File Exploder:
#
#   curl -fsSL https://raw.githubusercontent.com/oliverh57/MVR-Exploder/main/install.sh | bash
#
# Downloaded with curl, the app isn't quarantined, so macOS opens it without
# asking you to allow it in Privacy & Security.

set -euo pipefail

APP="LX File Exploder"
OLD_APP="MVR Exploder"   # the app's name before 1.8
ZIP_URL="https://github.com/oliverh57/MVR-Exploder/releases/latest/download/LX-File-Exploder.zip"
DEST="/Applications"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Downloading ${APP}..."
curl -fL --progress-bar "$ZIP_URL" -o "$TMP/app.zip"
ditto -x -k "$TMP/app.zip" "$TMP"
[[ -d "$TMP/$APP.app" ]] || { echo "The download didn't contain $APP.app." >&2; exit 1; }

running() { pgrep -xq "$APP" || pgrep -xq "$OLD_APP"; }
if running; then
  echo "Waiting for ${APP} to quit..."
  while running; do sleep 1; done
fi

rm -rf "$DEST/$APP.app" "$DEST/$OLD_APP.app"
ditto "$TMP/$APP.app" "$DEST/$APP.app"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DEST/$APP.app/Contents/Info.plist")"
echo "Installed $APP $VERSION in $DEST."
open "$DEST/$APP.app"
