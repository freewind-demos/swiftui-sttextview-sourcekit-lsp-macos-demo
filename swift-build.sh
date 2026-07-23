#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SWIFT_PROJECT_DIR="${SWIFT_PROJECT_DIR:-$ROOT}"
cd "$SWIFT_PROJECT_DIR"

MODE="$(printf '%s' "${1:-debug}" | tr '[:upper:]' '[:lower:]')"
case "$MODE" in
  debug)
    CONFIG="Debug"
    ;;
  release)
    CONFIG="Release"
    ;;
  *)
    echo "usage: ./swift-build.sh [debug|release]" >&2
    exit 2
    ;;
esac

PROJ_NAME="$(awk '/^name:[[:space:]]*/ { print $2; exit }' project.yml)"
if [[ -z "$PROJ_NAME" ]]; then
  echo "error: could not read project name from project.yml" >&2
  exit 1
fi

PLATFORM="$(awk '/platform:[[:space:]]*/ { print $2; exit }' project.yml)"
case "$PLATFORM" in
  macOS)
    DESTINATION_ARGS=()
    ;;
  iOS)
    DESTINATION_ARGS=(-destination "generic/platform=iOS Simulator")
    ;;
  *)
    echo "error: unsupported platform in project.yml: $PLATFORM" >&2
    exit 1
    ;;
esac

DERIVED="$ROOT/build/DerivedData-$CONFIG"
rm -rf "$DERIVED"

xcodegen generate

SCHEME_PATHS=("$PROJ_NAME.xcodeproj/xcshareddata/xcschemes"/*.xcscheme)
if [[ ! -e "${SCHEME_PATHS[0]}" ]]; then
  echo "error: could not find xcode scheme" >&2
  exit 1
fi
SCHEME_PATH="${SCHEME_PATHS[0]}"
SCHEME="$(basename "$SCHEME_PATH" .xcscheme)"

BUILD_SETTINGS="$(xcodebuild \
  ${DESTINATION_ARGS[@]+"${DESTINATION_ARGS[@]}"} \
  -project "$PROJ_NAME.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  -showBuildSettings)"

TARGET_BUILD_DIR="$(printf '%s\n' "$BUILD_SETTINGS" | awk -F ' = ' '/^[[:space:]]*TARGET_BUILD_DIR = / { print $2; exit }')"
WRAPPER_NAME="$(printf '%s\n' "$BUILD_SETTINGS" | awk -F ' = ' '/^[[:space:]]*WRAPPER_NAME = / { print $2; exit }')"
if [[ -z "$TARGET_BUILD_DIR" || -z "$WRAPPER_NAME" ]]; then
  echo "error: could not read app path from build settings" >&2
  exit 1
fi
APP_PATH="$TARGET_BUILD_DIR/$WRAPPER_NAME"

xcodebuild \
  ${DESTINATION_ARGS[@]+"${DESTINATION_ARGS[@]}"} \
  -project "$PROJ_NAME.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build

if [[ ! -d "$APP_PATH" ]]; then
  echo "error: app not found: $APP_PATH" >&2
  exit 1
fi

open "$(dirname "$APP_PATH")"
echo "$APP_PATH"
