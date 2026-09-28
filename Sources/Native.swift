import AppKit
import Carbon.HIToolbox
import QuickLookThumbnailing
import Quartz

// Small native services the Shelf needs: noticing drags anywhere on the Mac, the global shortcut,
// file thumbnails, the clipboard and Quick Look. Each replaces something Inlet did through Electron or osascript.

// ---------- drags anywhere on the Mac ----------

/// Notices when something is being dragged anywhere on the Mac, so the Shelf can open before the pointer
/// reaches it (the closed Shelf is only as big as the notch). A drag is: the left button is down and the drag
/// pasteboard has changed since it went down (dragging a window or selecting text doesn't touch it).
/// Nothing runs while the button is up; while it's down, a light 50 ms check, then every frame during a drag.
final class DragWatch {
    var onMove: (() -> Void)? // every tick while something is being dragged
    private var monitor: Any?
    private var timer: Timer?
    private var base = 0
    private let pasteboard = NSPasteboard(name: .drag)

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged]) { [weak self] e in
            self?.pressed(fresh: e.type == .leftMouseDown)
        }
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        timer?.invalidate()
        timer = nil
    }

    private func pressed(fresh: Bool) {
        if fresh || timer == nil { base = pasteboard.changeCount }
        guard timer == nil else { return }
        schedule(0.05)
    }

    /// 50 ms while the button is merely down; every frame once something is really being dragged,
    /// so the Shelf opens the moment the pointer comes near.
    private func schedule(_ interval: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        timer?.tolerance = interval / 10
    }

    private func tick() {
        guard NSEvent.pressedMouseButtons & 1 == 1 else { timer?.invalidate(); timer = nil; return }
        guard pasteboard.changeCount != base else { return }
        if let t = timer, t.timeInterval > 0.02 { schedule(1.0 / 60) }
        onMove?()
    }
}

// ---------- the global shortcut ----------

/// A system-wide shortcut through Carbon's hot keys: no Accessibility permission needed.
final class HotKey {
    private static var actions: [UInt32: () -> Void] = [:]
    private static var installed = false
    private var ref: EventHotKeyRef?
    let ok: Bool

    init(keyCode: Int, modifiers: Int, id: UInt32 = 1, action: @escaping () -> Void) {
        HotKey.install()
        HotKey.actions[id] = action
        let hotKeyID = EventHotKeyID(signature: OSType(0x4C44_4745), id: id) // 'LDGE'
        ok = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &ref) == noErr
    }

    deinit { if let ref { UnregisterEventHotKey(ref) } }

    private static func install() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            DispatchQueue.main.async { HotKey.actions[id.id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

// ---------- thumbnails ----------

/// A Quick Look thumbnail (images, PDFs, videos, and full-size folder and document icons), or the Finder icon,
/// as a PNG data URL for the page.
enum Thumbnails {
    private static var cache: [String: String] = [:] // key (path + modification date) → data URL
    private static var images: [String: NSImage] = [:] // path → the image, for dragging
    private static var waiting: [String: [(String?) -> Void]] = [:] // requests already being drawn

    /// A changed file gets a fresh thumbnail.
    private static func key(_ path: String) -> String {
        let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(modified)|\(path)"
    }

    static func dataURL(for path: String, size: CGFloat = 64, done: @escaping (String?) -> Void) {
        let key = key(path)
        if let hit = cache[key] { return done(hit) }
        // The closed island's newest item and its tile ask at the same moment: draw it once.
        if waiting[key] != nil { waiting[key]!.append(done); return }
        waiting[key] = [done]
        let url = URL(fileURLWithPath: path)
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size), scale: scale, representationTypes: .all)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
            let image = rep?.nsImage ?? NSWorkspace.shared.icon(forFile: path)
            let result = png(image, pixels: Int(size * scale)).map { "data:image/png;base64," + $0.base64EncodedString() }
            DispatchQueue.main.async {
                if cache.count > 500 { cache.removeAll(); images.removeAll() }
                cache[key] = result
                images[path] = image
                for fn in waiting.removeValue(forKey: key) ?? [] { fn(result) }
            }
        }
    }

    /// Draw these ahead of time, so tiles appear with their pictures instead of filling in as the Shelf opens.
    static func warm(_ paths: [String]) {
        for p in paths { dataURL(for: p) { _ in } }
    }

    /// The picture to drag a file by: its thumbnail if the Shelf drew one, else its Finder icon.
    static func dragImage(for path: String) -> NSImage {
        images[path] ?? NSWorkspace.shared.icon(forFile: path)
    }

    private static func png(_ image: NSImage, pixels: Int) -> Data? {
        var rect = NSRect(origin: .zero, size: image.size)
        if let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
            return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
        }
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}

// ---------- the clipboard ----------

enum Clipboard {
    /// Put these files on the clipboard, so ⌘V in Finder, Mail or Slack pastes the files themselves.
    static func copyFiles(_ paths: [String]) -> Bool {
        let pb = NSPasteboard.general
        pb.clearContents()
        return pb.writeObjects(paths.map { URL(fileURLWithPath: $0) as NSURL })
    }

