#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="VoiceScribe"
PROJECT_PATH="$ROOT_DIR/VoiceScribe.xcodeproj"
SCHEME="$APP_NAME"
DERIVED_DATA="$ROOT_DIR/build/DerivedData"
RELEASE_APP="$DERIVED_DATA/Build/Products/Release/$APP_NAME.app"
DIST_DIR="$ROOT_DIR/dist"
DIST_APP="$DIST_DIR/$APP_NAME.app"
DIST_ZIP="$DIST_DIR/${APP_NAME}-macOS-test.zip"

cd "$ROOT_DIR"

echo "==> Cleaning previous package output"
rm -rf "$DIST_APP" "$DIST_ZIP"
mkdir -p "$DIST_DIR"

echo "==> Building Release app"
xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  build

if [[ ! -d "$RELEASE_APP" ]]; then
  echo "Release app not found: $RELEASE_APP" >&2
  exit 1
fi

echo "==> Copying app to dist"
cp -R "$RELEASE_APP" "$DIST_APP"

if [[ ! -f "$DIST_APP/Contents/Resources/AppIcon.icns" ]]; then
  echo "App icon was not found in the packaged app." >&2
  exit 1
fi

echo "==> Creating zip"
ditto -c -k --sequesterRsrc --keepParent "$DIST_APP" "$DIST_ZIP"

echo
echo "Package complete:"
echo "  App: $DIST_APP"
echo "  Zip: $DIST_ZIP"
