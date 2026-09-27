import Foundation

// What's on the Shelf. Files are kept by reference (never copied or moved); text and links are stored here.
// Foundation only, so tests/ can compile it without AppKit. The file format is the one Inlet's Shelf used.

struct ShelfItem: Codable, Equatable {
    var id: String
    var kind: String // "file" | "text" | "link"
    var name: String
    var path: String?
    var isDir: Bool?
    var text: String?
    var addedAt: Double
}

final class ShelfStore {
    static let maxItems = 100
    static let maxText = 20000 // characters kept from one text drop

    let file: URL
    private(set) var items: [ShelfItem] = []

    init(dir: URL) {
        file = dir.appendingPathComponent("shelf.json")
        items = ShelfStore.load(file)
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

    @discardableResult
    func remove(_ ids: [String]) -> Int {
        let drop = Set(ids)
        let before = items.count
        items.removeAll { drop.contains($0.id) }
        if items.count != before { save() }
        return before - items.count
    }

    @discardableResult
    func clear() -> Int {
        let n = items.count
        items = []
        save()
        return n
    }

    /// Forget files that are gone (moved away by dragging them into Finder, or deleted). True if anything changed.
    @discardableResult
    func prune(exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Bool {
        let before = items.count
        items.removeAll { $0.kind == "file" && !exists($0.path ?? "") }
        if items.count == before { return false }
        save()
        return true
    }

    private func commit(_ added: [ShelfItem]) -> [ShelfItem] {
        if items.count > ShelfStore.maxItems { items.removeLast(items.count - ShelfStore.maxItems) }
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
