import AppKit
import Quartz
import WebKit

// The Shelf's window: a borderless panel over the notch (or the middle of the menu bar) that grows like the
// Dynamic Island when you hover over it, drag something onto it, or press the shortcut. The island itself is
// drawn by web/shelf.html in the system's own WebKit; this file owns the window, its size and the page's bridge.

enum IslandState: String { case closed, peek, open } // peek: hovering or dragging. open: shortcut or menu, stays until you leave it

/// A panel that can take the keyboard without bringing the app forward, and answers for Quick Look.
final class IslandPanel: NSPanel {
    weak var preview: Preview?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    // WebKit only tracks hover in an active window, and the Shelf is rarely the real key window (you're using
    // another app while it peeks). Telling WebKit it's active keeps :hover, mouseenter and mouseleave working;
    // `hasKeys` is the truth, for everything that needs it.
    override var isKeyWindow: Bool { true }
    var hasKeys: Bool { NSApp.keyWindow === self }
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = preview; panel.delegate = preview }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = nil; panel.delegate = nil }
}

/// The page's view. It takes the first click, follows the pointer even while another app is active, reads the
/// paths of dropped files (a page never sees them), and remembers the mouse event a file drag starts from.
final class IslandWebView: WKWebView {
    var onFileDrop: (([String]) -> Void)?
    private(set) var lastMouse: NSEvent?
    private var hover: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with e: NSEvent) { lastMouse = e; super.mouseDown(with: e) }
    override func mouseDragged(with e: NSEvent) { lastMouse = e; super.mouseDragged(with: e) }

    // WebKit only follows the pointer in the active app's key window. The Shelf is neither while you use other apps,
    // so this area follows it always and hands the moves to WebKit while the panel isn't key.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hover { removeTrackingArea(hover) }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hover = area
    }
    /// Our area's events go to WebKit only while the panel lacks the keys (otherwise WebKit's own area has them).
    private func mine(_ e: NSEvent) -> Bool { e.trackingArea != nil && e.trackingArea === hover && (window as? IslandPanel)?.hasKeys == true }
    override func mouseMoved(with e: NSEvent) { if !mine(e) { super.mouseMoved(with: e) } }
    override func mouseEntered(with e: NSEvent) { if !mine(e) { super.mouseEntered(with: e) } }
    override func mouseExited(with e: NSEvent) { if !mine(e) { super.mouseExited(with: e) } }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let paths = Clipboard.fileURLs(on: sender.draggingPasteboard)
        if !paths.isEmpty { onFileDrop?(paths) }
        return super.performDragOperation(sender) || !paths.isEmpty // the page still gets its drop, for the swallow
    }
}

/// Serves web/ to the page as ledge://app/…, a proper origin for its Content-Security-Policy.
final class AppScheme: NSObject, WKURLSchemeHandler {
    let root: URL
    init(root: URL) { self.root = root }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let name = task.request.url?.lastPathComponent ?? ""
        let file = root.appendingPathComponent(name)
        let types = ["html": "text/html", "css": "text/css", "js": "text/javascript"]
        guard !name.isEmpty, !name.hasPrefix("."), let type = types[file.pathExtension], let data = try? Data(contentsOf: file) else {
            return task.didFailWithError(URLError(.fileDoesNotExist))
        }
        task.didReceive(URLResponse(url: task.request.url!, mimeType: type, expectedContentLength: data.count, textEncodingName: "utf-8"))
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

/// Keeps WebKit from holding the Island strongly through its message handler.
final class WeakHandler: NSObject, WKScriptMessageHandlerWithReply {
    weak var target: WKScriptMessageHandlerWithReply?
    init(_ target: WKScriptMessageHandlerWithReply) { self.target = target }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
        target?.userContentController(c, didReceive: m, replyHandler: replyHandler)
    }
}

