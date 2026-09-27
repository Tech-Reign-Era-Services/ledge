import Foundation

// Tests for the parts with no AppKit in them. Built and run by `./build.sh test`
// (the Command Line Tools have no XCTest, so this is a plain executable that exits non-zero on failure).

var failures = 0
var current = ""
func test(_ name: String, _ body: () throws -> Void) {
    current = name
    do { try body() } catch { check(false, "threw \(error)") }
    print(failures == 0 ? "ok  \(name)" : "…   \(name)")
}
func check(_ ok: Bool, _ what: String = "", line: Int = #line) {
    if !ok { failures += 1; print("FAIL [\(current)] line \(line): \(what)") }
}
func eq<T: Equatable>(_ a: T, _ b: T, _ what: String = "", line: Int = #line) {
    check(a == b, "\(what) — got \(a), expected \(b)", line: line)
}

func tmp() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("ledge-test-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u.resolvingSymlinksInPath()
}
func write(_ u: URL, _ s: String) { try! s.write(to: u, atomically: true, encoding: .utf8) }

test("keeps files by reference, newest first, and remembers them") {
    let dir = tmp()
    let a = dir.appendingPathComponent("a.pdf"), b = dir.appendingPathComponent("b.png")
    write(a, "a"); write(b, "b")
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("Folder"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("Deck.key"), withIntermediateDirectories: true)

    let shelf = ShelfStore(dir: dir)
    let added = shelf.addFiles([a.path, b.path, dir.appendingPathComponent("missing.txt").path, "relative/path", a.path])
    eq(added.map(\.name), ["a.pdf", "b.png"])
    eq(shelf.items.map(\.name), ["a.pdf", "b.png"])

    shelf.addFiles([dir.appendingPathComponent("Folder").path, dir.appendingPathComponent("Deck.key").path])
    eq(shelf.items.first { $0.name == "Folder" }?.isDir, true)
    eq(shelf.items.first { $0.name == "Deck.key" }?.isDir, false, "packages behave like files")

    shelf.addFiles([b.path])
    eq(shelf.items[0].path, b.path, "adding again moves it to the front")
    eq(shelf.items.filter { $0.path == b.path }.count, 1)

    eq(try String(contentsOf: a, encoding: .utf8), "a", "the files themselves are never touched")
    eq(ShelfStore(dir: dir).items, shelf.items, "survives a restart")
}

test("text and links") {
    let shelf = ShelfStore(dir: tmp())
    let link = shelf.addText("  https://www.figma.com/file/abc  ")[0]
    eq(link.kind, "link")
    eq(link.text, "https://www.figma.com/file/abc")
    eq(link.name, "figma.com/file/abc")
    let note = shelf.addText("Meeting notes\nsecond line")[0]
    eq(note.kind, "text")
    eq(note.name, "Meeting notes")
    eq(shelf.addText("see https://a.com here")[0].kind, "text", "a URL inside a sentence is text")
    eq(shelf.addText("   ").count, 0)
    shelf.addText("https://www.figma.com/file/abc")
    eq(shelf.items.filter { $0.kind == "link" }.count, 1, "no duplicates")
    eq(shelf.items[0].kind, "link")
    eq(ShelfStore.linkName("https://a.com"), "a.com")
}

test("remove, clear, prune and the size cap") {
    let dir = tmp()
    let shelf = ShelfStore(dir: dir)
    let f = dir.appendingPathComponent("x.txt")
    write(f, "x")
    shelf.addFiles([f.path])
    let t = shelf.addText("keep me")[0]
    eq(shelf.prune(), false)
    try FileManager.default.removeItem(at: f)
    eq(shelf.prune(), true)
    eq(shelf.items.map(\.id), [t.id], "text survives a prune")
    eq(shelf.remove(["nope"]), 0)
    eq(shelf.remove([t.id]), 1)
    for i in 0..<(ShelfStore.maxItems + 5) { shelf.addText("note \(i)") }
    eq(shelf.items.count, ShelfStore.maxItems)
    eq(shelf.items[0].text, "note \(ShelfStore.maxItems + 4)", "the oldest fall off")
    eq(shelf.clear(), ShelfStore.maxItems)
    eq(ShelfStore(dir: dir).items.count, 0)
}

