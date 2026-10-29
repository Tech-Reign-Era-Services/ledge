import Foundation

// The todo list in the notch: a line of text, and whether it's done. You add one by typing in the island, by
// asking Siri ("Add a todo to Ledge" — see Intents.swift), or from a script with ledge://todo. Kept in
// todos.json beside shelf.json. Foundation only, so tests/ can compile it without AppKit.
//
// `items` is the list exactly as the island draws it: the ones still to do in the order they were added, then
// the done ones. Ticking something moves it to the end, so there's one array and no sorting to disagree about.

struct Todo: Codable, Equatable {
    var id: String
    var text: String
    var done: Bool
    var addedAt: Double
}

final class TodoStore {
    static let maxItems = 200
    static let maxText = 300 // a todo is a line, not an essay (Siri can dictate a long one)

    let file: URL
    private(set) var items: [Todo] = []

    init(dir: URL) {
        file = dir.appendingPathComponent("todos.json")
        items = TodoStore.load(file)
    }

    static func load(_ file: URL) -> [Todo] {
        guard let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = root["items"] as? [Any] else { return [] }
        // One damaged entry shouldn't cost the rest.
        let all: [Todo] = raw.compactMap { entry in
            guard entry is [String: Any], let d = try? JSONSerialization.data(withJSONObject: entry),
                  let t = try? JSONDecoder().decode(Todo.self, from: d), !t.text.isEmpty else { return nil }
            return t
        }
        return all.filter { !$0.done } + all.filter(\.done) // a hand-edited file may be in any order
    }

    /// How many are still to do: the number beside the notch.
    var open: Int { items.filter { !$0.done }.count }

    /// One line, trimmed, at most maxText characters. nil when nothing is left of it.
    static func clean(_ raw: String) -> String? {
        let line = raw.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let t = String(line.trimmingCharacters(in: .whitespaces).prefix(maxText))
        return t.isEmpty ? nil : t
    }

    /// Add a todo, after the ones already waiting. Asking for something that's already on the list doesn't add it
    /// twice: a waiting one is handed back as it is, and a done one is wanted again, so it comes back to the end
    /// of the list. Siri repeats itself more than a keyboard does.
    @discardableResult
    func add(_ raw: String) -> Todo? {
        guard let text = TodoStore.clean(raw) else { return nil }
        if let i = items.firstIndex(where: { $0.text.caseInsensitiveCompare(text) == .orderedSame }) {
            if !items[i].done { return items[i] }
            var again = items.remove(at: i)
            again.done = false
            again.addedAt = ShelfStore.now()
            items.insert(again, at: open)
            save()
            return again
        }
        let todo = Todo(id: ShelfStore.newId(), text: text, done: false, addedAt: ShelfStore.now())
        items.insert(todo, at: open)
        if items.count > TodoStore.maxItems { items.removeLast(items.count - TodoStore.maxItems) } // the done ones go first
        save()
        return todo
    }

    /// Tick one off, or put it back. Ticked, it sinks below the ones still to do; unticked, it rejoins them at the end.
    @discardableResult
    func set(_ id: String, done: Bool) -> Bool {
        guard let i = items.firstIndex(where: { $0.id == id }), items[i].done != done else { return false }
        var t = items.remove(at: i)
        t.done = done
        if done { items.append(t) } else { items.insert(t, at: open) }
        save()
        return true
    }

    /// Tick off the first thing waiting whose text matches, for Siri ("I've done the washing up").
    @discardableResult
    func complete(_ raw: String) -> Todo? {
        guard let text = TodoStore.clean(raw)?.lowercased() else { return nil }
        guard let i = items.firstIndex(where: { !$0.done && ($0.text.lowercased() == text || $0.text.lowercased().contains(text)) }) else { return nil }
        let id = items[i].id
        set(id, done: true)
        return items.first { $0.id == id }
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
    func clearDone() -> Int {
        let gone = items.filter(\.done).count
        if gone > 0 { items.removeAll(where: \.done); save() }
        return gone
    }

    @discardableResult
    func clear() -> Int {
        let gone = items.count
        items = []
        if gone > 0 { save() }
        return gone
    }

    func save() {
        guard let data = try? JSONEncoder().encode(["items": items]) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}
