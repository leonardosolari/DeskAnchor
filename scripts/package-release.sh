#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$TASK_ROOT"
APP="build/DeskAnchor.app"
if [[ ! -d "$APP" ]]; then printf 'Run make release to build the app first.\n' >&2; exit 1; fi
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
if [[ ! "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then printf 'Invalid application version.\n' >&2; exit 1; fi
for binary in DeskAnchorApp deskanchor; do
    architectures="$(lipo -archs "$APP/Contents/MacOS/$binary")"
    if [[ " $architectures " != *" arm64 "* || " $architectures " != *" x86_64 "* ]]; then
        printf '%s is not universal. Run make release.\n' "$binary" >&2
        exit 1
    fi
done
codesign --verify --deep --strict "$APP"
mkdir -p dist
ARCHIVE="DeskAnchor-$APP_VERSION-macos-universal.zip"
# Preserve executable bits, resource metadata and the application bundle inside the ZIP.
ditto -c -k --sequesterRsrc --keepParent "$APP" "dist/$ARCHIVE"
(cd dist && shasum -a 256 "$ARCHIVE" > "$ARCHIVE.sha256")
printf 'Ready for manual upload: dist/%s\n' "$ARCHIVE"
