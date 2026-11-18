import Cocoa
import Carbon
import CoreGraphics
import ScreenCaptureKit

final class OverlayWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func close() { onCancel?(); super.close() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) { onCancel?() }
        else { super.keyDown(with: event) }
    }
}

final class PickerView: NSView {
    let bitmap: NSBitmapImageRep
    let screenshot: NSImage
    var pointer = NSPoint(x: 100, y: 100)
    var onPick: ((String) -> Void)?
    var onCancel: (() -> Void)?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    init(frame: NSRect, bitmap: NSBitmapImageRep) {
        self.bitmap = bitmap
        screenshot = NSImage(size: frame.size)
        screenshot.addRepresentation(bitmap)
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }
    func pixel(_ point: NSPoint) -> NSColor {
        let x = min(bitmap.pixelsWide - 1, max(0, Int(point.x / bounds.width * CGFloat(bitmap.pixelsWide))))
        let y = min(bitmap.pixelsHigh - 1, max(0, Int(point.y / bounds.height * CGFloat(bitmap.pixelsHigh))))
        return bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) ?? .black
    }
    func hex(_ color: NSColor) -> String {
        String(format: "#%02X%02X%02X", Int((color.redComponent * 255).rounded()), Int((color.greenComponent * 255).rounded()), Int((color.blueComponent * 255).rounded()))
    }
    override func mouseMoved(with event: NSEvent) { pointer = convert(event.locationInWindow, from: nil); needsDisplay = true }
    override func mouseDown(with event: NSEvent) { onPick?(hex(pixel(convert(event.locationInWindow, from: nil)))) }
    override func rightMouseDown(with event: NSEvent) { onCancel?() }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() }
        else if event.keyCode == 36 || event.keyCode == 49 { onPick?(hex(pixel(pointer))) }
    }
    override func draw(_ dirtyRect: NSRect) {
        screenshot.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.none])
        let size: CGFloat = 11, count = 11
        let w: CGFloat = 153, h: CGFloat = 190
        let origin = NSPoint(x: min(max(8, pointer.x + 24), bounds.width - w - 8), y: min(max(8, pointer.y + 24), bounds.height - h - 8))
        let card = NSRect(origin: origin, size: NSSize(width: w, height: h))
        NSColor(calibratedWhite: 0.08, alpha: 0.96).setFill()
        NSBezierPath(roundedRect: card, xRadius: 12, yRadius: 12).fill()
        let sx = bounds.width / CGFloat(bitmap.pixelsWide), sy = bounds.height / CGFloat(bitmap.pixelsHigh)
        for y in 0..<count { for x in 0..<count {
            pixel(NSPoint(x: pointer.x + CGFloat(x - 5) * sx, y: pointer.y + CGFloat(y - 5) * sy)).setFill()
            NSRect(x: origin.x + 16 + CGFloat(x) * size, y: origin.y + 12 + CGFloat(y) * size, width: size, height: size).fill()
        }}
        NSColor.white.setStroke()
        let center = NSBezierPath(rect: NSRect(x: origin.x + 71, y: origin.y + 67, width: size, height: size)); center.lineWidth = 2; center.stroke()
        let color = pixel(pointer)
        (hex(color) as NSString).draw(at: NSPoint(x: origin.x + 22, y: origin.y + 143), withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 18, weight: .bold), .foregroundColor: NSColor.white])
        ("Click to copy · Esc to exit" as NSString).draw(at: NSPoint(x: origin.x + 13, y: origin.y + 170), withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.lightGray])
        NSColor.white.setStroke()
        let cross = NSBezierPath(); cross.move(to: NSPoint(x: pointer.x - 9, y: pointer.y)); cross.line(to: NSPoint(x: pointer.x + 9, y: pointer.y)); cross.move(to: NSPoint(x: pointer.x, y: pointer.y - 9)); cross.line(to: NSPoint(x: pointer.x, y: pointer.y + 9)); cross.lineWidth = 1; cross.stroke()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var status: NSStatusItem!
    var overlays: [NSWindow] = []
    var welcome: NSWindow?
    var hotkey: EventHotKeyRef?
    var escapeHotkey: EventHotKeyRef?
    var keyMonitor: Any?
    var capturing = false
    var pickSession: UUID?
    var cursorPushed = false
    var showingPermissionHelp = false
    var copyNotice: NSPanel?
    var dismissNotice: DispatchWorkItem?
    var samplerActive = false
    var samplerProvider: ((@escaping (NSColor?) -> Void) -> Void)?
    // Tests can replace capture without asking the OS for screen access.
    var captureProvider: (@MainActor () async throws -> [(NSScreen, NSBitmapImageRep)])?
    var permissionLabel: NSTextField?
    var permissionButton: NSButton?
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set the running application's Dock icon explicitly as well as the
        // bundle icon, so local builds do not depend on LaunchServices caches.
        let icon = Bundle.main.url(forResource: "PixelDrop", withExtension: "icns")
            .flatMap { NSImage(contentsOf: $0) }
        if let icon = icon { NSApp.applicationIconImage = icon }
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.title = "PixelDrop"
        if let icon = icon?.copy() as? NSImage {
            icon.size = NSSize(width: 18, height: 18)
            icon.isTemplate = false
            status.button?.image = icon
            status.button?.imagePosition = .imageLeading
        }
        let menu = NSMenu()
        menu.addItem(withTitle: "Pick screen color    ⌘⇧2", action: #selector(startPicking), keyEquivalent: "")
        menu.addItem(withTitle: "Last color: —", action: nil, keyEquivalent: "")
        let screenshotItem = menu.addItem(withTitle: "Freeze screenshot and pick…", action: #selector(startScreenshotPicking), keyEquivalent: "")
        screenshotItem.target = self
        let settingsItem = menu.addItem(withTitle: "Screen Recording settings…", action: #selector(openScreenRecordingSettings), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit PixelDrop", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.items[0].target = self
        status.menu = menu
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "PixelDrop")
        appMenu.addItem(withTitle: "Quit PixelDrop", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        NSApp.mainMenu = mainMenu
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context = context else { return OSStatus(eventNotHandledErr) }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            var identifier = EventHotKeyID()
            guard let event = event else { return OSStatus(eventNotHandledErr) }
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard result == noErr else { return result }
            if identifier.id == 2 { delegate.finish(nil) }
            else if identifier.id == 1 { delegate.startPicking() }
            return noErr
        }, 1, [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))], Unmanaged.passUnretained(self).toOpaque(), nil)
        RegisterEventHotKey(UInt32(kVK_ANSI_2), UInt32(cmdKey | shiftKey), EventHotKeyID(signature: 0x5049584C, id: 1), GetApplicationEventTarget(), 0, &hotkey)
        let window = OverlayWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 280), styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        window.onCancel = { [weak self, weak window] in
            if self?.pickSession != nil { self?.finish(nil) }
            else { window?.orderOut(nil) }
        }
        window.becomesKeyOnlyIfNeeded = false
        window.hidesOnDeactivate = false
        window.title = "PixelDrop 0.1.9"; window.center(); window.isReleasedWhenClosed = false
        let label = NSTextField(wrappingLabelWithString: "Press ⌘⇧2 for the macOS eyedropper.\n\nClick to copy #RRGGBB; Esc cancels.\nFrozen screenshots are available in the menu.")
        label.frame = NSRect(x: 28, y: 160, width: 384, height: 100); label.font = .systemFont(ofSize: 14)
        window.contentView?.addSubview(label)
        let button = NSButton(title: "Pick a color", target: self, action: #selector(startPicking)); button.bezelStyle = .rounded; button.frame = NSRect(x: 24, y: 25, width: 170, height: 34); window.contentView?.addSubview(button)
        let permission = NSTextField(wrappingLabelWithString: "")
        permission.frame = NSRect(x: 28, y: 70, width: 384, height: 80)
        permission.font = .systemFont(ofSize: 12)
        permission.textColor = .secondaryLabelColor
        window.contentView?.addSubview(permission)
        permissionLabel = permission
        let access = NSButton(title: "Screen Recording settings", target: self, action: #selector(openScreenRecordingSettings))
        access.bezelStyle = .rounded
        access.frame = NSRect(x: 210, y: 25, width: 210, height: 34)
        access.isHidden = true
        window.contentView?.addSubview(access)
        permissionButton = access
        button.identifier = NSUserInterfaceItemIdentifier("pickButton")
        welcome = window; window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc func startPicking() {
        guard !samplerActive, !capturing, overlays.isEmpty else { return }
        if showingPermissionHelp { finish(nil) }
        dismissCopyNotice()
        samplerActive = true
        welcome?.orderOut(nil)
        // Let AppKit own sampling and cancellation. In particular, do not
        // register our Escape hotkey: the system sampler must receive it.
        let completion: (NSColor?) -> Void = { [weak self] color in
            guard let self = self else { return }
            self.samplerActive = false
            guard let color = color?.usingColorSpace(.sRGB) else { return }
            self.copyHex(Self.hex(color))
        }
        if let provider = samplerProvider {
            provider(completion)
        } else {
            NSColorSampler().show(selectionHandler: completion)
        }
    }
    static func hex(_ color: NSColor) -> String {
        String(format: "#%02X%02X%02X", Int((color.redComponent * 255).rounded()),
               Int((color.greenComponent * 255).rounded()), Int((color.blueComponent * 255).rounded()))
    }
    func copyHex(_ hex: String) {
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(hex, forType: .string) else { return }
        status?.menu?.items[1].title = "Last color: \(hex) (copied)"
        status?.button?.title = hex
        showCopyNotice(hex)
    }
    func dismissCopyNotice() {
        dismissNotice?.cancel()
        dismissNotice = nil
        copyNotice?.orderOut(nil)
        copyNotice = nil
    }
    func showCopyNotice(_ hex: String) {
        dismissCopyNotice()
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 236, height: 48),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        let background = NSView(frame: NSRect(x: 0, y: 0, width: 236, height: 48))
        background.wantsLayer = true
        background.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.65).cgColor
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true
        panel.contentView = background
        let label = NSTextField(labelWithString: "Copied")
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textColor = .white

        let rgb = UInt32(hex.dropFirst(), radix: 16) ?? 0
        let swatch = NSView()
        swatch.wantsLayer = true
        swatch.layer?.backgroundColor = NSColor(
            srgbRed: CGFloat((rgb >> 16) & 0xff) / 255,
            green: CGFloat((rgb >> 8) & 0xff) / 255,
            blue: CGFloat(rgb & 0xff) / 255, alpha: 1).cgColor
        swatch.layer?.borderWidth = 1
        swatch.layer?.borderColor = NSColor.white.withAlphaComponent(0.4).cgColor

        let code = NSTextField(labelWithString: hex)
        code.font = .monospacedSystemFont(ofSize: 15, weight: .medium)
        code.textColor = .white
        let content = NSStackView(views: [label, swatch, code])
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 10
        content.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(content)
        NSLayoutConstraint.activate([
            swatch.widthAnchor.constraint(equalToConstant: 16),
            swatch.heightAnchor.constraint(equalToConstant: 16),
            content.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            content.centerYAnchor.constraint(equalTo: background.centerYAnchor)
        ])
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: visible.midX - panel.frame.width / 2,
                                         y: visible.midY - panel.frame.height / 2))
        } else { panel.center() }
        copyNotice = panel
        panel.orderFrontRegardless()
        let dismissal = DispatchWorkItem { [weak self, weak panel] in
            panel?.orderOut(nil)
            if self?.copyNotice === panel { self?.copyNotice = nil }
        }
        dismissNotice = dismissal
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: dismissal)
    }
    @objc func startScreenshotPicking() {
        guard !samplerActive, !capturing, overlays.isEmpty else { return }
        dismissCopyNotice()
        // A previous denial is recoverable. Tear down that attempt and try
        // again instead of permanently latching onto the Settings screen.
        if showingPermissionHelp { finish(nil) }
        let session = UUID()
        pickSession = session
        capturing = true
        // Escape covers setup as well as capture, from the instant the
        // shortcut is pressed, before any focus or permission work.
        installCancellation()
        showingPermissionHelp = false
        permissionLabel?.stringValue = ""
        permissionButton?.isHidden = true
        welcome?.contentView?.subviews.first(where: { $0.identifier?.rawValue == "pickButton" })?.isHidden = false
        // Leave window focus and Spaces untouched until pixels are frozen.
        // Capture inside this process so permission belongs to PixelDrop,
        // rather than a command-line screenshot subprocess.
        Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
                guard self.pickSession == session else { return }
                let provider = self.captureProvider ?? Self.captureAllScreens
                let captures = try await provider()
                guard self.pickSession == session else { return }
                self.capturing = false
                self.showOverlays(captures)
            } catch {
                guard self.pickSession == session else { return }
                self.finish(nil)
                let alert = NSAlert()
                let captureError = error as NSError
                if captureError.domain == SCStreamErrorDomain && captureError.code == -3801 {
                    self.showPermissionHelp()
                } else {
                    alert.messageText = "Could not capture the screen"
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
            }
        }
    }
    @MainActor static func captureAllScreens() async throws -> [(NSScreen, NSBitmapImageRep)] {
        // ScreenCaptureKit handles authorization itself. A cached CG preflight
        // result is not allowed to prevent a real capture attempt.
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        var captures: [(NSScreen, NSBitmapImageRep)] = []
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let display = content.displays.first(where: { $0.displayID == number.uint32Value }) else {
                throw NSError(domain: "PixelDrop", code: 1, userInfo: [NSLocalizedDescriptionKey: "A display disconnected. Please try again."])
            }
            let configuration = SCStreamConfiguration()
            configuration.width = CGDisplayPixelsWide(display.displayID)
            configuration.height = CGDisplayPixelsHigh(display.displayID)
            configuration.showsCursor = false
            // Explicitly capture all other applications, including normal
            // windows. Excluding this app also removes our welcome UI
            // without hiding it and changing Stage Manager/Space focus.
            let ownApplications = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            let filter = SCContentFilter(display: display, excludingApplications: ownApplications, exceptingWindows: [])
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            captures.append((screen, NSBitmapImageRep(cgImage: image)))
        }
        return captures
    }
    func showPermissionHelp() {
        if pickSession == nil {
            pickSession = UUID()
            installCancellation()
        }
        showingPermissionHelp = true
        status?.button?.title = "PixelDrop !"
        permissionLabel?.stringValue = "Frozen capture was denied by macOS. Pick a color and ⌘⇧2 use the system eyedropper instead. Esc closes this message."
        permissionButton?.isHidden = false
        welcome?.contentView?.subviews.first(where: { $0.identifier?.rawValue == "pickButton" })?.isHidden = false
        welcome?.makeKeyAndOrderFront(nil)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        welcome?.makeKeyAndOrderFront(nil)
        return true
    }
    @objc func openScreenRecordingSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
    func showOverlays(_ captures: [(NSScreen, NSBitmapImageRep)]) {
        for (screen, bitmap) in captures {
            let window = OverlayWindow(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.becomesKeyOnlyIfNeeded = false
            window.hidesOnDeactivate = false
            window.level = .screenSaver; window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; window.isReleasedWhenClosed = false
            let view = PickerView(frame: NSRect(origin: .zero, size: screen.frame.size), bitmap: bitmap)
            let mouse = NSEvent.mouseLocation
            view.pointer = NSPoint(x: mouse.x - screen.frame.minX, y: screen.frame.maxY - mouse.y)
            view.onPick = { [weak self] hex in self?.finish(hex) }; view.onCancel = { [weak self] in self?.finish(nil) }
            window.contentView = view; window.acceptsMouseMovedEvents = true; overlays.append(window)
            window.makeKeyAndOrderFront(nil); window.makeFirstResponder(view)
        }
        // Nonactivating panels receive keyboard focus without activating
        // PixelDrop, which could switch Spaces or rearrange Stage Manager.
        welcome?.orderOut(nil)
        if let window = overlays.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) { window.makeKeyAndOrderFront(nil) }
        NSCursor.crosshair.push()
        cursorPushed = true
    }
    func installCancellation() {
        // Register before capture starts, including the delay and async work.
        let result = RegisterEventHotKey(UInt32(kVK_Escape), 0, EventHotKeyID(signature: 0x5049584C, id: 2), GetApplicationEventTarget(), 0, &escapeHotkey)
        if result != noErr { NSLog("Escape hotkey registration failed: %d; panel keyboard handling remains enabled", result) }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.pickSession != nil, event.keyCode == UInt16(kVK_Escape) else { return event }
            self.finish(nil)
            return nil
        }
    }
    func finish(_ hex: String?) {
        guard pickSession != nil else { return }
        pickSession = nil
        capturing = false
        if showingPermissionHelp { welcome?.orderOut(nil); showingPermissionHelp = false }
        if let hotkey = escapeHotkey { UnregisterEventHotKey(hotkey); escapeHotkey = nil }
        if let monitor = keyMonitor { NSEvent.removeMonitor(monitor); keyMonitor = nil }
        for window in overlays { window.orderOut(nil) }; overlays.removeAll()
        if cursorPushed { NSCursor.pop(); cursorPushed = false }
        if let hex = hex {
            copyHex(hex)
        }
    }
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
