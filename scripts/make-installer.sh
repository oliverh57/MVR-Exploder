#!/bin/zsh
#
# Builds MVR Exploder and packages it as a DMG for distribution.
#
#   ./scripts/make-installer.sh            → dist/MVR Exploder 1.1.dmg
#   ./scripts/make-installer.sh 1.2-beta   → dist/MVR Exploder 1.2-beta.dmg
#
# The DMG holds the app, a symlink to /Applications to drag it onto, and a
# read-me. There is no .pkg: a drag-install is the macOS convention for an
# app with no privileged components, and a pkg would add an unsigned
# installer to get past on top of the unsigned app.
#
# NOT SIGNED OR NOTARISED. There is no Developer ID certificate on this
# machine, so the app is ad-hoc signed and Gatekeeper will refuse to open
# it on another Mac until the user allows it by hand — which the read-me
# explains. Signing needs a paid Apple Developer account; with one, add
# `--sign "Developer ID Application: …"` to the codesign step below and run
# `xcrun notarytool submit` on the finished DMG.

set -euo pipefail

cd "$(dirname "$0")/.."
PROJECT="MVR Exploder.xcodeproj"
SCHEME="MVR Exploder"
APP_NAME="MVR Exploder"

VERSION="${1:-$(
  xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
    -showBuildSettings 2>/dev/null |
    awk -F' = ' '/ MARKETING_VERSION = /{print $2; exit}'
)}"
: "${VERSION:?could not determine a version}"

BUILD_DIR="$(mktemp -d)"
STAGE="$BUILD_DIR/stage"
DMG="dist/$APP_NAME $VERSION.dmg"
trap 'rm -rf "$BUILD_DIR"' EXIT

echo "Building $APP_NAME $VERSION…"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -derivedDataPath "$BUILD_DIR/derived" build > "$BUILD_DIR/build.log" 2>&1 ||
  { tail -40 "$BUILD_DIR/build.log"; exit 1; }

APP="$BUILD_DIR/derived/Build/Products/Release/$APP_NAME.app"
[[ -d "$APP" ]] || { echo "no app at $APP"; exit 1; }

# Universal is not automatic — a Release build that only made arm64 would
# fail silently on an Intel Mac, so it is checked rather than assumed.
ARCHS="$(lipo -archs "$APP/Contents/MacOS/$APP_NAME")"
for wanted in arm64 x86_64; do
  [[ "$ARCHS" == *"$wanted"* ]] || { echo "not universal: $ARCHS"; exit 1; }
done

mkdir -p "$STAGE" dist
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' \
  "$APP/Contents/Info.plist" 2>/dev/null || echo '26.0')"

cat > "$STAGE/READ ME FIRST.txt" <<TXT
MVR Exploder $VERSION
$(printf '=%.0s' {1..40})

Requires macOS $MIN_OS or later. Universal — Apple silicon and Intel.

To install: drag "$APP_NAME" onto the Applications folder here.


FIRST LAUNCH — please read
--------------------------
This app is not signed with an Apple Developer certificate, so macOS will
refuse to open it the first time and may say it is "damaged". It isn't —
that is just what macOS says about any app it can't trace to a paid
developer account.

To open it:

  1. Drag the app to Applications.
  2. Double-click it. macOS will refuse. Click Done / OK.
  3. Open System Settings > Privacy & Security.
  4. Scroll down. There will be a line about "$APP_NAME" being blocked,
     with an "Open Anyway" button. Click it, and confirm.

That is a one-off. It opens normally from then on.

Right-click > Open no longer works as a shortcut on current macOS, so use
the steps above.

If that line does not appear, open Terminal and run this, then try again:

  xattr -dr com.apple.quarantine "/Applications/$APP_NAME.app"
TXT

rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" \
  -ov -format UDZO -quiet "$DMG"
hdiutil verify "$DMG" > /dev/null

echo "$DMG  ($(du -h "$DMG" | cut -f1), $ARCHS)"
