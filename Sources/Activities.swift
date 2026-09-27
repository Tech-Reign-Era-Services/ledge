import Foundation

// Live activities: things happening right now that the island shows, like the Dynamic Island on iPhone.
// Music comes from Apple Music and Spotify; any other app can post its own (see the README). Everything that
// arrives from outside is untrusted, so it's validated and trimmed here. Foundation only (tested in tests/).

struct Activity: Equatable {
    var id: String // "music", or "app:<id>" for one posted by another app
    var kind: String // "music" | "custom"
    var source: String // who it's from, shown small: "Music", "Spotify", "Xcode"…
    var title: String
    var subtitle: String = ""
    var symbol: String? // an SF Symbol name, drawn by the app (custom)
    var emoji: String? // …or an emoji
    var bundleID: String? // whose app icon to show
    var progress: Double? // 0…1, drawn as a ring (compact) or a bar (expanded)
    var trailing: String? // a few characters beside the island when it's closed, e.g. "2:15" or "80%"
    var tint: String? // #rrggbb for the ring, bar and symbol
    var link: String? // opened when the activity is clicked (custom)
    var playing: Bool? // music
    var elapsed: Double? // music: seconds into the track at `at`
    var duration: Double? // music: seconds
    var at: Double = 0 // when this was last updated, ms since 1970
    var expires: Double = .infinity // ms since 1970

    /// What the page reads. `icon` (a data URL) is added by the app, which draws symbols and app icons.
    func json(icon: String?) -> [String: Any] {
        var d: [String: Any] = ["id": id, "kind": kind, "source": source, "title": title, "subtitle": subtitle, "at": at]
        if let icon { d["icon"] = icon }
        if let emoji { d["emoji"] = emoji }
        if let progress { d["progress"] = progress }
        if let trailing { d["trailing"] = trailing }
        if let tint { d["tint"] = tint }
        if link != nil { d["link"] = true } // the page only needs to know it's clickable, never the URL
        if let playing { d["playing"] = playing }
        if let elapsed { d["elapsed"] = elapsed }
        if let duration { d["duration"] = duration }
        return d
    }
}

enum ActivityRequest: Equatable {
    case upsert(Activity) // start one, or update the one with the same id (fields left out stay as they were)
    case end(String)
}

enum Activities {
    static let maxCustom = 4
    static let defaultTTL = 10 * 60.0 // an activity nobody ends goes away by itself after 10 minutes…
    static let maxTTL = 24 * 60 * 60.0 // …or at most a day, if it asks for longer
    static let pausedTTL = 10 * 60.0 // paused music stays for 10 minutes

    // ---------- from other apps ----------