    /// One picture: the file, and the picture itself, for apps that take a picture but not a file. Which one a
    /// remote desktop sends across is up to it.
    static func copyImage(_ path: String) -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)), let rep = NSBitmapImageRep(data: data) else { return copyFiles([path]) }
        let item = NSPasteboardItem()
        item.setString(URL(fileURLWithPath: path).absoluteString, forType: .fileURL)
        if let png = path.hasSuffix(".png") ? data : rep.representation(using: .png, properties: [:]) { item.setData(png, forType: .png) }
        if let tiff = rep.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        let pb = NSPasteboard.general
        pb.clearContents()
        return pb.writeObjects([item])
    }

    static func copyText(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// Paths of any files on the clipboard (e.g. after ⌘C in Finder).
    static func files() -> [String] { fileURLs(on: NSPasteboard.general) }

    static func text() -> String? { NSPasteboard.general.string(forType: .string) }

    /// Text with pictures in it (from Notes, TextEdit, Mail, Pages, Safari…), or just a picture, as pieces in reading
    /// order. nil when there's no picture: that's ordinary text. Only formats that carry their pictures are read
    /// (RTFD, web archives, images), never HTML that links to them: that would mean downloading.
    static func parts(on pb: NSPasteboard) -> [ClipPart]? {
        if !fileURLs(on: pb).isEmpty { return nil }
        var parts: [ClipPart] = []
        if let d = pb.data(forType: .rtfd) ?? pb.data(forType: NSPasteboard.PasteboardType("com.apple.flat-rtfd")),
           let rich = NSAttributedString(rtfd: d, documentAttributes: nil) {
            var text = ""
            rich.enumerateAttribute(.attachment, in: NSRange(location: 0, length: rich.length)) { value, range, _ in
                if let a = value as? NSTextAttachment, let picture = image(a.fileWrapper?.regularFileContents) ?? image(a.contents) {
                    if !text.isEmpty { parts.append(.text(text)); text = "" }
                    parts.append(picture)
                } else {
                    text += rich.attributedSubstring(from: range).string.replacingOccurrences(of: "\u{FFFC}", with: "")
                }
            }
            if !text.isEmpty { parts.append(.text(text)) }
        } else if let d = pb.data(forType: NSPasteboard.PasteboardType("com.apple.webarchive")),
                  let archive = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any] {
            // A web archive holds the page's pictures, but placing them in the text would mean reading its HTML:
            // the text as one note, then its pictures in the order the page uses them.
            if let t = pb.string(forType: .string) { parts.append(.text(t)) }
            let html = ((archive["WebMainResource"] as? [String: Any])?["WebResourceData"] as? Data).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let subs = (archive["WebSubresources"] as? [[String: Any]] ?? []).filter { ($0["WebResourceMIMEType"] as? String ?? "").hasPrefix("image/") }
            let order = { (s: [String: Any]) -> Int in
                guard let u = s["WebResourceURL"] as? String, let r = html.range(of: u) else { return Int.max }
                return html.distance(from: html.startIndex, to: r.lowerBound)
            }
            for s in subs.sorted(by: { order($0) < order($1) }) where order(s) != Int.max {
                if let p = image(s["WebResourceData"] as? Data) { parts.append(p) }
            }
        } else if let p = image(pb.data(forType: .png) ?? pb.data(forType: .tiff)) {
            parts.append(p) // just a picture: a screenshot, or copied from Preview or Photos
        }
        return parts.contains(where: { if case .image = $0 { return true } else { return false } }) ? parts : nil
    }

    /// A picture as a PNG or JPEG file's bytes. JPEGs stay as they are; anything else (TIFF, HEIC, GIF…) becomes PNG.
    private static func image(_ data: Data?) -> ClipPart? {
        guard let data, !data.isEmpty, data.count <= ShelfStore.maxClipSize, let rep = NSBitmapImageRep(data: data) else { return nil }
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return .image(data, ext: "jpg") }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return .image(data, ext: "png") }
        return rep.representation(using: .png, properties: [:]).map { .image($0, ext: "png") }
    }

    static func fileURLs(on pb: NSPasteboard) -> [String] {
        let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.map(\.path)
    }
}

// ---------- Quick Look ----------

final class PreviewItem: NSObject, QLPreviewItem {
    let url: URL
    let title: String
    init(url: URL, title: String) { self.url = url; self.title = title }
    var previewItemURL: URL! { url }
    var previewItemTitle: String! { title } // the name, not the whole path, in Quick Look's title bar
}

/// Feeds Quick Look the one item being previewed. Keys pressed while Quick Look has the keyboard go back to the page.
final class Preview: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    var item: PreviewItem?
    var onKey: ((NSEvent) -> Void)?

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { item == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { item }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown, let onKey else { return false }
        onKey(event)
        return true
    }
}
