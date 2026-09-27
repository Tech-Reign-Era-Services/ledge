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

    private var artwork: (track: String, url: String?) = ("", nil) // the playing track's album artwork, once fetched
    private var pending: Activity? // a new song, waiting a moment for its artwork
    private var pendingWork: DispatchWorkItem?
    static let artworkWait = 0.6

    func start() {
        let center = DistributedNotificationCenter.default()
        // Music: the players announce every change to the whole system. No permission needed.
        for p in ActivityCenter.players {
            center.addObserver(forName: Notification.Name(p.notification), object: nil, queue: .main) { [weak self] n in
                let info = (n.userInfo ?? [:]).reduce(into: [String: Any]()) { d, kv in if let k = kv.key as? String { d[k] = kv.value } }
                self?.music(info, app: p.app, bundleID: p.bundleID)
            }
        }
        // The players only announce changes: ask the ones already running what's playing now.
        for p in ActivityCenter.players where NSRunningApplication.runningApplications(withBundleIdentifier: p.bundleID).count > 0 {
            Artwork.nowPlaying(bundleID: p.bundleID) { [weak self] info in
                guard let self, let info, !self.list.contains(where: { $0.id == "music" }) else { return }
                self.music(info, app: p.app, bundleID: p.bundleID)
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
        guard var a = Activities.music(info, app: app, bundleID: bundleID, now: now) else {
            if list.first(where: { $0.id == "music" })?.source == app || pending?.source == app { // only the player that was showing can end it
                pending = nil; pendingWork?.cancel()
                apply(.end("music"))
            }
            return
        }
        let track = "\(bundleID)|\(a.title)|\(a.subtitle)"
        if artwork.track == track { a.art = artwork.url }
        // A new song: hold it until its artwork arrives (or a moment has passed), so the island changes once, not twice.
        if artwork.track != track {
            artwork = (track, nil)
            pending = a
            pendingWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.showPending() }
            pendingWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + ActivityCenter.artworkWait, execute: work)
            guard Prefs.showArtwork else { return showPending() }
            Artwork.fetch(bundleID: bundleID) { [weak self] url in
                guard let self, self.artwork.track == track else { return }
                self.artwork.url = url
                if var p = self.pending { p.art = url; self.pending = p; self.showPending() }
                else if let url, var m = self.list.first(where: { $0.id == "music" }), m.source == app { m.art = url; self.apply(.upsert(m)) }
            }
            return
        }
        if pending != nil { pending = a; return } // the same song again, while its artwork is on the way
        // Players announce each change two or three times over: only show what's actually different.
        if let m = list.first(where: { $0.id == "music" }), Activities.sameMusic(m, a, now: now) { return }
        apply(.upsert(a))
    }

    private func showPending() {
        pendingWork?.cancel(); pendingWork = nil
        guard let p = pending else { return }
        pending = nil
        apply(.upsert(p))
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

/// The playing track's album artwork, as a small data URL. Music hands over the image itself; Spotify, a link to it.
/// Both through AppleScript, like the controls (macOS asks once).
enum Artwork {
    private static let queue = DispatchQueue(label: "ledge.artwork")

    static func fetch(bundleID: String, done: @escaping (String?) -> Void) {
        queue.async {
            let finish = { (url: String?) in DispatchQueue.main.async { done(url) } }
            switch bundleID {
            case "com.apple.Music":
                let file = FileManager.default.temporaryDirectory.appendingPathComponent("ledge-artwork-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: file) }
                let script = """
                tell application id "com.apple.Music"
                    if (count of artworks of current track) is 0 then return ""
                    set d to raw data of artwork 1 of current track
                end tell
                set f to open for access (POSIX file "\(file.path)") with write permission
                set eof f to 0
                write d to f
                close access f
                return "ok"
                """
                guard run(script) == "ok", let image = NSImage(contentsOf: file) else { return finish(nil) }
                finish(dataURL(image))
            case "com.spotify.client":
                guard let link = run("tell application id \"com.spotify.client\" to return artwork url of current track"),
                      let url = URL(string: link), url.scheme == "https" else { return finish(nil) }
                var request = URLRequest(url: url, timeoutInterval: 8)
                request.cachePolicy = .returnCacheDataElseLoad
                URLSession.shared.dataTask(with: request) { data, _, _ in
                    guard let data, data.count < 4_000_000, let image = NSImage(data: data) else { return finish(nil) }
                    finish(dataURL(image))
                }.resume()
            default:
                finish(nil)
            }
        }
    }

    /// What a running player is playing right now, in the shape of its own notifications' userInfo.
    static func nowPlaying(bundleID: String, done: @escaping ([String: Any]?) -> Void) {
        queue.async {
            // Tab-separated: state, name, artist, album, duration (s), position (s). Spotify's duration is in ms.
            let script = """
            tell application id "\(bundleID)"
                if player state is stopped then return ""
                set t to current track
                set n to name of t
                set ar to artist of t
                set al to album of t
                set d to duration of t
                set pos to player position
                return (player state as text) & tab & n & tab & ar & tab & al & tab & (d as text) & tab & (pos as text)
            end tell
            """
            let parts = run(script)?.components(separatedBy: "\t") ?? []
            guard parts.count == 6, parts[0] == "playing" || parts[0] == "paused" else { return DispatchQueue.main.async { done(nil) } }
            let number = { (s: String) in Double(s.replacingOccurrences(of: ",", with: ".")) ?? 0 }
            let ms = bundleID == "com.spotify.client" ? number(parts[4]) : number(parts[4]) * 1000
            let info: [String: Any] = ["Player State": parts[0] == "playing" ? "Playing" : "Paused", "Name": parts[1], "Artist": parts[2],
                                       "Album": parts[3], "Total Time": ms, "Playback Position": number(parts[5])]
            DispatchQueue.main.async { done(info) }
        }
    }

    /// Runs an AppleScript and returns what it printed, or nil if it failed.
    private static func run(_ script: String) -> String? {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Cropped square and drawn at 96 px: enough for the 40 pt row at 2×, a few KB as JPEG.
    private static func dataURL(_ image: NSImage) -> String? {
        let px = 96
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        let s = image.size, scale = max(CGFloat(px) / max(s.width, 1), CGFloat(px) / max(s.height, 1))
        let w = s.width * scale, h = s.height * scale
        image.draw(in: NSRect(x: (CGFloat(px) - w) / 2, y: (CGFloat(px) - h) / 2, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]).map { "data:image/jpeg;base64," + $0.base64EncodedString() }
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
