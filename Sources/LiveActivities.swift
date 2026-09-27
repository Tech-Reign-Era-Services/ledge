import AppKit

// Keeps the list of live activities: music that's playing, and whatever other apps post. The rules for what's
// accepted live in Activities.swift; this listens, keeps time, draws icons and runs the music controls.

final class ActivityCenter {
    static let notification = Notification.Name("com.techreignera.ledge.activity")

    private(set) var list: [Activity] = []
    var onChange: ((_ started: Bool) -> Void)? // started: something new appeared (the island gives a little bump)
    private var expiry: Timer?
    private var lastPost: [String: Double] = [:] // per activity, to ignore floods
    private static let players: [(notification: String, app: String, bundleID: String)] = [
        ("com.apple.Music.playerInfo", "Music", "com.apple.Music"),
        ("com.spotify.client.PlaybackStateChanged", "Spotify", "com.spotify.client"),
    ]

    func start() {
        let center = DistributedNotificationCenter.default()
        // Music: the players announce every change to the whole system. No permission needed.
        for p in ActivityCenter.players {
            center.addObserver(forName: Notification.Name(p.notification), object: nil, queue: .main) { [weak self] n in
                let info = (n.userInfo ?? [:]).reduce(into: [String: Any]()) { d, kv in if let k = kv.key as? String { d[k] = kv.value } }
                self?.music(info, app: p.app, bundleID: p.bundleID)
            }
        }
        // Other apps: a JSON object as the notification's object (sandboxed apps can't send userInfo).
        center.addObserver(forName: ActivityCenter.notification, object: nil, queue: .main) { [weak self] n in
            guard let json = n.object as? String, json.utf8.count <= 4096, let data = json.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            let fields = obj.reduce(into: [String: String]()) { d, kv in
                if let s = kv.value as? String { d[kv.key] = s } else if let n = kv.value as? NSNumber { d[kv.key] = n.stringValue }
            }
            self?.request(fields)
        }
    }

    /// A request from another app, from ledge://activity or a distributed notification.
    func request(_ fields: [String: String], end: Bool = false) {
        let now = ActivityCenter.now()
        let key = "app:" + (fields["id"] ?? "")
        // At most 20 updates a second per activity: a runaway script can't keep the island busy.
        if !end, let last = lastPost[key], now - last < 50 { return }
        lastPost[key] = now
        guard let r = Activities.parse(fields, end: end, existing: list.first { $0.id == key }, now: now) else { return }
        apply(r)
    }

    private func music(_ info: [String: Any], app: String, bundleID: String) {
        let now = ActivityCenter.now()
        if let a = Activities.music(info, app: app, bundleID: bundleID, now: now) { apply(.upsert(a)) }
        else if list.first(where: { $0.id == "music" })?.source == app { apply(.end("music")) } // only the player that was showing can end it
    }

    private func apply(_ r: ActivityRequest) {
        let before = Set(list.map(\.id))
        list = Activities.apply(r, to: list)
        scheduleExpiry()
        onChange?(!Set(list.map(\.id)).isSubset(of: before))
    }

    private func scheduleExpiry() {
        expiry?.invalidate()
        guard let next = list.map(\.expires).min(), next.isFinite else { return }
        let wait = max(0.1, (next - ActivityCenter.now()) / 1000)
        expiry = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in
            guard let self, let kept = Activities.prune(self.list, now: ActivityCenter.now() + 50) else { self?.scheduleExpiry(); return }
            self.list = kept
            self.scheduleExpiry()
            self.onChange?(false)
        }
        expiry?.tolerance = 1
    }

    static func now() -> Double { (Date().timeIntervalSince1970 * 1000).rounded() }

    // ---------- what the page gets ----------

    func json() -> [[String: Any]] { list.map { $0.json(icon: ActivityIcons.icon(for: $0)) } }

    // ---------- clicks ----------

    func perform(_ id: String, action: String) {
        guard let a = list.first(where: { $0.id == id }) else { return }
        switch (a.kind, action) {
        case ("music", "playpause"), ("music", "next"), ("music", "previous"):
            let command = ["playpause": "playpause", "next": "next track", "previous": "previous track"][action]!
            MusicControl.send(command, to: a.bundleID ?? "com.apple.Music")
            if action == "playpause", var m = list.first, m.id == "music" {
                // Show the change straight away; the player's own announcement follows and corrects it if needed.
                let now = ActivityCenter.now()
                if let e = m.elapsed, m.playing == true { m.elapsed = e + (now - m.at) / 1000 }
                m.playing = !(m.playing ?? false)
                m.at = now
                apply(.upsert(m))
            }
        case ("music", "open"):
            if let b = a.bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b) { NSWorkspace.shared.open(url) }
        case ("custom", "open"):
            if let link = a.link, let url = URL(string: link) { NSWorkspace.shared.open(url) }
        case (_, "dismiss"):
            apply(.end(id))
        default: break
        }
    }
}

/// Play, pause and skip through AppleScript: macOS asks once, the first time you use a control.
enum MusicControl {
    private static let queue = DispatchQueue(label: "ledge.music")

    static func send(_ command: String, to bundleID: String) {
        // Only players that are installed: otherwise AppleScript asks "Where is …?".
        guard bundleID.range(of: #"^[A-Za-z0-9.-]+$"#, options: .regularExpression) != nil,
              NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil else { return }
        queue.async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", "tell application id \"\(bundleID)\" to \(command)"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
        }
    }
}

/// App icons and SF Symbols, drawn once as PNG data URLs for the page.
enum ActivityIcons {
    private static var cache: [String: String] = [:]

    static func icon(for a: Activity) -> String? {
        if a.emoji != nil { return nil }
        if let s = a.symbol { return symbol(s, tint: a.tint) ?? app(a.bundleID) }
        // The player's icon, or a note when it can't be found.
        return app(a.bundleID) ?? (a.kind == "music" ? symbol("music.note", tint: "#8ea2ff") : nil)
    }

    static func app(_ bundleID: String?) -> String? {
        guard let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let key = "app:" + bundleID
        if let hit = cache[key] { return hit }
        let result = dataURL(NSWorkspace.shared.icon(forFile: url.path), points: 44)
        cache[key] = result
        return result
    }

    static func symbol(_ name: String, tint: String?) -> String? {
        let key = "sym:\(name):\(tint ?? "")"
        if let hit = cache[key] { return hit }
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        let config = NSImage.SymbolConfiguration(pointSize: 30, weight: .semibold)
            .applying(.init(paletteColors: [color(tint) ?? .white]))
        guard let image = base.withSymbolConfiguration(config) else { return nil }
        let result = dataURL(image, points: 44)
        cache[key] = result
        return result
    }

    private static func color(_ hex: String?) -> NSColor? {
        guard let hex, hex.count == 7, let v = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    /// Drawn at 2× into a square, the image centred and scaled to fit.
    private static func dataURL(_ image: NSImage, points: CGFloat) -> String? {
        let px = Int(points * 2)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let s = image.size, scale = min(CGFloat(px) / max(s.width, 1), CGFloat(px) / max(s.height, 1))
        let w = s.width * scale, h = s.height * scale
        image.draw(in: NSRect(x: (CGFloat(px) - w) / 2, y: (CGFloat(px) - h) / 2, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:]).map { "data:image/png;base64," + $0.base64EncodedString() }
    }
}
