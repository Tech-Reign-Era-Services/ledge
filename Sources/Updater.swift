import AppKit
import CryptoKit

// Updates from inside the app. A check asks GitHub for the latest release (from the menu, or once a day if Settings
// allows); a newer one shows in the island. Updating downloads its installer, checks it against the SHA-256 digest
// GitHub gives, and opens it in Installer, which quits Ledge, puts the new one in /Applications and opens it again.
// What's on the Shelf is kept. What counts as a release is decided in Updates.swift.

final class Updater {
    static let activityID = "ledge:update" // other apps' activities are always "app:…", so they can't pose as this
    static let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    private static let downloads = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("com.techreignera.ledge/Updates")

    private(set) var available: Release? // newer than this one
    private(set) var busy = false // checking or downloading
    var onChange: (() -> Void)? // for the menu

    private let activities: ActivityCenter
    private let session = URLSession(configuration: .ephemeral) // nothing cached or kept
    private var timer: Timer?
    private var download: URLSessionDownloadTask?
    private var watch: NSKeyValueObservation?
    private var shown = -1.0 // download progress last shown, so the island redraws every 5%, not every packet

    init(activities: ActivityCenter) { self.activities = activities }

    func start() {
        try? FileManager.default.removeItem(at: Updater.downloads) // an installer from last time, now installed (or not wanted)
        // Soon after launch, then once a day. The hourly timer only compares two dates: the Mac may have slept.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.checkIfDue() }
        timer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in self?.checkIfDue() }
        timer?.tolerance = 10 * 60
    }

    private func checkIfDue() {
        guard Prefs.autoUpdate, Updates.due(lastCheck: Prefs.lastUpdateCheck, now: Date().timeIntervalSince1970) else { return }
        check(manual: false)
    }

    // ---------- checking ----------

    /// manual: from the menu or Settings, so say what was found, even "up to date".
    func check(manual: Bool) {
        guard !busy else { return }
        busy = true
        onChange?()
        var request = URLRequest(url: Updates.latestURL, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Ledge/\(Updater.current)", forHTTPHeaderField: "User-Agent") // GitHub asks for one
        session.dataTask(with: request) { [weak self] data, response, _ in
            let release = (response as? HTTPURLResponse)?.statusCode == 200 ? data.flatMap(Updates.parse) : nil
            DispatchQueue.main.async { self?.checked(release, manual: manual) }
        }.resume()
    }

    private func checked(_ release: Release?, manual: Bool) {
        busy = false
        if release != nil { Prefs.lastUpdateCheck = Date().timeIntervalSince1970 }
        available = release.flatMap { Updates.isNewer($0.version, than: Updater.current) ? $0 : nil }
        onChange?()
        if manual { return report(release == nil) }
        // Found by itself: say so once per version, in the island. The menu offers it until it's installed.
        guard let r = available, Prefs.announcedUpdate != r.version else { return }
        Prefs.announcedUpdate = r.version
        show(r, title: "Ledge \(r.version) is available", subtitle: "Click to update. You have \(Updater.current).", hours: 12)
    }

    private func report(_ failed: Bool) {
        let alert = NSAlert()
        if failed {
            alert.messageText = "Couldn't check for updates"
            alert.informativeText = "Check your internet connection and try again, or get the newest Ledge from its Releases page."
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Open Releases")
            if run(alert) == .alertSecondButtonReturn { NSWorkspace.shared.open(URL(string: "https://github.com/\(Updates.repo)/releases")!) }
        } else if let r = available {
            alert.messageText = "Ledge \(r.version) is available"
            alert.informativeText = "You have \(Updater.current). Updating downloads the installer and opens it: Ledge quits, updates and opens again. What's on your Shelf is kept."
            alert.addButton(withTitle: "Update")
            alert.addButton(withTitle: "Later")
            alert.addButton(withTitle: "What's New")
            switch run(alert) {
            case .alertFirstButtonReturn: install()
            case .alertThirdButtonReturn: NSWorkspace.shared.open(r.page)
            default: break
            }
        } else {
            alert.messageText = "Ledge is up to date"
            alert.informativeText = "\(Updater.current) is the newest version."
            alert.addButton(withTitle: "OK")
            run(alert)
        }
    }

    @discardableResult
    private func run(_ alert: NSAlert) -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal()
    }

    // ---------- updating ----------

    /// Download the newer release's installer, check it, and open it. Without one known yet, check first.
    func install() {
        guard let r = available else { return check(manual: true) }
        guard download == nil else { return }
        busy = true
        onChange?()
        shown = -1
        progress(r, 0)
        let task = session.downloadTask(with: r.pkg) { [weak self] file, response, _ in
            // The download is deleted once this returns: check it and keep it now.
            let pkg = (response as? HTTPURLResponse)?.statusCode == 200 ? file.flatMap { Updater.keep($0, r) } : nil
            DispatchQueue.main.async { self?.downloaded(pkg, r) }
        }
        watch = task.progress.observe(\.fractionCompleted) { [weak self] p, _ in
            let f = p.fractionCompleted
            DispatchQueue.main.async { self?.progress(r, f) }
        }
        download = task
        task.resume()
    }

    private func progress(_ r: Release, _ f: Double) {
        guard download != nil || f == 0, f - shown >= 0.05 || f == 0 else { return }
        shown = f
        show(r, title: "Downloading Ledge \(r.version)", subtitle: "The installer opens when it's done.", hours: 1, progress: f)
    }

    /// The installer, if it's exactly what GitHub said it would be: its size and SHA-256 digest.
    private static func keep(_ file: URL, _ r: Release) -> URL? {
        guard let data = try? Data(contentsOf: file), data.count == r.size, data.count <= Updates.maxSize,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == r.sha256 else { return nil }
        let pkg = downloads.appendingPathComponent("Ledge-\(r.version).pkg")
        do {
            try? FileManager.default.removeItem(at: downloads)
            try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
            try data.write(to: pkg)
            return pkg
        } catch { return nil }
    }

    private func downloaded(_ pkg: URL?, _ r: Release) {
        download = nil
        watch = nil
        busy = false
        onChange?()
        guard let pkg else {
            activities.end(Updater.activityID)
            let alert = NSAlert()
            alert.messageText = "The update couldn't be downloaded"
            alert.informativeText = "It didn't arrive, or wasn't exactly the installer GitHub lists, so it wasn't opened. Try again later, or download it from the release page."
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Open Release Page")
            if run(alert) == .alertSecondButtonReturn { NSWorkspace.shared.open(r.page) }
            return
        }
        show(r, title: "Installing Ledge \(r.version)", subtitle: "Follow the steps in Installer.", hours: 0.05, progress: 1)
        let installer = URL(fileURLWithPath: "/System/Library/CoreServices/Installer.app")
        NSWorkspace.shared.open([pkg], withApplicationAt: installer, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            guard error != nil else { return }
            DispatchQueue.main.async { NSWorkspace.shared.activateFileViewerSelecting([pkg]) } // open it from Finder instead
        }
    }

    /// The update in the island. Clicking it opens ledge://update, which comes back here as install().
    private func show(_ r: Release, title: String, subtitle: String, hours: Double, progress: Double? = nil) {
        let now = ActivityCenter.now()
        var a = Activity(id: Updater.activityID, kind: "custom", source: "Ledge", title: title, subtitle: subtitle)
        a.symbol = "arrow.down.circle" // one colour: the filled one would be a plain disc
        a.tint = "#7b96ff"
        a.progress = progress
        a.link = progress == nil ? "ledge://update" : nil
        a.at = now
        a.expires = now + hours * 3_600_000
        activities.post(a)
    }
}
