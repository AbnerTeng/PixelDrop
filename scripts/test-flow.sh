#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
python3 - "$TEST_DIR/flow.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Sources/main.swift').read_text().split('\nlet app = NSApplication.shared')[0]
# Override UI effects only; exercise the production start/error/retry/finish code.
source = source.replace('final class AppDelegate:', 'class AppDelegate:', 1)
source += '''
final class HeadlessDelegate: AppDelegate {
    var successes = 0
    var copied: [String] = []
    override func copyHex(_ hex: String) { copied.append(hex) }
    override func installCancellation() { }
    override func showOverlays(_ captures: [(NSScreen, NSBitmapImageRep)]) { successes += 1 }
}
@main struct FlowRegression {
    @MainActor static func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<300 {
            if condition() { return }
            try! await Task.sleep(nanoseconds: 10_000_000)
        }
        fatalError("Capture flow timed out")
    }
    @MainActor static func main() async {
        let picker = HeadlessDelegate()
        // The normal picker must never call the screenshot/permission path.
        picker.captureProvider = { fatalError("Native picker must not request screenshot access") }
        var callback: ((NSColor?) -> Void)?
        var samplerStarts = 0
        picker.samplerProvider = { completion in samplerStarts += 1; callback = completion }
        picker.startPicking()
        precondition(picker.samplerActive && samplerStarts == 1 && picker.escapeHotkey == nil)
        picker.startPicking()
        precondition(samplerStarts == 1, "Do not start duplicate sampler sessions")
        callback?(nil) // AppKit reports Escape as nil.
        precondition(!picker.samplerActive && picker.copied.isEmpty)
        picker.startPicking()
        callback?(NSColor(srgbRed: 18.0/255, green: 171.0/255, blue: 239.0/255, alpha: 1))
        precondition(!picker.samplerActive && picker.copied == ["#12ABEF"])
        picker.showPermissionHelp()
        picker.startPicking()
        precondition(picker.samplerActive && !picker.showingPermissionHelp && picker.pickSession == nil)
        callback?(nil)
        var attempts = 0
        picker.captureProvider = {
            attempts += 1
            throw NSError(domain: SCStreamErrorDomain, code: -3801)
        }
        picker.startScreenshotPicking()
        await waitUntil { picker.showingPermissionHelp }
        precondition(attempts == 1)
        let deniedSession = picker.pickSession
        // A repeated shortcut must retry, not keep showing Settings forever.
        picker.startScreenshotPicking()
        precondition(picker.capturing && !picker.showingPermissionHelp)
        precondition(picker.pickSession != deniedSession)
        await waitUntil { picker.showingPermissionHelp }
        precondition(attempts == 2)
        // Permission can become available in the same process.
        picker.captureProvider = { attempts += 1; return [] }
        picker.startScreenshotPicking()
        await waitUntil { picker.successes == 1 }
        precondition(attempts == 3 && !picker.showingPermissionHelp && !picker.capturing)
        picker.finish(nil)
        precondition(picker.pickSession == nil)
        // Escape while capture is pending must prevent a late overlay.
        picker.startScreenshotPicking()
        picker.finish(nil)
        try! await Task.sleep(nanoseconds: 350_000_000)
        precondition(attempts == 3 && picker.successes == 1 && picker.pickSession == nil)
        print("PASS: native sampler selection/cancellation; no capture permission path; screenshot recovery/cancellation")
    }
}
'''
Path(sys.argv[1]).write_text(source)
PY
swiftc -parse-as-library -module-cache-path "${TMPDIR:-/tmp}/pixeldrop-module-cache" "$TEST_DIR/flow.swift" -o "$TEST_DIR/flow" -framework Cocoa -framework Carbon -framework CoreGraphics -framework ScreenCaptureKit
"$TEST_DIR/flow"
