#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
APP="$PWD/dist/PixelDrop.app"
OUTPUT="$PWD/dist/release/PixelDrop-macos-universal.dmg"
codesign --verify --deep --strict "$APP"
DMG_WORK=$(mktemp -d)
trap 'rm -rf "$DMG_WORK"' EXIT
mkdir -p "$DMG_WORK/volume" "$(dirname "$OUTPUT")"
ditto "$APP" "$DMG_WORK/volume/PixelDrop.app"
ln -s /Applications "$DMG_WORK/volume/Applications"
cat > "$DMG_WORK/volume/Install.txt" <<'INSTALL'
Install PixelDrop

1. Drag PixelDrop.app into Applications.
2. Eject this disk image.
3. Open PixelDrop from Applications.

PixelDrop lives in the menu bar and does not appear in the Dock.
Press Command–Shift–2 to pick a color; Escape cancels.
Click to copy the hex code and show a confirmation popup.
Quit PixelDrop from its menu bar menu.
INSTALL
# The normal compressed image builder needs a virtual disk device. A
# filesystem-only HFS image is also mountable by Finder and works on hosts
# where virtual disk devices are unavailable (for example sandboxed builds).
if ! hdiutil create -volname PixelDrop -srcfolder "$DMG_WORK/volume" -format UDZO -ov "$OUTPUT"; then
  hdiutil makehybrid -hfs -hfs-volume-name PixelDrop -o "$DMG_WORK/PixelDrop.dmg" "$DMG_WORK/volume"
  hdiutil convert "$DMG_WORK/PixelDrop.dmg" -format UDZO -o "$OUTPUT" -ov
fi
if [ "${CODE_SIGN_IDENTITY:--}" != "-" ]; then
  codesign --force --sign "$CODE_SIGN_IDENTITY" --timestamp "$OUTPUT"
fi
if [ -n "${NOTARY_PROFILE:-}" ]; then
  xcrun notarytool submit "$OUTPUT" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$OUTPUT"
fi
hdiutil verify "$OUTPUT"
echo "Built $OUTPUT"