final class Island: NSObject, NSWindowDelegate, WKNavigationDelegate, WKScriptMessageHandlerWithReply, NSDraggingSource {
    static let pageURL = URL(string: "ledge://app/shelf.html")!
    static let collapse = 0.32 // a little longer than the island's 0.3s close in shelf.css
    static let keepKeysFor = 0.7 // how long Quick Look may try to take the keyboard after opening
    static let debug = ProcessInfo.processInfo.environment["LEDGE_DEBUG"] != nil // LEDGE_DEBUG=1: log state changes

    let store: ShelfStore
    var onChange: (() -> Void)? // the item count changed (for the menu bar)
    private(set) var state: IslandState = .closed
    private var panel: IslandPanel!
    private var web: IslandWebView!
    private var notch: Notch?
    private var ready = false
    private var shrinkWork: DispatchWorkItem?
    private var watchTimer: Timer?
    private var keysTimer: Timer?
    private let drags = DragWatch()
    private let preview = Preview()
    private let textDir = FileManager.default.temporaryDirectory.appendingPathComponent("Ledge Shelf")

    init(store: ShelfStore, webRoot: URL) {
        self.store = store
        super.init()
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(AppScheme(root: webRoot), forURLScheme: "ledge")
        config.userContentController.addScriptMessageHandler(WeakHandler(self), contentWorld: .page, name: "ledge")
        config.suppressesIncrementalRendering = true
        web = IslandWebView(frame: .zero, configuration: config)
        web.setValue(false, forKey: "drawsBackground") // transparent: only the island is drawn
        web.navigationDelegate = self
        web.onFileDrop = { [weak self] paths in self?.addFiles(paths) }

        panel = IslandPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 32),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.preview = preview
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        // Above the menu bar but below the image of whatever is being dragged, or a file dragged onto the
        // Shelf would disappear behind it.
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.delegate = self
        panel.contentView = NSView()
        panel.contentView!.addSubview(web)

        preview.onKey = { [weak self] e in
            guard let self else { return }
            self.panel.makeKey()
            self.web.keyDown(with: e)
        }
        drags.onMove = { [weak self] in
            guard let self, self.state == .closed else { return }
            let p = self.cursor()
            if Geometry.nearShelf(x: p.x, y: p.y, self.layout()) { self.setState(.peek) }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)

