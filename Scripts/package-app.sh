#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="Colosseum"
BUNDLE_ID="dev.pab.colosseum"
VERSION="1.10.0"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
ZIP="$DIST/${APP_NAME}-${VERSION}-macos.zip"

INSTALL=1
for arg in "$@"; do
  case "$arg" in
    --no-install) INSTALL=0 ;;
    *)
      echo "Unknown option: $arg" >&2
      echo "Usage: $0 [--no-install]" >&2
      exit 1
      ;;
  esac
done

echo "Building universal release (arm64 + x86_64)…"
swift build -c release --arch arm64 --arch x86_64

BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/$APP_NAME"
if [[ ! -x "$BIN" ]]; then
  echo "Missing binary at $BIN" >&2
  exit 1
fi

rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES"

cp "$BIN" "$MACOS/$APP_NAME"
chmod +x "$MACOS/$APP_NAME"

# Bundle resource bundle produced by SPM if present
RES_BUNDLE="$(dirname "$BIN")/${APP_NAME}_${APP_NAME}.bundle"
if [[ -d "$RES_BUNDLE" ]]; then
  cp -R "$RES_BUNDLE" "$RESOURCES/"
fi

if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
  cp "$ROOT/Resources/AppIcon.icns" "$RESOURCES/AppIcon.icns"
fi

cat > "$CONTENTS/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>${APP_NAME}</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_ID}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key>
  <string>${APP_NAME}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION}</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
EOF

# Ad-hoc sign so Gatekeeper is less noisy for local installs
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

# Zip for distribution (preserve .app bundle layout; no AppleDouble junk)
rm -f "$ZIP"
(
  cd "$DIST"
  COPYFILE_DISABLE=1 ditto -c -k --keepParent --norsrc --noextattr "$APP_NAME.app" "$(basename "$ZIP")"
)

echo "Packaged: $ZIP"

if [[ "$INSTALL" -eq 1 ]]; then
  INSTALL_DIR="/Applications"
  echo "Installing to $INSTALL_DIR/$APP_NAME.app…"
  rm -rf "$INSTALL_DIR/$APP_NAME.app"
  cp -R "$APP" "$INSTALL_DIR/$APP_NAME.app"
  echo "Done: $INSTALL_DIR/$APP_NAME.app"
  echo "Launch with: open -a $APP_NAME"
else
  echo "Skipped install (--no-install)."
fi