test("ignores a damaged shelf file, and reads Inlet's") {
    let dir = tmp()
    write(dir.appendingPathComponent("shelf.json"), "{not json")
    eq(ShelfStore(dir: dir).items.count, 0)
    write(dir.appendingPathComponent("shelf.json"), #"{"items":[null,{"id":"a","kind":"file"},{"id":"b","kind":"text","text":"ok","name":"ok","addedAt":1}]}"#)
    eq(ShelfStore(dir: dir).items.map(\.id), ["b"])
}

// Measured on a 14" MacBook Pro: 1710 pt wide, a 209 × 38 pt notch at x 751.
let mbpNotch = Geometry.notch(screenWidth: 1710, safeTop: 38, leftWidth: 751, rightX: 960)
let mbp = Display(x: 0, y: 0, width: 1710, height: 1112, menuBar: 40)
let external = Display(x: -2560, y: -300, width: 2560, height: 1440, menuBar: 25)

test("reads the notch") {
    eq(mbpNotch, Notch(left: 751, width: 209, height: 38, screenWidth: 1710))
    eq(Geometry.notch(screenWidth: 2560, safeTop: 0, leftWidth: 0, rightX: 0), nil, "no notch")
}

test("sits on the notch and grows around it") {
    let empty = Geometry.layout(mbp, notch: mbpNotch, count: 0)
    eq(empty.hasNotch, true)
    eq(empty.closed, Box(x: 751, y: 0, width: 209, height: 38), "empty: exactly the notch, so it is invisible")
    eq(empty.islandClosed, Size(width: 209, height: 38))
    let full = Geometry.layout(mbp, notch: mbpNotch, count: 3)
    let ear = Geometry.ear, sh = Geometry.shoulder
    eq(full.islandClosed, Size(width: 209 + ear * 2, height: 38), "with items: room for the newest item and the count")
    eq(full.closed, Box(x: 751 - ear - sh, y: 0, width: 209 + (ear + sh) * 2, height: 38), "…and the shoulders")
    func center(_ b: Box) -> Double { Double(b.x) + Double(b.width) / 2 }
    eq(center(full.open), center(full.closed), "opens around the notch")
    eq(center(full.open), 751 + 209 / 2.0)
    check(full.open.width > full.islandOpen.width && full.open.height > full.islandOpen.height, "room for the shadow")
    eq((full.islandOpen.width - 209) % 2, 0, "the island centres exactly")
}

test("without a notch it is a thin strip in the middle of the menu bar") {
    let L = Geometry.layout(external, notch: nil, count: 0)
    eq(L.hasNotch, false)
    eq(L.closed.y, -300)
    eq(Double(L.closed.x) + Double(L.closed.width) / 2, -1280)
    check(L.closed.height < 10, "never covers menu bar items")
    eq(Geometry.layout(external, notch: mbpNotch, count: 0).hasNotch, false, "a notch measured on another screen is ignored")
}

test("a drag opens the Shelf once it gets near the notch, not just on it") {
    let L = Geometry.layout(mbp, notch: mbpNotch, count: 0)
    let mid = Double(L.closed.x) + Double(L.closed.width) / 2
    check(Geometry.nearShelf(x: mid, y: 0, L), "on the notch")
    check(Geometry.nearShelf(x: Double(L.closed.x - 40), y: 10, L), "beside it")
    check(Geometry.nearShelf(x: mid, y: Double(L.bar + 10), L), "just below the menu bar")
    check(!Geometry.nearShelf(x: mid, y: Double(L.bar + 200), L), "not from the middle of the screen")
    check(!Geometry.nearShelf(x: 20, y: 5, L), "not from the menu bar far to the side")
    let flat = Geometry.layout(external, notch: nil, count: 0)
    check(Geometry.nearShelf(x: -1280, y: -290, flat))
    check(!Geometry.nearShelf(x: -1280, y: -100, flat))
}

test("without a notch, something live or on the Shelf becomes a floating pill") {
    let L = Geometry.layout(external, notch: nil, count: 0, live: true)
    check(L.islandClosed.height < external.menuBar && L.islandClosed.height >= 18, "fits inside the menu bar")
    check(L.insetClosed > 0, "floats clear of the top edge")
    eq(L.closed.height, L.islandClosed.height + L.insetClosed)
    eq(Double(L.closed.x) + Double(L.closed.width) / 2, -1280, "centred")
    eq(Geometry.layout(external, notch: nil, count: 2).islandClosed, L.islandClosed, "Shelf items show the same pill")
    check(Geometry.layout(external, notch: nil, count: 0).islandClosed.height < 10, "nothing to show: back to the thin strip")
    eq(L.insetOpen, L.insetClosed, "opens out of the pill")
    let n = Geometry.layout(mbp, notch: mbpNotch, count: 0, live: true)
    eq(n.islandClosed.width, 209 + Geometry.ear * 2, "with a notch, a live activity sits beside it")
    eq(n.insetClosed, 0)
}

test("each live activity adds a row to the open island, up to two") {
    let base = Geometry.layout(mbp, notch: mbpNotch, count: 1).islandOpen.height
    eq(Geometry.layout(mbp, notch: mbpNotch, count: 1, live: true, activities: 1).islandOpen.height, base + Geometry.row)
    eq(Geometry.layout(mbp, notch: mbpNotch, count: 1, live: true, activities: 5).islandOpen.height, base + Geometry.row * 2)
}

let t0 = 1_000_000.0
test("activities from other apps are validated") {
    guard case .upsert(let a)? = Activities.parse(["id": "build", "title": "  Building Ledge  ", "symbol": "hammer.fill", "progress": "1.7", "tint": "#7b96ff", "trailing": "80% done soon", "source": "Xcode"], now: t0) else { return check(false, "parsed") }
    eq(a.id, "app:build")
    eq(a.title, "Building Ledge", "trimmed")
    eq(a.symbol, "hammer.fill")
    eq(a.progress, 1, "clamped")
    eq(a.trailing, "80% done", "at most 8 characters")
    eq(a.expires, t0 + Activities.defaultTTL * 1000, "goes away by itself")
    check(Activities.parse(["id": "../x", "title": "t"], now: t0) == nil, "ids are plain")
    check(Activities.parse(["id": "x"], now: t0) == nil, "a new activity needs a title")
    eq(Activities.parse(["id": "x", "action": "end"], now: t0), .end("app:x"))
    guard case .upsert(let b)? = Activities.parse(["id": "x", "title": "t", "symbol": "<img>", "tint": "red", "link": "file:///etc/passwd", "emoji": "hello", "ttl": "99999999"], now: t0) else { return check(false, "parsed") }
    eq(b.symbol, nil); eq(b.tint, nil); eq(b.link, nil); eq(b.emoji, nil)
    eq(b.expires, t0 + Activities.maxTTL * 1000, "at most a day")
    eq(Activities.safeLink("https://github.com/x"), "https://github.com/x")
    eq(Activities.safeLink("javascript:alert(1)"), nil)
    check(Activities.isEmoji("🎧") && !Activities.isEmoji("ab"), "emoji")
    // An update keeps what it doesn't mention.
    guard case .upsert(let c)? = Activities.parse(["id": "build", "progress": "0.5"], existing: a, now: t0 + 1000) else { return check(false, "update") }
    eq(c.title, "Building Ledge"); eq(c.progress, 0.5); eq(c.symbol, "hammer.fill")
    eq(c.expires, a.expires, "an update doesn't extend the time unless it says so")
    check(a.json(icon: nil)["link"] == nil && b.json(icon: nil)["link"] == nil, "the page never sees a link")
}

test("music from Apple Music and Spotify") {
    let m = Activities.music(["Player State": "Playing", "Name": "Song", "Artist": "Band", "Album": "Record", "Total Time": NSNumber(value: 200_000)], app: "Music", bundleID: "com.apple.Music", now: t0)
    eq(m?.title, "Song"); eq(m?.subtitle, "Band — Record"); eq(m?.duration, 200); eq(m?.playing, true)
    eq(m?.expires, .infinity, "stays while playing")
    let s = Activities.music(["Player State": "Paused", "Name": "Track", "Duration": NSNumber(value: 180_000), "Playback Position": NSNumber(value: 42.5)], app: "Spotify", bundleID: "com.spotify.client", now: t0)
    eq(s?.playing, false); eq(s?.elapsed, 42.5); eq(s?.duration, 180)
    eq(s?.expires, t0 + Activities.pausedTTL * 1000, "paused music goes away after a while")
    check(Activities.music(["Player State": "Stopped", "Name": "Song"], app: "Music", bundleID: "com.apple.Music", now: t0) == nil, "stopped")
}

test("the list: music first, newest next, at most four from apps, expired ones go") {
    var list: [Activity] = []
    for i in 0..<6 { if case .upsert(let a)? = Activities.parse(["id": "a\(i)", "title": "t\(i)", "ttl": "\(10 + i)"], now: t0) { list = Activities.apply(.upsert(a), to: list) } }
    eq(list.map(\.id), ["app:a5", "app:a4", "app:a3", "app:a2"])
    list = Activities.apply(.upsert(Activity(id: "music", kind: "music", source: "Music", title: "Song")), to: list)
    eq(list.first?.id, "music")
    list = Activities.apply(.end("app:a4"), to: list)
    eq(list.count, 4)
    eq(Activities.prune(list, now: t0 + 13_500)?.map(\.id), ["music", "app:a5"], "a2 and a3 expired")
    eq(Activities.prune(list, now: t0), nil, "nothing changed")
}

print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
