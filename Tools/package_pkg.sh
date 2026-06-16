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
COMPONENT_PKG="$DIST_DIR/${APP_NAME}-Component.pkg"
FINAL_PKG="$DIST_DIR/${APP_NAME}.pkg"

cd "$ROOT_DIR"

echo "==> Cleaning previous package output"
rm -rf "$DIST_APP" "$COMPONENT_PKG" "$FINAL_PKG"
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

echo "==> Ad-hoc signing app bundle"
/usr/bin/codesign --force --deep --sign - "$DIST_APP"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$DIST_APP"

echo "==> Preparing installation scripts"
SCRIPTS_DIR="$DIST_DIR/pkg_scripts"
rm -rf "$SCRIPTS_DIR"
mkdir -p "$SCRIPTS_DIR"

# Write postinstall script
cat << 'EOF' > "$SCRIPTS_DIR/postinstall"
#!/bin/bash
set -euo pipefail

# Find the console user
CONSOLE_USER=$(stat -f '%Su' /dev/console)

if [ -z "$CONSOLE_USER" ] || [ "$CONSOLE_USER" = "root" ] || [ "$CONSOLE_USER" = "loginwindow" ]; then
    CONSOLE_USER="${SUDO_USER:-$USER}"
fi

if [ -z "$CONSOLE_USER" ] || [ "$CONSOLE_USER" = "root" ]; then
    echo "Could not determine console user." >&2
    exit 0
fi

USER_HOME=$(eval echo "~$CONSOLE_USER")
VENV_DIR="$USER_HOME/.voicescribe/venv"

echo "Creating Python virtual environment for user: $CONSOLE_USER at $VENV_DIR"

# Ensure ~/.voicescribe directory exists and is owned by console user
mkdir -p "$USER_HOME/.voicescribe"
chown "$CONSOLE_USER" "$USER_HOME/.voicescribe"

# Find python3 executable
PYTHON_BIN=""
for candidate in "/usr/bin/python3" "/usr/local/bin/python3" "/opt/homebrew/bin/python3"; do
    if [ -x "$candidate" ]; then
        PYTHON_BIN="$candidate"
        break
    fi
done

if [ -z "$PYTHON_BIN" ] && command -v python3 &>/dev/null; then
    PYTHON_BIN=$(command -v python3)
fi

if [ -n "$PYTHON_BIN" ]; then
    echo "Using python: $PYTHON_BIN"
    # Create the virtual environment running as the console user
    sudo -u "$CONSOLE_USER" "$PYTHON_BIN" -m venv "$VENV_DIR"

    # Pre-upgrade pip, setuptools, wheel as console user
    if [ -x "$VENV_DIR/bin/python3" ]; then
        echo "Upgrading pip/setuptools/wheel..."
        sudo -u "$CONSOLE_USER" "$VENV_DIR/bin/python3" -m pip install -U pip setuptools wheel -q
    fi
else
    echo "python3 not found. Virtualenv will be created by the app on startup." >&2
fi

exit 0
EOF

chmod +x "$SCRIPTS_DIR/postinstall"

echo "==> Building Component Package"
pkgbuild --component "$DIST_APP" \
         --install-location "/Applications" \
         --scripts "$SCRIPTS_DIR" \
         "$COMPONENT_PKG"

echo "==> Building Final Product Package"
productbuild --package "$COMPONENT_PKG" "$FINAL_PKG"

# Clean up component pkg and scripts
rm -f "$COMPONENT_PKG"
rm -rf "$SCRIPTS_DIR"

echo
echo "Package complete:"
echo "  App: $DIST_APP"
echo "  PKG: $FINAL_PKG"
