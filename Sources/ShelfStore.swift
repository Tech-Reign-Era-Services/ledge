import Foundation

// What's on the Shelf. Files are kept by reference (never copied or moved); text and links are stored here.
// Pictures pasted in (from a note or a web page, with text around them) become clippings: image files Ledge writes
// in its own Clips folder and deletes when they leave the Shelf, so they can go wherever files go (a remote desktop
// passes files, but not pictures inside text). Foundation only, so tests/ can compile it without AppKit. The file
// format is the one Inlet's Shelf used.

struct ShelfItem: Codable, Equatable {
    var id: String
    var kind: String // "file" | "text" | "link"
    var name: String
    var path: String?
    var isDir: Bool?
    var text: String?
    var addedAt: Double
    var clip: Bool? = nil // a clipping: Ledge's own file in Clips/<id>/, deleted with the item
}

/// A piece of what was pasted or dropped, in reading order.
enum ClipPart: Equatable {
    case text(String)
    case image(Data, ext: String) // "png" or "jpg"
}

final class ShelfStore {
    static let maxItems = 100
    static let maxText = 20000 // characters kept from one text drop
    static let maxClips = 30 // pictures kept from one paste
    static let maxClipSize = 40_000_000

    let file: URL
    let clips: URL // Clips/<item id>/Image 1.png
    private(set) var items: [ShelfItem] = []

    init(dir: URL) {
        file = dir.appendingPathComponent("shelf.json")
        clips = dir.appendingPathComponent("Clips")
        items = ShelfStore.load(file)
        // Clippings whose item is gone (removed while Ledge wasn't running, or a damaged shelf.json): delete them.
        let kept = Set(items.filter { $0.clip == true }.map(\.id))
        for name in (try? FileManager.default.contentsOfDirectory(atPath: clips.path)) ?? [] where !kept.contains(name) {
            try? FileManager.default.removeItem(at: clips.appendingPathComponent(name))
        }
    }

    static func load(_ file: URL) -> [ShelfItem] {
        guard let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = root["items"] as? [Any] else { return [] }
        // One damaged entry shouldn't cost the rest.
        return raw.compactMap { entry in
            guard entry is [String: Any], let d = try? JSONSerialization.data(withJSONObject: entry),
                  let it = try? JSONDecoder().decode(ShelfItem.self, from: d) else { return nil }
            return (it.kind == "file" ? !(it.path ?? "").isEmpty : !(it.text ?? "").isEmpty) ? it : nil
        }
    }

    func get(_ ids: [String]) -> [ShelfItem] {
        let want = Set(ids)
        return items.filter { want.contains($0.id) }
    }

