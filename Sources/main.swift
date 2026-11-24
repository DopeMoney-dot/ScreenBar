import AppKit
import ServiceManagement

// ScreenBar — a menu bar item that opens and closes Apple's Screenshot palette.
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
        menu.addItem(NSMenuItem(title: "Quit ScreenBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

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

    /// macOS stages an in-progress recording as `<UUID>.mov` here and only moves it to the save
    /// location when Apple's own Stop button is used.
    private let stagingDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Group Containers/group.com.apple.screencapture/ScreenRecordings")

    /// The staged file being written right now (modified within the last 3 s), if any.
    private func activeRecording() -> URL? {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: stagingDir, includingPropertiesForKeys: keys)) ?? []
        return files.filter { $0.pathExtension == "mov" }
            .compactMap { f -> (URL, Date)? in
                guard let d = try? f.resourceValues(forKeys: Set(keys)).contentModificationDate else { return nil }
                return (f, d)
            }
            .filter { Date().timeIntervalSince($0.1) < 3 }
            .max { $0.1 < $1.1 }?.0
    }

    private func saveFolder() -> URL {
        let out = run("/usr/bin/defaults", ["read", "com.apple.screencapture", "location"]).out
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !out.isEmpty {
            let url = URL(fileURLWithPath: (out as NSString).expandingTildeInPath)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
    }

    private func closePalette() {
        // A click on this icon while recording is almost always meant as "stop". Killing the
        // recorder this way skips Apple's hand-off, which strands the finished movie in the
        // staging folder. So: stop it, then do the hand-off ourselves.
        let recording = activeRecording()
        // SIGINT, not SIGTERM: SIGTERM discards an in-progress recording.
        for pid in palettePIDs() { kill(pid, SIGINT) }
        lastSeenOpen = .distantPast
        if let recording { DispatchQueue.global().async { [weak self] in self?.deliver(recording) } }
    }

    /// Wait for the recorder to exit and the file to stop growing, then move it to the save folder.
    private func deliver(_ staged: URL) {
        var lastSize = -1
        for _ in 0..<40 {                       // up to ~10 s
            Thread.sleep(forTimeInterval: 0.25)
            let size = (try? staged.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
            if palettePIDs().isEmpty && size == lastSize && size > 0 { break }
            lastSize = size
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' h.mm.ss a"
        let dir = saveFolder()
        var dest = dir.appendingPathComponent("Screen Recording \(f.string(from: Date())).mov")
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = dir.appendingPathComponent("Screen Recording \(f.string(from: Date())) \(n).mov"); n += 1
        }
        do { try FileManager.default.moveItem(at: staged, to: dest) }
        catch { NSLog("ScreenBar: could not move recording: \(error)") }
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

if let i = CommandLine.arguments.firstIndex(of: "--selftest"), i + 1 < CommandLine.arguments.count {
    // Diagnostic: report whether THIS app identity can read the recording staging folder.
    let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Group Containers/group.com.apple.screencapture/ScreenRecordings")
    var report = ""
    do { report = "ok: \(try FileManager.default.contentsOfDirectory(atPath: dir.path).count) entries\n" }
    catch { report = "ERROR: \(error)\n" }
    try? report.write(toFile: CommandLine.arguments[i + 1], atomically: true, encoding: .utf8)
    exit(0)
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
