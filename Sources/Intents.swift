import AppIntents
import AppKit
import Foundation

// Siri, Shortcuts and Spotlight. Saying "Add a todo to Ledge" runs AddTodoIntent here, in Ledge itself: macOS
// starts it in the background if it isn't already running, so the todo lands on the same list the island draws.
//
// These only reach Siri when the app carries its App Intents metadata, which needs the processor that ships with
// full Xcode (see build.sh). A build made with only the Command Line Tools works exactly as usual — the todo list,
// ledge://todo and the keyboard are all here — it just has nothing for Siri to find.

/// The one door to the todo list from outside the island: an intent, or a ledge://todo URL.
@MainActor
enum Todos {
    /// The running app's list, so an intent writes where the island is looking. Set by Island.
    static weak var store: TodoStore?
    /// Redraw the island after an intent has changed something.
    static var changed: (() -> Void)?
    /// Open the island, for the Shortcuts action of the same name.
    static var showShelf: (() -> Void)?
    /// Peek, so a todo added by voice is seen landing on the list.
    static var flash: (() -> Void)?

    /// Work on the todo list, whether or not the island is up yet.
    static func use<T>(_ body: (TodoStore) -> T) -> T {
        if let store {
            let result = body(store)
            changed?()
            return result
        }
        // Launched just for this intent, before the island exists: work straight on todos.json.
        return body(TodoStore(dir: AppDelegate.dataDir))
    }
}

@available(macOS 13.0, *)
struct AddTodoIntent: AppIntent {
    static var title: LocalizedStringResource = "Add a Todo"
    static var description = IntentDescription("Puts a todo on the list in the notch.",
                                              categoryName: "Todos", searchKeywords: ["todo", "task", "reminder", "shelf", "notch"])
    static var openAppWhenRun = false

    @Parameter(title: "Todo", requestValueDialog: "What should I add?")
    var todo: String

    static var parameterSummary: some ParameterSummary { Summary("Add \(\.$todo) to Ledge") }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let added = await MainActor.run { Todos.use { $0.add(todo) } }
        guard let added else { return .result(dialog: "There was nothing to add.") }
        await MainActor.run { Todos.flash?() }
        return .result(dialog: IntentDialog("Added \(added.text)."))
    }
}

@available(macOS 13.0, *)
struct CompleteTodoIntent: AppIntent {
    static var title: LocalizedStringResource = "Tick Off a Todo"
    static var description = IntentDescription("Ticks off the first thing on the list in the notch that matches.",
                                               categoryName: "Todos", searchKeywords: ["todo", "task", "done", "complete"])
    static var openAppWhenRun = false

    @Parameter(title: "Todo", requestValueDialog: "Which one should I tick off?")
    var todo: String

    static var parameterSummary: some ParameterSummary { Summary("Tick \(\.$todo) off in Ledge") }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let done = await MainActor.run { Todos.use { $0.complete(todo) } }
        guard let done else { return .result(dialog: IntentDialog("I couldn't find \(todo) on the list.")) }
        await MainActor.run { Todos.flash?() }
        return .result(dialog: IntentDialog("Ticked off \(done.text)."))
    }
}

@available(macOS 13.0, *)
struct TodoListIntent: AppIntent {
    static var title: LocalizedStringResource = "What's on My Todo List"
    static var description = IntentDescription("Reads back what's still to do in the notch.",
                                              categoryName: "Todos", searchKeywords: ["todo", "task", "list"])
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<[String]> {
        let waiting = await MainActor.run { Todos.use { $0.items.filter { !$0.done }.map(\.text) } }
        if waiting.isEmpty { return .result(value: [], dialog: "Nothing to do.") }
        // Read out the first few, and say how many are left over, so a long list doesn't become a speech.
        let said = waiting.prefix(5).joined(separator: ", ")
        let rest = waiting.count - min(waiting.count, 5)
        let dialog = rest > 0 ? "\(said), and \(rest) more." : "\(said)."
        return .result(value: waiting, dialog: IntentDialog(stringLiteral: dialog))
    }
}

@available(macOS 13.0, *)
struct ShowShelfIntent: AppIntent {
    static var title: LocalizedStringResource = "Open the Shelf"
    static var description = IntentDescription("Opens the island under the notch.", categoryName: "Shelf")
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        await MainActor.run { Todos.showShelf?() }
        return .result()
    }
}

/// The phrases Siri listens for. "Ledge" is the app's name, which Siri fills in itself.
///
/// Each phrase leads with the app's name. "Add a todo to Ledge" reads better, but it is almost exactly how you
/// add a reminder to a list, so Siri hands it to Reminders and answers "I couldn't add that to Ledge, but I added
/// it to your Reminders". Leading with the name keeps the phrase out of Apple's own domains. The same goes for
/// the others: "what's on my list" is Reminders, and "open my shelf" is close to Files.
@available(macOS 13.0, *)
struct LedgeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AddTodoIntent(),
                    phrases: ["\(.applicationName) todo",
                              "New \(.applicationName) todo",
                              "\(.applicationName) add a todo",
                              "Add a todo to \(.applicationName)"],
                    shortTitle: "Add a Todo", systemImageName: "checklist")
        AppShortcut(intent: TodoListIntent(),
                    phrases: ["\(.applicationName) todos",
                              "\(.applicationName) list",
                              "What's on my \(.applicationName)"],
                    shortTitle: "My Todos", systemImageName: "list.bullet")
        AppShortcut(intent: CompleteTodoIntent(),
                    phrases: ["\(.applicationName) tick off",
                              "\(.applicationName) mark done"],
                    shortTitle: "Tick Off a Todo", systemImageName: "checkmark.circle")
        AppShortcut(intent: ShowShelfIntent(),
                    phrases: ["Open \(.applicationName)", "Show \(.applicationName)"],
                    shortTitle: "Open the Shelf", systemImageName: "tray.full")
    }
}

// ---------- helping Siri along ----------

/// Ledge's four actions reach Siri through the App Intents above, and macOS indexes them when the app is
/// installed. The spoken phrases can lag behind that by a restart, so "Set Up Siri…" in the menu bar points
/// people at the sure thing instead: a shortcut of their own, built from Ledge's own "Add a Todo" action.
/// Siri runs any shortcut by its name straight away.
///
/// Ledge can't add that shortcut itself. macOS refuses to import a shortcut file an app writes locally
/// ("Importing unsigned shortcut files is not supported"), and signing one needs Apple's own service.
enum SiriSetup {
    static let shortcutName = "Add Todo"
    static let steps = """
        1. In Shortcuts, choose File › New Shortcut.
        2. Search the action list for Ledge and add "Add a Todo".
        3. Name the shortcut "\(shortcutName)" and close the window.

        Then say "Hey Siri, \(shortcutName)".
        """

    /// Bring Shortcuts to the front, ready for those steps.
    static func openShortcuts() {
        let app = URL(fileURLWithPath: "/System/Applications/Shortcuts.app")
        if FileManager.default.fileExists(atPath: app.path) { NSWorkspace.shared.open(app) }
        else if let scheme = URL(string: "shortcuts://") { NSWorkspace.shared.open(scheme) }
    }
}
