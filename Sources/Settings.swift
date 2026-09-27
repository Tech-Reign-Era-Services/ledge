import AppKit
import ServiceManagement
import SwiftUI

// Settings: the pill's size and place, how the island opens, and the music. Kept in UserDefaults; the island
// follows every change as it happens (Island watches UserDefaults), so a slider moves the real pill.

enum Prefs {
    private static let d = UserDefaults.standard

    enum Key {
        static let alwaysShow = "pill.alwaysShow", idleWidth = "pill.idleWidth", activeWidth = "pill.activeWidth"
        static let autoHeight = "pill.autoHeight", height = "pill.height", autoGap = "pill.autoGap", gap = "pill.gap"
        static let openWidth = "island.openWidth", hoverOpen = "island.hoverOpen", hoverDelay = "island.hoverDelay"
        static let showArtwork = "music.artwork", realBars = "music.realBars", barColor = "music.barColor"
    }

    static let defaults: [String: Any] = {
        let s = PillStyle()
        return [
            Key.alwaysShow: s.alwaysShow, Key.idleWidth: s.idleWidth, Key.activeWidth: s.activeWidth,
            Key.autoHeight: true, Key.height: 19, Key.autoGap: true, Key.gap: 3,
            Key.openWidth: s.openWidth, Key.hoverOpen: true, Key.hoverDelay: 140,
            Key.showArtwork: true, Key.realBars: true, Key.barColor: "#8ea2ff",
        ]
    }()

    static func register() { d.register(defaults: defaults) }
    static func reset() { for k in defaults.keys { d.removeObject(forKey: k) } }

    static var pillStyle: PillStyle {
        PillStyle(alwaysShow: d.bool(forKey: Key.alwaysShow), idleWidth: d.integer(forKey: Key.idleWidth),
                  activeWidth: d.integer(forKey: Key.activeWidth),
                  height: d.bool(forKey: Key.autoHeight) ? nil : d.integer(forKey: Key.height),
                  gap: d.bool(forKey: Key.autoGap) ? nil : d.integer(forKey: Key.gap),
                  openWidth: d.integer(forKey: Key.openWidth))
    }
    static var showArtwork: Bool { d.bool(forKey: Key.showArtwork) }
    static var realBars: Bool { d.bool(forKey: Key.realBars) }

    /// What the page reads (shelf.js applyPrefs).
    static var page: [String: Any] {
        let color = d.string(forKey: Key.barColor) ?? ""
        return ["hoverOpen": d.bool(forKey: Key.hoverOpen), "hoverDelay": d.integer(forKey: Key.hoverDelay),
                "barColor": color.range(of: #"^#[0-9a-fA-F]{6}$"#, options: .regularExpression) != nil ? color : "#8ea2ff",
                "showArtwork": showArtwork]
    }
}

struct SettingsView: View {
    @AppStorage(Prefs.Key.alwaysShow) private var alwaysShow = true
    @AppStorage(Prefs.Key.idleWidth) private var idleWidth = 96
    @AppStorage(Prefs.Key.activeWidth) private var activeWidth = 184
    @AppStorage(Prefs.Key.autoHeight) private var autoHeight = true
    @AppStorage(Prefs.Key.height) private var height = 19
    @AppStorage(Prefs.Key.autoGap) private var autoGap = true
    @AppStorage(Prefs.Key.gap) private var gap = 3
    @AppStorage(Prefs.Key.openWidth) private var openWidth = 640
    @AppStorage(Prefs.Key.hoverOpen) private var hoverOpen = true
    @AppStorage(Prefs.Key.hoverDelay) private var hoverDelay = 140
    @AppStorage(Prefs.Key.showArtwork) private var showArtwork = true
    @AppStorage(Prefs.Key.realBars) private var realBars = true
    @AppStorage(Prefs.Key.barColor) private var barColor = "#8ea2ff"
    @StateObject private var login = LoginItem()

    var body: some View {
        Form {
            Section {
                Toggle("Show the pill when there's nothing in it", isOn: $alwaysShow)
                slider("Width when idle", $idleWidth, 40...320, unit: "pt").disabled(!alwaysShow)
                slider("Width when busy", $activeWidth, 120...420, unit: "pt")
                Toggle("Fit the height to the menu bar", isOn: $autoHeight)
                if !autoHeight { slider("Height", $height, 12...44, unit: "pt") }
                Toggle("Centre it in the menu bar", isOn: $autoGap)
                if !autoGap { slider("Gap from the top of the screen", $gap, 0...24, unit: "pt") }
            } header: {
                Text("Pill")
            } footer: {
                Text("Busy: music is playing, or something is on the Shelf. On screens without a notch; on a MacBook with a notch, the island stays the shape of the notch.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Island") {
                slider("Width when open", $openWidth, 400...1000, unit: "pt")
                Toggle("Open when the pointer rests on it", isOn: $hoverOpen)
                if hoverOpen { slider("Wait before opening", $hoverDelay, 0...800, step: 20, unit: "ms") }
                else { Text("Click the pill, or press ⌃⌥S, to open it.").font(.caption).foregroundStyle(.secondary) }
            }

            Section {
                Toggle("Show the album artwork", isOn: $showArtwork)
                Toggle("Bars move to the music itself", isOn: $realBars)
                ColorPicker("Colour of the bars", selection: colorBinding, supportsOpacity: false)
            } header: {
                Text("Music")
            } footer: {
                Text("The bars listen to Music or Spotify only, and only while a song plays: macOS asks once for System Audio Recording. Nothing is recorded or saved. Off, the bars dance by themselves.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("General") {
                Toggle("Open at login", isOn: $login.on)
                HStack {
                    Spacer()
                    Button("Restore Defaults") { Prefs.reset() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func slider(_ title: String, _ value: Binding<Int>, _ range: ClosedRange<Double>, step: Double = 1, unit: String) -> some View {
        LabeledContent {
            HStack {
                // Rounded here rather than with `step:`, which draws a tick for every step.
                Slider(value: Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = Int(($0 / step).rounded() * step) }), in: range)
                Text("\(value.wrappedValue) \(unit)").monospacedDigit().foregroundStyle(.secondary).frame(width: 56, alignment: .trailing)
            }
            .frame(width: 210)
        } label: { Text(title) }
    }

    private var colorBinding: Binding<Color> {
        Binding(get: {
            guard barColor.count == 7, let v = UInt32(barColor.dropFirst(), radix: 16) else { return .blue }
            return Color(.sRGB, red: Double(v >> 16 & 0xFF) / 255, green: Double(v >> 8 & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
        }, set: { c in
            guard let s = NSColor(c).usingColorSpace(.sRGB) else { return }
            barColor = String(format: "#%02x%02x%02x", Int((s.redComponent * 255).rounded()), Int((s.greenComponent * 255).rounded()), Int((s.blueComponent * 255).rounded()))
        })
    }
}

/// Open at Login, from the system's own record of it.
final class LoginItem: ObservableObject {
    @Published var on = SMAppService.mainApp.status == .enabled {
        didSet {
            let service = SMAppService.mainApp
            guard on != (service.status == .enabled) else { return }
            try? on ? service.register() : service.unregister()
            if on != (service.status == .enabled) { DispatchQueue.main.async { self.on = service.status == .enabled } }
        }
    }
}

/// The Settings window: one, reused, brought to the front each time.
final class SettingsWindow {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            w.title = "Ledge Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        let first = window?.isVisible == false
        window?.makeKeyAndOrderFront(nil)
        if first { window?.center() } // once SwiftUI has sized it
    }
}
