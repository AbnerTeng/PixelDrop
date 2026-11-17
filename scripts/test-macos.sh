#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
python3 - "$TEST_DIR/main.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Sources/main.swift').read_text()
source = source[:source.index('\nlet app = NSApplication.shared')]
source += '''
final class RegressionRunner: NSObject, NSApplicationDelegate {
    let picker = AppDelegate()
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Keep Esc live during setup, with no click needed to dismiss it.
        let setup = OverlayWindow(contentRect: NSRect(x: 100, y: 100, width: 440, height: 240),
            styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        setup.isReleasedWhenClosed = false
        setup.becomesKeyOnlyIfNeeded = false
        setup.onCancel = { self.picker.finish(nil) }
        picker.welcome = setup
        picker.showPermissionHelp()
        precondition(picker.showingPermissionHelp)
        precondition(picker.pickSession != nil && picker.keyMonitor != nil)
        let setupEscape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: setup.windowNumber,
            context: nil, characters: "\\u{1b}", charactersIgnoringModifiers: "\\u{1b}",
            isARepeat: false, keyCode: 53)!
        NSApp.sendEvent(setupEscape)
        precondition(picker.pickSession == nil && !picker.showingPermissionHelp && !setup.isVisible)
        picker.showPermissionHelp()
        setup.close()
        precondition(picker.pickSession == nil && picker.keyMonitor == nil)
        // Cancel before any overlay exists, as when an async capture is pending.
        picker.pickSession = UUID()
        picker.capturing = true
        picker.installCancellation()
        picker.finish(nil)
        precondition(picker.pickSession == nil && !picker.capturing)
        precondition(picker.keyMonitor == nil && picker.escapeHotkey == nil)
        // Exercise a real panel and event delivery with no mouse click.
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 4, bitsPerPixel: 32)!
        let panel = OverlayWindow(contentRect: NSRect(x: 100, y: 100, width: 160, height: 120),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        let view = PickerView(frame: NSRect(x: 0, y: 0, width: 160, height: 120), bitmap: bitmap)
        view.onCancel = { self.picker.finish(nil) }
        panel.contentView = view
        picker.pickSession = UUID()
        picker.overlays = [panel]
        picker.installCancellation()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(view)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            precondition(panel.isKeyWindow, "Panel must receive keys without a click")
            precondition(panel.firstResponder === view)
            let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                context: nil, characters: "\\u{1b}", charactersIgnoringModifiers: "\\u{1b}",
                isARepeat: false, keyCode: 53)!
            NSApp.sendEvent(escape)
            precondition(self.picker.overlays.isEmpty && self.picker.pickSession == nil)
            precondition(self.picker.keyMonitor == nil && self.picker.escapeHotkey == nil)
            precondition(!panel.isVisible)
            print("PASS: pending cancellation and Escape before any mouse click")
            NSApp.terminate(nil)
        }
    }
}
let app = NSApplication.shared
let runner = RegressionRunner()
app.delegate = runner
app.setActivationPolicy(.accessory)
DispatchQueue.global().asyncAfter(deadline: .now() + 8) {
    fputs("FAIL: macOS GUI regression timed out; run in a logged-in desktop session.\\n", stderr)
    exit(2)
}
app.run()
'''
Path(sys.argv[1]).write_text(source)
PY
swiftc -module-cache-path "${TMPDIR:-/tmp}/pixeldrop-module-cache" "$TEST_DIR/main.swift" -o "$TEST_DIR/regression" -framework Cocoa -framework Carbon -framework CoreGraphics -framework ScreenCaptureKit
if [ "${1:-}" = "--compile-only" ]; then
  echo "GUI regression harness compiled (not executed)"
else
  "$TEST_DIR/regression"
fi