    /// Parse a request from another app: the query of `ledge://activity?…` / `ledge://activity/end?…`, or the JSON
    /// object of a distributed notification. `existing` is the activity it would update, if there is one.
    static func parse(_ f: [String: String], end: Bool = false, existing: Activity? = nil, now: Double) -> ActivityRequest? {
        guard let rawID = f["id"], let id = clean(rawID, max: 40), rawID.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil else { return nil }
        let key = "app:" + id
        if end || f["action"] == "end" { return .end(key) }

        var a = existing ?? Activity(id: key, kind: "custom", source: "App", title: "")
        if let v = f["title"] { a.title = clean(v, max: 60) ?? "" }
        if let v = f["subtitle"] { a.subtitle = clean(v, max: 80) ?? "" }
        if let v = f["source"] { a.source = clean(v, max: 30) ?? a.source }
        if let v = f["symbol"] { a.symbol = v.range(of: #"^[a-z0-9.]{1,60}$"#, options: .regularExpression) != nil ? v : nil }
        if let v = f["emoji"] { a.emoji = isEmoji(v) ? v : nil }
        if let v = f["bundle"] { a.bundleID = v.range(of: #"^[A-Za-z0-9.-]{1,100}$"#, options: .regularExpression) != nil ? v : nil }
        if let v = f["progress"] { a.progress = Double(v).map { min(1, max(0, $0)) } }
        if let v = f["trailing"] { a.trailing = clean(v, max: 8) }
        if let v = f["tint"] { a.tint = v.range(of: #"^#[0-9A-Fa-f]{6}$"#, options: .regularExpression) != nil ? v : nil }
        if let v = f["link"] { a.link = safeLink(v) }
        guard !a.title.isEmpty else { return nil } // nothing to show
        let ttl = f["ttl"].flatMap(Double.init).map { min(maxTTL, max(1, $0)) } ?? (existing == nil ? defaultTTL : nil)
        if let ttl { a.expires = now + ttl * 1000 }
        a.at = now
        return .upsert(a)
    }

    /// Links an activity may open: web pages and apps' own URL schemes. Never files or scripts.
    static func safeLink(_ s: String) -> String? {
        guard s.count <= 500, let u = URLComponents(string: s), let scheme = u.scheme?.lowercased() else { return nil }
        if ["file", "javascript", "data", "about", "blob", "ledge"].contains(scheme) { return nil }
        return s
    }

    static func isEmoji(_ s: String) -> Bool {
        s.count >= 1 && s.count <= 2 && s.unicodeScalars.contains { $0.properties.isEmojiPresentation || $0.properties.isEmoji && $0.value > 0xFF }
    }

    /// Trimmed, without control characters, at most `max` characters. nil when nothing is left.
    static func clean(_ s: String, max: Int) -> String? {
        let t = String(String(s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }).trimmingCharacters(in: .whitespaces).prefix(max))
        return t.isEmpty ? nil : t
    }

    // ---------- music ----------

    /// Apple Music ("com.apple.Music.playerInfo") and Spotify ("com.spotify.client.PlaybackStateChanged") tell the
    /// whole system about every change. nil means nothing is playing any more.
    static func music(_ info: [String: Any], app: String, bundleID: String, now: Double) -> Activity? {
        let state = info["Player State"] as? String ?? ""
        guard state == "Playing" || state == "Paused", let name = info["Name"] as? String, let title = clean(name, max: 80) else { return nil }
        let artist = (info["Artist"] as? String).flatMap { clean($0, max: 80) }
        let album = (info["Album"] as? String).flatMap { clean($0, max: 80) }
        var a = Activity(id: "music", kind: "music", source: app, title: title, subtitle: [artist, album].compactMap { $0 }.joined(separator: " — "))
        a.bundleID = bundleID
        a.playing = state == "Playing"
        // Durations arrive in milliseconds ("Total Time" from Music, "Duration" from Spotify), positions in seconds.
        if let ms = number(info["Total Time"] ?? info["Duration"]), ms > 0 { a.duration = ms / 1000 }
        if let pos = number(info["Playback Position"]), pos >= 0 { a.elapsed = pos }
        a.at = now
        a.expires = a.playing == true ? .infinity : now + pausedTTL * 1000
        return a
    }

    private static func number(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }

    // ---------- the list ----------

    /// Apply a request to the list: newest custom activities first, music always first, at most maxCustom of the rest.
    static func apply(_ r: ActivityRequest, to list: [Activity]) -> [Activity] {
        switch r {
        case .end(let id):
            return list.filter { $0.id != id }
        case .upsert(let a):
            var rest = list.filter { $0.id != a.id }
            if a.kind == "music" { return [a] + rest }
            let music = rest.filter { $0.kind == "music" }
            rest = rest.filter { $0.kind != "music" }
            return music + Array(([a] + rest).prefix(maxCustom))
        }
    }

    /// Drop the ones that have expired. Returns nil when nothing changed.
    static func prune(_ list: [Activity], now: Double) -> [Activity]? {
        let kept = list.filter { $0.expires > now }
        return kept.count == list.count ? nil : kept
    }
}
