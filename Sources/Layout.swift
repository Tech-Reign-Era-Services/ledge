import Foundation

// Where the Shelf sits on screen. Foundation only (tested in tests/). All rectangles here use a top-left
// origin, as the page and Inlet's original layout did; IslandWindow converts to AppKit's bottom-left.

struct Box: Equatable { var x: Int, y: Int, width: Int, height: Int }
struct Size: Equatable { var width: Int, height: Int }

/// The notch, relative to its screen. nil for a screen without one.
struct Notch: Equatable { var left: Int, width: Int, height: Int, screenWidth: Int }

/// A screen: its bounds (top-left origin) and the menu bar's height.
struct Display { var x: Int, y: Int, width: Int, height: Int, menuBar: Int }

struct ShelfLayout: Equatable {
    var hasNotch: Bool
    var notch: Size // width and height of the notch (height 0 without one)
    var bar: Int // notch / menu bar height: the top strip of the open island
    var shoulder: Int
    var closed: Box // the window's bounds in each state…
    var open: Box
    var islandClosed: Size // …and the black shape drawn inside it
    var islandOpen: Size
    var insetClosed: Int // how far below the top edge the island floats (a pill on a screen without a notch)
    var insetOpen: Int
    var rows: Int // live activity rows in the open island

    /// What the page reads (shelf.js applyState).
    var json: [String: Any] {
        func box(_ b: Box) -> [String: Int] { ["x": b.x, "y": b.y, "width": b.width, "height": b.height] }
        func size(_ s: Size) -> [String: Int] { ["width": s.width, "height": s.height] }
        return [
            "hasNotch": hasNotch, "notch": size(notch), "bar": bar, "shoulder": shoulder,
            "closed": box(closed), "open": box(open),
            "island": ["closed": size(islandClosed), "open": size(islandOpen)], "inset": ["closed": insetClosed, "open": insetOpen], "rows": rows,
        ]
    }
}

enum Geometry {
    static let ear = 38 // room either side of the notch for the newest item and the count
    static let noNotchWidth = 200 // the hover strip on screens without a notch
    static let edgeHeight = 5 // …and its height, so it never covers menu bar items
    static let openWidth = 640
    static let openHeight = 174
    static let shoulder = 10 // the inward curves where the island meets the top of the screen, like the notch's own
    static let side = 34 // open: room beside and below the island for its shoulders, shadow and springy overshoot
    static let below = 48
    static let pillWidth = 184 // no notch: the island when something is live or on the Shelf, like the iPhone's
    static let row = 64 // one live activity in the open island
    static let maxRows = 2
    static let reachX = 80 // while dragging, how far beside the closed island the pointer opens the Shelf
    static let reachY = 24 // …and how far below the menu bar

    /// Turn raw screen measurements into a Notch, or nil for a screen without one.
    static func notch(screenWidth: Double, safeTop: Double, leftWidth: Double, rightX: Double) -> Notch? {
        guard safeTop > 0, leftWidth > 0, rightX > leftWidth else { return nil }
        return Notch(left: Int(leftWidth.rounded()), width: Int((rightX - leftWidth).rounded()),
                     height: Int(safeTop.rounded()), screenWidth: Int(screenWidth.rounded()))
    }

    /// Sizes and screen positions for each state. notch is ignored if it was measured on a screen of a different width.
    /// live: something is happening (music, another app's activity), so the closed island shows it.
    static func layout(_ d: Display, notch: Notch?, count: Int, live: Bool = false, activities: Int = 0) -> ShelfLayout {
        let menuBar = max(24, d.menuBar)
        let hasNotch = notch != nil && notch!.screenWidth == d.width
        let n = hasNotch ? notch! : Notch(left: Int((Double(d.width - noNotchWidth) / 2).rounded()), width: noNotchWidth, height: menuBar, screenWidth: d.width)
        let center = Double(d.x) + Double(n.left) + Double(n.width) / 2
        // Same odd/even width as the notch, so everything centres on it exactly.
        func fit(_ w: Double) -> Int {
            let c = min(Int(w.rounded()), d.width)
            return max(1, c - ((c - n.width) % 2 != 0 ? 1 : 0)) // a sleeping display can report 0 × 0
        }
        func box(_ w: Int, _ h: Int) -> Box {
            let width = fit(Double(w))
            let x = min(max(center - Double(width) / 2, Double(d.x)), Double(d.x + d.width - width)).rounded()
            return Box(x: Int(x), y: d.y, width: width, height: h)
        }
        let shows = count > 0 || live // something to show beside the notch, or in the pill
        // No notch: a pill floating in the middle of the menu bar, a few points clear of its edges.
        let pillHeight = max(18, menuBar - 6)
        let pillInset = (menuBar - pillHeight) / 2
        let islandClosed: Size
        if hasNotch { islandClosed = Size(width: fit(Double(n.width + (shows ? ear * 2 : 0))), height: n.height) }
        else if shows { islandClosed = Size(width: fit(Double(pillWidth)), height: pillHeight) }
        else { islandClosed = Size(width: fit(Double(n.width)), height: edgeHeight) } // nearly invisible, but catches the pointer and drops
        let closedInset = !hasNotch && shows ? pillInset : 0
        let openInset = hasNotch ? 0 : pillInset
        // An empty Shelf is exactly the notch (invisible). With something to show, the window also fits the shoulders.
        let closed = box(islandClosed.width + (hasNotch && shows ? shoulder * 2 : 0), islandClosed.height + closedInset)
        let rows = min(activities, maxRows)
        let islandOpen = Size(width: fit(Double(min(max(openWidth, n.width + ear * 2), d.width - side * 2))),
                              height: openHeight + (hasNotch ? n.height - 32 : 0) + rows * row)
        let open = box(islandOpen.width + side * 2, islandOpen.height + below + openInset)
        return ShelfLayout(hasNotch: hasNotch, notch: Size(width: n.width, height: hasNotch ? n.height : 0),
                           bar: hasNotch ? n.height : menuBar, shoulder: shoulder,
                           closed: closed, open: open, islandClosed: islandClosed, islandOpen: islandOpen,
                           insetClosed: closedInset, insetOpen: openInset, rows: rows)
    }

    /// While something is being dragged: is the pointer close enough to the closed Shelf to open it?
    static func nearShelf(x: Double, y: Double, _ L: ShelfLayout) -> Bool {
        let c = L.closed
        return x >= Double(c.x - reachX) && x <= Double(c.x + c.width + reachX)
            && y >= Double(c.y) && y <= Double(c.y + L.bar + reachY)
    }
}