        measure()
        web.load(URLRequest(url: Island.pageURL))
        drags.start()
    }

    // ---------- where it sits ----------

    private var screen: NSScreen? { NSScreen.screens.first } // the one with the menu bar

    /// Read the notch again (screens changed), then reposition.
    @objc private func screensChanged() { measure() }

    private func measure() {
        notch = nil
        if let s = screen, let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea {
            notch = Geometry.notch(screenWidth: s.frame.width, safeTop: s.safeAreaInsets.top, leftWidth: l.width, rightX: r.minX - s.frame.minX)
        }
        place()
    }

    func layout() -> ShelfLayout {
        guard let s = screen else { return Geometry.layout(Display(x: 0, y: 0, width: 1440, height: 900, menuBar: 24), notch: nil, count: store.items.count) }
        let menuBar = max(s.frame.maxY - s.visibleFrame.maxY, NSStatusBar.system.thickness)
        let d = Display(x: Int(s.frame.minX), y: 0, width: Int(s.frame.width), height: Int(s.frame.height), menuBar: Int(menuBar.rounded()))
        return Geometry.layout(d, notch: notch, count: store.items.count)
    }

    /// The pointer, with a top-left origin like the layout.
    private func cursor() -> (x: Double, y: Double) {
        let p = NSEvent.mouseLocation
        return (Double(p.x), Double((screen?.frame.maxY ?? 0) - p.y))
    }

    private func frame(_ b: Box) -> NSRect {
        let top = screen?.frame.maxY ?? 0
        return NSRect(x: CGFloat(b.x), y: top - CGFloat(b.y) - CGFloat(b.height), width: CGFloat(b.width), height: CGFloat(b.height))
    }

    private func setFrame(_ b: Box, _ L: ShelfLayout) {
        let f = frame(b)
        panel.setFrame(f, display: true)
        // The page is always laid out at the open size, centred under the top edge, and the window only
        // shows part of it: resizing the window never resizes (and re-lays out) the page mid-animation.
        let w = CGFloat(L.open.width), h = CGFloat(L.open.height)
        web.frame = NSRect(x: ((f.width - w) / 2).rounded(), y: f.height - h, width: w, height: h)
    }

    /// Size the window for the current state and tell the page how to draw the island.
    private func place() {
        let L = layout()
        shrinkWork?.cancel()
        if state == .closed {
            // Let the island shrink inside the big window first, then shrink the window to fit it.
            let shrink = DispatchWorkItem { [weak self] in
                guard let self, self.state == .closed else { return }
                self.setFrame(L.closed, L)
                self.letGoOfKeys()
            }
            shrinkWork = shrink
            if panel.frame.height > CGFloat(L.closed.height) { DispatchQueue.main.asyncAfter(deadline: .now() + Island.collapse, execute: shrink) }
            else { shrink.perform() }
        } else {
            setFrame(L.open, L)
        }
        watch(state == .peek)
        emit("state", ["state": state.rawValue, "layout": L.json])
    }

    /// Once closed, the Shelf mustn't keep the keyboard out of sight: hand it back to the app you were using.
    private func letGoOfKeys() {
        guard panel.hasKeys else { return }
        panel.orderOut(nil)
        panel.orderFrontRegardless()
    }

    // ---------- state ----------

    func setState(_ next: IslandState, focus: Bool = false) {
        if next == state && !focus { return }
        if next == .peek && state == .open { return } // hovering doesn't downgrade a Shelf opened on purpose
        if Island.debug { NSLog("state %@ → %@", state.rawValue, next.rawValue) }
        state = next
        place()
        if next == .open && focus { takeKeys() }
    }

    func toggle() { setState(state == .closed ? .open : .closed, focus: true) }

    /// Open briefly to show something just landed on the Shelf.
    func flash(ms: Int = 1600) {
        guard state == .closed else { return }
        setState(.peek)
        emit("flash", ms)
    }

    private func takeKeys() {
        if !panel.hasKeys { panel.makeKey() }
        panel.makeFirstResponder(web)
    }

    /// A peeking Shelf closes once the pointer has left it. The page sees the pointer leave too, but not after
    /// dragging a file out (the drag belongs to macOS by then), so this is the backstop.
    private func watch(_ on: Bool) {
        guard on else { watchTimer?.invalidate(); watchTimer = nil; return }
        guard watchTimer == nil else { return }
        var away = 0
        watchTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, self.state == .peek else { self?.watch(false); return }
            let p = NSEvent.mouseLocation, b = self.panel.frame
            let inside = p.x >= b.minX - 8 && p.x <= b.maxX + 8 && p.y <= b.maxY && p.y >= b.minY - 12
            away = inside ? 0 : away + 1
            if away >= 3 { self.setState(.closed) }
        }
    }

    /// Quick Look takes the keyboard while it opens. Keep taking it back for a moment, as Finder does,
    /// so Space, the arrows and Esc stay with the Shelf.
    private func keepKeys(_ on: Bool = true) {
        keysTimer?.invalidate()
        keysTimer = nil
        guard on else { return }
        let until = Date().addingTimeInterval(Island.keepKeysFor)
        keysTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
            guard let self, self.state != .closed, Date() < until else { self?.keepKeys(false); return }
            if !self.panel.hasKeys { self.takeKeys() }
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        // Clicking somewhere else closes a Shelf opened on purpose. Quick Look taking the keys doesn't.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, self.state == .open, !self.panel.hasKeys else { return }
            if NSApp.keyWindow is QLPreviewPanel { return }
            self.setState(.closed)
        }
    }

    // ---------- items ----------

    /// After the Shelf's contents change: redraw it and resize the island.
    private func changed() {
        emit("items", itemsJSON())
        place()
        onChange?()
    }

    private func itemsJSON() -> [[String: Any]] {
        guard let data = try? JSONEncoder().encode(store.items),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return list
    }

    func addFiles(_ paths: [String]) {
        if !store.addFiles(paths).isEmpty { changed() }
    }

    func clear() {
        store.clear()
        changed()
    }

    func show() {
        setState(.open, focus: true)
    }

    private func existingFiles(_ ids: [String]) -> [ShelfItem] {
        store.get(ids).filter { $0.kind == "file" && FileManager.default.fileExists(atPath: $0.path ?? "") }
    }

    /// A text or link item as a .txt file, so Quick Look can show it. Kept in the temp folder, removed at quit.
    private func textFile(_ it: ShelfItem) -> URL? {
        var name = it.name.replacingOccurrences(of: "[/:\\\\]", with: "-", options: .regularExpression)
        name = String(name.replacingOccurrences(of: "^\\.+", with: "", options: .regularExpression).prefix(60)).trimmingCharacters(in: .whitespaces)
        let file = textDir.appendingPathComponent(it.id).appendingPathComponent("\(name.isEmpty ? "Text" : name).txt")
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (it.text ?? "").write(to: file, atomically: true, encoding: .utf8)
            return file
        } catch { return nil }
    }

    func cleanUp() { try? FileManager.default.removeItem(at: textDir) }

    // ---------- the page ----------

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.request.url == Island.pageURL ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        ready = true
        place()
        panel.orderFrontRegardless()
        snapshotForDevelopment()
    }

    /// LEDGE_SNAPSHOT=out.png [LEDGE_STATE=open|peek|closed]: draw the page in that state to a PNG and quit.
    private func snapshotForDevelopment() {
        let env = ProcessInfo.processInfo.environment
        guard let out = env["LEDGE_SNAPSHOT"] else { return }
        setState(IslandState(rawValue: env["LEDGE_STATE"] ?? "open") ?? .open)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            self.web.takeSnapshot(with: nil) { image, error in
                if let image, let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: out))
                } else { NSLog("snapshot failed: %@", String(describing: error)) }
                NSApp.terminate(nil)
            }
        }
    }

    // The page's web process died (rare): start it again rather than leave an empty notch.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        ready = false
        web.load(URLRequest(url: Island.pageURL))
    }

    private func emit(_ name: String, _ payload: Any) {
        guard ready, let data = try? JSONSerialization.data(withJSONObject: [name, payload], options: [.fragmentsAllowed]),
              let json = String(data: data, encoding: .utf8) else { return }
        web.evaluateJavaScript("window.__ledge.emit(...\(json))")
    }

    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage, replyHandler reply: @escaping (Any?, String?) -> Void) {
        guard m.frameInfo.isMainFrame, m.frameInfo.request.url == Island.pageURL,
              let body = m.body as? [String: Any], let cmd = body["cmd"] as? String else { return reply(nil, "Not allowed") }
        let args = body["args"] as? [Any] ?? []
        let strings = { (i: Int) -> [String] in (args.count > i ? args[i] as? [Any] : nil)?.compactMap { $0 as? String } ?? [] }
        let string = { (i: Int) -> String in args.count > i ? (args[i] as? String ?? "") : "" }

        switch cmd {
        case "items":
            store.prune()
            place()
            reply(itemsJSON(), nil)
        case "addFiles":
            let n = store.addFiles(strings(0)).count
            if n > 0 { changed() }
            reply(n, nil)
        case "addText":
            let n = store.addText(string(0)).count
            if n > 0 { changed() }
            reply(n, nil)
        case "paste":
            let files = Clipboard.files()
            let n = files.isEmpty ? store.addText(Clipboard.text() ?? "").count : store.addFiles(files).count
            if n > 0 { changed() }
            reply(n, nil)
        case "remove":
            if store.remove(strings(0)) > 0 { changed() }
            reply(nil, nil)
        case "clear":
            store.clear()
            changed()
            reply(nil, nil)
        case "copy":
            let ids = strings(0)
            let files = existingFiles(ids)
            // The clipboard holds files or text, not both: files win, as they're what the Shelf is mostly for.
            if !files.isEmpty { return reply(["count": Clipboard.copyFiles(files.compactMap(\.path)) ? files.count : 0, "kind": "files"], nil) }
            let texts = store.get(ids).filter { $0.kind != "file" }.compactMap(\.text)
            if texts.isEmpty { return reply(["count": 0], nil) }
            Clipboard.copyText(texts.joined(separator: "\n\n"))
            reply(["count": texts.count, "kind": "text"], nil)
        case "open":
            if let it = store.get([string(0)]).first {
                if it.kind == "file", let p = it.path, FileManager.default.fileExists(atPath: p) { NSWorkspace.shared.open(URL(fileURLWithPath: p)) }
                else if it.kind == "link", let t = it.text, ShelfStore.isURL(t), let u = URL(string: t) { NSWorkspace.shared.open(u) }
                else if let t = it.text { Clipboard.copyText(t) }
            }
            reply(nil, nil)
        case "reveal":
            if let p = existingFiles([string(0)]).first?.path { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) }
            reply(nil, nil)
        case "preview":
            reply(showPreview(string(0)), nil)
        case "closePreview":
            keepKeys(false)
            if QLPreviewPanel.sharedPreviewPanelExists() { QLPreviewPanel.shared().orderOut(nil) }
            reply(nil, nil)
        case "focus":
            takeKeys()
            reply(nil, nil)
        case "icon":
            guard let it = store.get([string(0)]).first, it.kind == "file", let p = it.path else { return reply(nil, nil) }
            Thumbnails.dataURL(for: p) { reply($0, nil) }
        case "setState":
            if let s = IslandState(rawValue: string(0)) { setState(s) }
            reply(nil, nil)
        case "drag":
            dragOut(existingFiles(strings(0)).compactMap(\.path))
            reply(nil, nil)
        case "log":
            NSLog("[page] %@", string(0))
            reply(nil, nil)
        default:
            reply(nil, "Unknown")
        }
    }

    // ---------- Quick Look (Space, as in Finder) ----------

    private func showPreview(_ id: String) -> Bool {
        guard let it = store.get([id]).first else { return false }
        let url: URL?
        if it.kind == "file", let p = it.path, FileManager.default.fileExists(atPath: p) { url = URL(fileURLWithPath: p) }
        else if it.kind != "file" { url = textFile(it) }
        else { url = nil }
        guard let url else { return false }
        preview.item = PreviewItem(url: url, title: it.name)
        takeKeys() // Quick Look looks for its controller from the key window
        let ql = QLPreviewPanel.shared()!
        ql.updateController()
        if ql.isVisible { ql.reloadData() } else { ql.orderFront(nil) }
        keepKeys()
        return true
    }

    // ---------- dragging files out ----------

    /// Files need a native drag (a page can't hand out real files): to Finder, Mail, a browser upload box…
    private func dragOut(_ paths: [String]) {
        guard !paths.isEmpty, let event = web.lastMouse, NSEvent.pressedMouseButtons & 1 == 1 else { return }
        let at = web.convert(event.locationInWindow, from: nil)
        let items: [NSDraggingItem] = paths.enumerated().map { i, p in
            let item = NSDraggingItem(pasteboardWriter: URL(fileURLWithPath: p) as NSURL)
            let offset = CGFloat(min(i, 3) * 4)
            item.setDraggingFrame(NSRect(x: at.x - 28 + offset, y: at.y - 28 - offset, width: 56, height: 56), contents: Thumbnails.dragImage(for: p))
            return item
        }
        let session = web.beginDraggingSession(with: items, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .move, .generic] : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        // Dragged into a Finder folder on the same disk, a file moves: it's no longer the Shelf's to keep.
        if store.prune() { changed() }
    }
}
