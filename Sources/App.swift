import AppKit
import Carbon.HIToolbox
import ServiceManagement

// Ledge: a Shelf in the notch. A menu bar app (no Dock icon) that holds files, text and links for a moment,
// so you can drop them somewhere else later.

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var island: Island!
    private let activities = ActivityCenter()
    private var hotKey: HotKey?
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let settings = SettingsWindow()
    private let defaults = UserDefaults.standard

    /// LEDGE_DATA_DIR=/tmp/ledge-dev keeps a development build's Shelf apart from the installed app's.
    static let sandboxed = ProcessInfo.processInfo.environment["LEDGE_DATA_DIR"] != nil
    static let dataDir = ProcessInfo.processInfo.environment["LEDGE_DATA_DIR"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Ledge")

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.register()
        importInletShelf()
        let store = ShelfStore(dir: AppDelegate.dataDir)
        let web = Bundle.main.resourceURL!.appendingPathComponent("web")
        island = Island(store: store, activities: activities, webRoot: web)
        activities.onChange = { [weak self] _ in self?.island.activitiesChanged() }
        activities.start()
        island.onChange = { [weak self] in self?.refreshIcon() }

        hotKey = HotKey(keyCode: kVK_ANSI_S, modifiers: controlKey | optionKey) { [weak self] in self?.island.toggle() }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = AppDelegate.menuBarIcon()
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.toolTip = "Ledge"
        menu.delegate = self
        statusItem.menu = menu
        refreshIcon()

        // First launch of the installed app: start with the Mac, as a notch utility is expected to. Easy to turn off
        // from the menu. A build run from anywhere else (dist/ while developing) leaves login items alone.
        if !defaults.bool(forKey: "launched"), Bundle.main.bundlePath.hasPrefix("/Applications/") {
            defaults.set(true, forKey: "launched")
            try? SMAppService.mainApp.register()
        }
    }

    func applicationWillTerminate(_ notification: Notification) { island?.cleanUp() }

    /// Files opened with Ledge (`open -a Ledge file…`, or dropped on its icon) go on the Shelf.
    /// ledge://activity?… and ledge://activity/end?… start, update and end another app's live activity.
    func application(_ sender: NSApplication, open urls: [URL]) {
        if urls.contains(where: { $0.scheme == "ledge" && $0.host == "settings" }) { settings.show() } // ledge://settings
        for url in urls where url.scheme == "ledge" && url.host == "activity" {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let fields = items.reduce(into: [String: String]()) { d, q in if let v = q.value { d[q.name] = v } }
            activities.request(fields, end: url.path == "/end")
        }
        let files = urls.filter(\.isFileURL).map(\.path)
        guard !files.isEmpty, let island else { return }
        island.addFiles(files)
        island.flash()
    }

    // ---------- menu bar ----------

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let n = island.store.items.count
        let show = NSMenuItem(title: n > 0 ? "Show Shelf (\(n))" : "Show Shelf", action: #selector(showShelf), keyEquivalent: hotKey?.ok == true ? "s" : "")
        show.keyEquivalentModifierMask = [.control, .option]
        menu.addItem(show)
        let clear = NSMenuItem(title: "Clear Shelf", action: n > 0 ? #selector(clearShelf) : nil, keyEquivalent: "")
        menu.addItem(clear)
        menu.addItem(.separator())
        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "About Ledge", action: #selector(about), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Quit Ledge", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) { item.target = self }
    }

    @objc private func showShelf() { island.show() }
    @objc private func showSettings() { settings.show() }
    @objc private func clearShelf() { island.clear() }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change Open at Login"
            alert.informativeText = "You can add Ledge yourself in System Settings › General › Login Items.\n\n\(error.localizedDescription)"
            alert.runModal()
        }
    }

    @objc private func about() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(string: "Keep files, text and links in the notch for a moment.\nHover over the notch, drag something to it, or press ⌃⌥S.",
                                         attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]),
        ])
    }

    private func refreshIcon() {
        let n = island?.store.items.count ?? 0
        statusItem?.button?.title = n > 0 ? " \(n)" : ""
    }

    /// The Shelf glyph from the page (a tray with a shelf across it), as a template image for the menu bar.
    static func menuBarIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            let s: CGFloat = 18.0 / 24.0
            NSColor.black.setStroke()
            let box = NSBezierPath(roundedRect: NSRect(x: 3 * s, y: 4 * s, width: 18 * s, height: 16 * s), xRadius: 2.5 * s, yRadius: 2.5 * s)
            let lines = NSBezierPath()
            lines.move(to: NSPoint(x: 3 * s, y: 12 * s)); lines.line(to: NSPoint(x: 21 * s, y: 12 * s))
            lines.move(to: NSPoint(x: 10 * s, y: 8 * s)); lines.line(to: NSPoint(x: 14 * s, y: 8 * s))
            lines.move(to: NSPoint(x: 10 * s, y: 16 * s)); lines.line(to: NSPoint(x: 14 * s, y: 16 * s))
            for p in [box, lines] { p.lineWidth = 1.5; p.lineCapStyle = .round; p.lineJoinStyle = .round; p.stroke() }
            return true
        }
        image.isTemplate = true
        return image
    }

    // ---------- moving over from Inlet ----------

    /// The Shelf used to live in Inlet: on first launch, bring across whatever is on it.
    private func importInletShelf() {
        guard !AppDelegate.sandboxed else { return }
        let fm = FileManager.default
        let mine = AppDelegate.dataDir.appendingPathComponent("shelf.json")
        guard !fm.fileExists(atPath: mine.path) else { return }
        let inlet = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Inlet/shelf.json")
        guard fm.fileExists(atPath: inlet.path) else { return }
        try? fm.createDirectory(at: AppDelegate.dataDir, withIntermediateDirectories: true)
        try? fm.copyItem(at: inlet, to: mine)
    }
}
