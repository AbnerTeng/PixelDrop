#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
OUTPUT=${1:-dist/PixelDrop.app/Contents/Resources/PixelDrop.icns}
ICON_WORK=$(mktemp -d)
trap 'rm -rf "$ICON_WORK"' EXIT
ICONSET="$ICON_WORK/PixelDrop.iconset"
mkdir -p "$ICONSET" "$(dirname "$OUTPUT")"
for SIZE in 16 32 128 256 512; do
  sips -z "$SIZE" "$SIZE" assets/PixelDrop.png --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
  DOUBLE=$((SIZE * 2))
  sips -z "$DOUBLE" "$DOUBLE" assets/PixelDrop.png --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
# Store PNG representations in the documented ICNS chunk container. This
# also works in build environments where iconutil cannot load its encoder.
python3 - "$ICONSET" "$OUTPUT" <<'PYICON'
from pathlib import Path
import struct
import sys
root = Path(sys.argv[1])
representations = {
    "icp4": "icon_16x16.png", "ic11": "icon_16x16@2x.png",
    "icp5": "icon_32x32.png", "ic12": "icon_32x32@2x.png",
    "ic07": "icon_128x128.png", "ic13": "icon_128x128@2x.png",
    "ic08": "icon_256x256.png", "ic14": "icon_256x256@2x.png",
    "ic09": "icon_512x512.png", "ic10": "icon_512x512@2x.png",
}
chunks = []
for kind, name in representations.items():
    data = (root / name).read_bytes()
    assert data.startswith(b"\x89PNG\r\n\x1a\n")
    chunks.append(kind.encode("ascii") + struct.pack(">I", len(data) + 8) + data)
body = b"".join(chunks)
Path(sys.argv[2]).write_bytes(b"icns" + struct.pack(">I", len(body) + 8) + body)
PYICON
