#!/bin/sh
# Package an already-built universal macOS app and Ubuntu launcher.
set -eu
cd "$(dirname "$0")/.."
mkdir -p dist/release
lipo dist/PixelDrop.app/Contents/MacOS/PixelDrop -verify_arch arm64 x86_64
codesign --verify --deep --strict dist/PixelDrop.app
COPYFILE_DISABLE=1 tar -czf dist/release/PixelDrop-macos-universal.tar.gz -C dist PixelDrop.app
COPYFILE_DISABLE=1 tar -czf dist/release/PixelDrop-ubuntu.tar.gz -C linux pixeldrop.py -C "$PWD/assets" PixelDrop.png
./scripts/build-dmg.sh
cp install.sh dist/release/install.sh
(cd dist/release && shasum -a 256 PixelDrop-*.tar.gz PixelDrop-*.dmg > SHA256SUMS)
if [ "$#" -eq 2 ]; then
  python3 scripts/homebrew-formula.py "$1" "$2" dist/release/PixelDrop-macos-universal.tar.gz dist/release/pixeldrop.rb
  python3 scripts/homebrew-formula.py --cask "$1" "$2" dist/release/PixelDrop-macos-universal.dmg dist/release/pixeldrop-cask.rb
fi
