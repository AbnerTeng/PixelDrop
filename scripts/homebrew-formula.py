#!/usr/bin/env python3
"""Generate a macOS Homebrew formula from release artifacts, with real hashes."""
import argparse
import hashlib
from pathlib import Path
import re
p = argparse.ArgumentParser()
p.add_argument('--cask', action='store_true', help='Generate a drag-to-Applications Homebrew cask from the DMG')
p.add_argument('repository')
p.add_argument('tag')
p.add_argument('archive', type=Path)
p.add_argument('output', type=Path)
a = p.parse_args()
if not re.fullmatch(r'[\w.-]+/[\w.-]+', a.repository) or not re.fullmatch(r'v?\d+\.\d+\.\d+', a.tag):
    p.error('Expected owner/repository and a semantic version tag, e.g. v0.1.0')
sha = hashlib.sha256(a.archive.read_bytes()).hexdigest()
a.output.parent.mkdir(parents=True, exist_ok=True)
if a.cask:
    a.output.write_text(f'''cask "pixeldrop" do
  version "{a.tag.removeprefix('v')}"
  sha256 "{sha}"

  url "https://github.com/{a.repository}/releases/download/{a.tag}/PixelDrop-macos-universal.dmg"
  name "PixelDrop"
  desc "Menu bar eyedropper that copies HTML hex colors"
  homepage "https://github.com/{a.repository}"

  depends_on macos: ">= :sonoma"
  app "PixelDrop.app"
end
''')
    raise SystemExit(0)
a.output.write_text(f'''class Pixeldrop < Formula
  desc "Screenshot eyedropper that copies HTML hex colors"
  homepage "https://github.com/{a.repository}"
  url "https://github.com/{a.repository}/releases/download/{a.tag}/PixelDrop-macos-universal.tar.gz"
  version "{a.tag.removeprefix('v')}"
  sha256 "{sha}"

  depends_on :macos
  depends_on macos: :sonoma

  def install
    prefix.install "PixelDrop.app"
    (bin/"pixeldrop").write <<~SH
      #!/bin/sh
      exec /usr/bin/open "#{{prefix}}/PixelDrop.app" "$@"
    SH
  end

  def caveats
    <<~EOS
      Launch with: pixeldrop
      The optional frozen screenshot mode requires Screen Recording permission.
      This build is ad-hoc signed, not notarized. macOS may require Open Anyway.
    EOS
  end

  test do
    assert_path_exists prefix/"PixelDrop.app/Contents/MacOS/PixelDrop"
    system "/usr/bin/codesign", "--verify", "--deep", "--strict", prefix/"PixelDrop.app"
  end
end
''')
