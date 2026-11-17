#!/bin/sh
# Usage: sh install.sh owner/repository [release-tag]
set -eu
REPO=${1:-${PIXELDROP_REPO:-}}
TAG=${2:-latest}
case "$REPO" in
  */*) ;;
  *) echo 'Usage: sh install.sh owner/repository [release-tag]' >&2; exit 1 ;;
esac
case "$REPO" in *[!a-zA-Z0-9_./-]*|*..*) echo 'Invalid repository' >&2; exit 1;; esac
case "$TAG" in *[!a-zA-Z0-9_.-]*|'') echo 'Invalid release tag' >&2; exit 1;; esac
if [ "$TAG" = latest ]; then BASE="https://github.com/$REPO/releases/latest/download"; else BASE="https://github.com/$REPO/releases/download/$TAG"; fi
fetch() {
  if command -v curl >/dev/null 2>&1; then curl -fLSs "$1" -o "$2"; else wget -q "$1" -O "$2"; fi
}
case "$(uname -s)" in
  Darwin) ASSET=PixelDrop-macos-universal.tar.gz ;;
  Linux)
    ASSET=PixelDrop-ubuntu.tar.gz
    if ! /usr/bin/python3 -c 'import gi; gi.require_version("Gtk", "3.0"); from gi.repository import Gtk; import cairo' 2>/dev/null; then
      echo 'Install Ubuntu dependencies first:' >&2
      echo 'sudo apt update && sudo apt install python3 python3-gi python3-gi-cairo gir1.2-gtk-3.0 xdg-desktop-portal' >&2
      exit 1
    fi ;;
  *) echo 'Supported platforms: macOS and Ubuntu desktop' >&2; exit 1 ;;
esac
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
fetch "$BASE/$ASSET" "$WORK/$ASSET"
fetch "$BASE/SHA256SUMS" "$WORK/SHA256SUMS"
(cd "$WORK"; if command -v sha256sum >/dev/null 2>&1; then
  awk -v name="$ASSET" '$2 == name {print}' SHA256SUMS > selected.sha256
  test -s selected.sha256
  sha256sum -c selected.sha256
else
  awk -v name="$ASSET" '$2 == name {print}' SHA256SUMS > selected.sha256
  test -s selected.sha256
  shasum -a 256 -c selected.sha256
fi)
tar -xzf "$WORK/$ASSET" -C "$WORK"
if [ "$(uname -s)" = Darwin ]; then
  mkdir -p "$HOME/Applications"
  if [ -e "$HOME/Applications/PixelDrop.app" ]; then
    echo 'PixelDrop already exists in ~/Applications. Quit it and move the old app aside before installing.' >&2
    exit 1
  fi
  cp -R "$WORK/PixelDrop.app" "$HOME/Applications/"
  echo 'Installed ~/Applications/PixelDrop.app. Open it in Finder to launch.'
  echo 'This local build is not notarized; macOS may require Open Anyway in Privacy & Security.'
else
  mkdir -p "$HOME/.local/share/pixeldrop" "$HOME/.local/bin" "$HOME/.local/share/applications"
  cp "$WORK/pixeldrop.py" "$HOME/.local/share/pixeldrop/pixeldrop.py"
  cp "$WORK/PixelDrop.png" "$HOME/.local/share/pixeldrop/PixelDrop.png"
  cat > "$HOME/.local/bin/pixeldrop" <<'LAUNCHER'
#!/bin/sh
exec /usr/bin/python3 "$HOME/.local/share/pixeldrop/pixeldrop.py" "$@"
LAUNCHER
  chmod +x "$HOME/.local/bin/pixeldrop"
  cat > "$HOME/.local/share/applications/local.pixeldrop.app.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=PixelDrop
Comment=Pick a screenshot pixel and copy its HTML color
Exec="$HOME/.local/bin/pixeldrop"
Icon=$HOME/.local/share/pixeldrop/PixelDrop.png
Terminal=false
Categories=Graphics;Utility;
DESKTOP
  echo 'Installed PixelDrop. Launch from Applications or run ~/.local/bin/pixeldrop.'
  echo 'Assign ~/.local/bin/pixeldrop to Ctrl+Shift+2 in Settings → Keyboard → Custom Shortcuts.'
fi
