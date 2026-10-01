import AppKit
import ServiceManagement

// ScreenshotToggle — a menu bar item that opens and closes Apple's Screenshot palette.
//
// Screenshot.app is only a launcher: it spawns `/usr/sbin/screencapture` (the interactive
// palette) plus the resident `screencaptureui` service and then exits. So "is the palette
// open?" means "is there a live /usr/sbin/screencapture process?", and closing it means
// terminating that process — the same thing Escape does, with no Accessibility permission
// needed. Cmd-Shift-3/4/5 spawn the same process, so the toggle also closes a palette the
// user opened from the keyboard.

private let screenshotAppURL = URL(fileURLWithPath: "/System/Applications/Utilities/Screenshot.app")

@discardableResult
private func run(_ path: String, _ args: [String]) -> (status: Int32, out: String) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: path)
    task.arguments = args
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    do { try task.run() } catch { return (-1, "") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    return (task.terminationStatus, String(decoding: data, as: UTF8.self))
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var pollTimer: Timer?
    private var menu: NSMenu!
    private let toggleItem = NSMenuItem(title: "Open Screenshot", action: #selector(toggle), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Open at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        menu = NSMenu()
        toggleItem.target = self
        menu.addItem(toggleItem)
        menu.addItem(.separator())
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(NSMenuItem(title: "Quit ScreenshotToggle", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        refresh()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    // MARK: - Palette state

    /// PIDs of live *interactive* `screencapture` processes.
    ///
    /// Only interactive invocations own the palette, and they are the ones carrying an `i`
    /// flag (the launcher runs `screencapture -zsuis_msg-… -uUpi`). Scripted captures such as
    /// `screencapture -x out.png` must not count, or an unrelated script would make the icon
    /// flicker and a click would "close" something the user never opened.
    private func palettePIDs() -> [Int32] {
        let result = run("/bin/ps", ["-axo", "pid=,args="])
        var pids: [Int32] = []
        for line in result.out.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 2, let pid = Int32(fields[0]),
                  fields[1].hasSuffix("/screencapture") || fields[1] == "screencapture" else { continue }
            let interactive = fields.dropFirst(2).contains { $0.hasPrefix("-") && $0.dropFirst().contains("i") }
            if interactive { pids.append(pid) }
        }
        return pids
    }

    private var paletteIsOpen: Bool { !palettePIDs().isEmpty }

    /// Last moment the palette was observed open. Clicking the menu bar is a click *outside*
    /// the palette, which makes macOS dismiss it before this app's action method runs — so a
    /// naive check always reads "closed" and the toggle would reopen what the user meant to
    /// close. Treat a very recent sighting as still-open.
    private var lastSeenOpen = Date.distantPast
    private var paletteWasJustOpen: Bool { Date().timeIntervalSince(lastSeenOpen) < 1.5 }

    private func refresh() {
        let open = paletteIsOpen
        if open { lastSeenOpen = Date() }
        let symbol = open ? "camera.viewfinder" : "camera"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Screenshot")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = open ? "Screenshot is open — click to close" : "Click to open Screenshot"
        toggleItem.title = open ? "Close Screenshot" : "Open Screenshot"
        loginItem.state = launchAtLoginEnabled ? .on : .off
    }

    // MARK: - Actions

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            toggle()
        }
    }

    @objc private func toggle() {
        if paletteIsOpen || paletteWasJustOpen { closePalette() } else { openPalette() }
        // Give the process table a moment to settle before repainting the icon.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.refresh() }
    }

    private func openPalette() {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: screenshotAppURL, configuration: config)
    }

    private func closePalette() {
        for pid in palettePIDs() { kill(pid, SIGTERM) }
        lastSeenOpen = .distantPast
    }

    // MARK: - Login item

    private var launchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if launchAtLoginEnabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change the login item"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
        refresh()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