    /// Add files and folders by path, newest first. A path already on the Shelf moves to the front.
    @discardableResult
    func addFiles(_ paths: [String]) -> [ShelfItem] {
        var added: [ShelfItem] = []
        var seen = Set<String>()
        let unique = paths.filter { seen.insert($0).inserted }
        for raw in unique.reversed() {
            guard raw.hasPrefix("/") else { continue }
            let p = URL(fileURLWithPath: raw).standardizedFileURL.path
            var dir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: p, isDirectory: &dir) else { continue }
            items.removeAll { $0.path == p }
            let item = ShelfItem(id: ShelfStore.newId(), kind: "file", name: (p as NSString).lastPathComponent,
                                 path: p, isDir: dir.boolValue && !ShelfStore.isPackage(p), text: nil, addedAt: ShelfStore.now())
            items.insert(item, at: 0)
            added.insert(item, at: 0)
        }
        return commit(added)
    }

    /// Add a piece of text. A lone URL becomes a link. The same text twice moves to the front instead.
    @discardableResult
    func addText(_ raw: String) -> [ShelfItem] {
        let text = String(raw.prefix(ShelfStore.maxText))
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }
        let isLink = ShelfStore.isURL(trimmed)
        let value = isLink ? trimmed : text
        items.removeAll { $0.kind != "file" && $0.text == value }
        let item = ShelfItem(id: ShelfStore.newId(), kind: isLink ? "link" : "text",
                             name: isLink ? ShelfStore.linkName(value) : ShelfStore.firstLine(value),
                             path: nil, isDir: nil, text: value, addedAt: ShelfStore.now())
        items.insert(item, at: 0)
        return commit([item])
    }

    /// Add what was pasted: its text as notes and its pictures as clippings, left to right in reading order.
    @discardableResult
    func addClips(_ parts: [ClipPart]) -> [ShelfItem] {
        var added: [ShelfItem] = []
        var images = 0
        for part in parts {
            switch part {
            case .text(let raw):
                let text = String(raw.prefix(ShelfStore.maxText))
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                added.append(ShelfItem(id: ShelfStore.newId(), kind: "text", name: ShelfStore.firstLine(text), path: nil, isDir: nil, text: text, addedAt: ShelfStore.now()))
            case .image(let data, let ext):
                guard images < ShelfStore.maxClips, !data.isEmpty, data.count <= ShelfStore.maxClipSize, ["png", "jpg"].contains(ext) else { continue }
                images += 1
                let id = ShelfStore.newId(), name = "Image \(images).\(ext)"
                let folder = clips.appendingPathComponent(id), url = folder.appendingPathComponent(name)
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try data.write(to: url)
                } catch { continue }
                added.append(ShelfItem(id: id, kind: "file", name: name, path: url.path, isDir: false, text: nil, addedAt: ShelfStore.now(), clip: true))
            }
        }
        let texts = Set(added.compactMap(\.text))
        items.removeAll { $0.kind != "file" && texts.contains($0.text ?? "") }
        items.insert(contentsOf: added, at: 0) // the first piece leftmost, where the newest goes
        return commit(added)
    }

    @discardableResult
    func remove(_ ids: [String]) -> Int {
        let drop = Set(ids)
        let gone = items.filter { drop.contains($0.id) }
        items.removeAll { drop.contains($0.id) }
        if !gone.isEmpty { save(); discard(gone) }
        return gone.count
    }

    @discardableResult
    func clear() -> Int {
        let gone = items
        items = []
        save()
        discard(gone)
        return gone.count
    }

    /// Delete the clippings among these items. Only ever Ledge's own files, in Clips/.
    private func discard(_ gone: [ShelfItem]) {
        for it in gone where it.clip == true && it.id.range(of: #"^[0-9a-f]{12}$"#, options: .regularExpression) != nil {
            try? FileManager.default.removeItem(at: clips.appendingPathComponent(it.id))
        }
    }

    /// Forget files that are gone (moved away by dragging them into Finder, or deleted). True if anything changed.
    @discardableResult
    func prune(exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Bool {
        let gone = items.filter { $0.kind == "file" && !exists($0.path ?? "") }
        if gone.isEmpty { return false }
        items.removeAll { $0.kind == "file" && !exists($0.path ?? "") }
        save()
        discard(gone) // a clipping dragged into a Finder folder moved there: its empty folder goes
        return true
    }

    private func commit(_ added: [ShelfItem]) -> [ShelfItem] {
        if items.count > ShelfStore.maxItems { discard(Array(items.suffix(items.count - ShelfStore.maxItems))); items.removeLast(items.count - ShelfStore.maxItems) }
        if !added.isEmpty { save() }
        return added
    }

    func save() {
        guard let data = try? JSONEncoder().encode(["items": items]) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    // ---------- helpers ----------

    static func now() -> Double { (Date().timeIntervalSince1970 * 1000).rounded() }

    static func newId() -> String {
        (0..<6).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    static func isPackage(_ p: String) -> Bool {
        let ext = (p as NSString).pathExtension.lowercased()
        return ["app", "pages", "numbers", "key", "bundle", "rtfd", "pkg", "mpkg", "photoslibrary"].contains(ext)
    }

    static func isURL(_ s: String) -> Bool {
        s.range(of: #"^https?://\S+$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func firstLine(_ t: String) -> String {
        let line = t.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").first ?? ""
        return String(line.prefix(80))
    }

    static func linkName(_ url: String) -> String {
        guard let u = URLComponents(string: url), let host = u.host else { return String(url.prefix(80)) }
        let h = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let path = u.percentEncodedPath
        return String((h + (path == "/" ? "" : path)).prefix(80))
    }
}
