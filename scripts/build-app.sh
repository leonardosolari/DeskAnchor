#!/bin/bash
set -euo pipefail

TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$TASK_ROOT"
APP_VERSION="${VERSION:-$(cat VERSION)}"
APP_BUILD="${BUILD_NUMBER:-1}"
CONFIGURATION="${CONFIGURATION:-release}"
SIGNING_IDENTITY="${CODE_SIGN_IDENTITY:--}"
APP="$TASK_ROOT/build/DeskAnchor.app"

if [[ ! "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || ! "$APP_BUILD" =~ ^[1-9][0-9]*$ ]]; then
    printf 'VERSION must be X.Y.Z and BUILD_NUMBER must be a positive integer.\n' >&2
    exit 1
fi
if [[ "$CONFIGURATION" != release && "$CONFIGURATION" != debug ]]; then
    printf 'CONFIGURATION must be release or debug.\n' >&2
    exit 1
fi

# Never replace the bundle of a running instance.
RUNNING_APP_PIDS="$(/bin/ps -axo pid=,comm= | /usr/bin/awk -v executable="$APP/Contents/MacOS/DeskAnchorApp" '{sub(/^[[:space:]]*/, ""); pid=$1; sub(/^[0-9]+[[:space:]]+/, ""); if ($0 == executable) print pid}')"
if [[ -n "$RUNNING_APP_PIDS" ]]; then
    printf 'Quit DeskAnchor before rebuilding its bundle (PID: %s).\n' "$RUNNING_APP_PIDS" >&2
    exit 1
fi

export CLANG_MODULE_CACHE_PATH="$TASK_ROOT/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$TASK_ROOT/.build/module-cache"
BUILD_ARGS=(-c "$CONFIGURATION" --cache-path .build/cache --config-path .build/config --security-path .build/security)
if [[ "${DESKANCHOR_DISABLE_PACKAGE_SANDBOX:-0}" == 1 ]]; then BUILD_ARGS+=(--disable-sandbox); fi
if [[ "${UNIVERSAL:-0}" == 1 ]]; then BUILD_ARGS+=(--arch arm64 --arch x86_64); fi
swift build "${BUILD_ARGS[@]}"
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"

# A signing failure must not destroy the previous working bundle.
mkdir -p "$TASK_ROOT/build"
STAGE="$(mktemp -d "$TASK_ROOT/build/.package.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
STAGED_APP="$STAGE/DeskAnchor.app"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
cp "$BIN_DIR/DeskAnchorApp" "$STAGED_APP/Contents/MacOS/DeskAnchorApp"
cp "$BIN_DIR/deskanchor" "$STAGED_APP/Contents/MacOS/deskanchor"
cp packaging/Info.plist "$STAGED_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$STAGED_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $APP_BUILD" "$STAGED_APP/Contents/Info.plist"
cp LICENSE "$STAGED_APP/Contents/Resources/LICENSE"
swift scripts/make-icon.swift "$TASK_ROOT/.build/AppIcon.iconset"
iconutil -c icns .build/AppIcon.iconset -o "$STAGED_APP/Contents/Resources/AppIcon.icns"
codesign --force --sign "$SIGNING_IDENTITY" "$STAGED_APP/Contents/MacOS/deskanchor"
codesign --force --sign "$SIGNING_IDENTITY" "$STAGED_APP"
codesign --verify --deep --strict "$STAGED_APP"
if [[ -d "$APP" ]]; then mv "$APP" "$STAGE/previous.app"; fi
if ! mv "$STAGED_APP" "$APP"; then
    if [[ -d "$STAGE/previous.app" ]]; then mv "$STAGE/previous.app" "$APP"; fi
    exit 1
fi
printf 'Built %s (%s): %s\n' "$APP_VERSION" "$APP_BUILD" "$APP"
