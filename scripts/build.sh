#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
APP="$PWD/dist/PixelDrop.app"
# Replacing a running executable can leave TCC checking a different code
# identity than the process in memory. Require a clean restart after builds.
if /usr/bin/pgrep -x PixelDrop >/dev/null 2>&1; then
  echo "Quit PixelDrop from its menu bar before rebuilding." >&2
  exit 1
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
./scripts/build-icon.sh "$APP/Contents/Resources/PixelDrop.icns"
BUILD_ARCHS=(${=ARCHS:-$(uname -m)})
BUILD_DIR=$(mktemp -d)
trap 'rm -rf "$BUILD_DIR"' EXIT
for ARCH in $BUILD_ARCHS; do
  swiftc -target "$ARCH-apple-macosx14.0" -module-cache-path "${TMPDIR:-/tmp}/pixeldrop-module-cache" Sources/main.swift -o "$BUILD_DIR/PixelDrop-$ARCH" -framework Cocoa -framework Carbon -framework CoreGraphics -framework ScreenCaptureKit
done
lipo -create "$BUILD_DIR"/PixelDrop-* -output "$APP/Contents/MacOS/PixelDrop"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>PixelDrop</string>
<key>CFBundleIdentifier</key><string>local.pixeldrop.app</string>
<key>CFBundleName</key><string>PixelDrop</string>
<key>CFBundleIconFile</key><string>PixelDrop.icns</string>
<key>CFBundleVersion</key><string>9</string>
<key>CFBundleShortVersionString</key><string>0.1.8</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
# Keep the designated requirement stable across local rebuilds so TCC can
# recognize the same app even when its ad-hoc code hash changes.
if [ "${CODE_SIGN_IDENTITY:--}" = "-" ]; then
  codesign --force --sign - --identifier local.pixeldrop.app --requirements '=designated => identifier "local.pixeldrop.app"' "$APP"
else
  codesign --force --sign "$CODE_SIGN_IDENTITY" --options runtime --timestamp "$APP"
fi
touch "$APP"
echo "Built $APP"
