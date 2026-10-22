import AppIntents
import Foundation

/// "New idea": opens Ember straight into dictation. For Siri, Shortcuts,
/// the Smart Stack, and the Action Button on an Ultra.
struct NewIdeaIntent: AppIntent {
    static var title: LocalizedStringResource = "New idea"
    static var description = IntentDescription("Open Ember and say an idea.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        CaptureRequests.shared.pending = .dictate
        return .result()
    }
}

/// "Record idea": opens Ember recording. Good on the Action Button: press,
/// talk, tap save.
struct RecordIdeaIntent: AppIntent {
    static var title: LocalizedStringResource = "Record idea"
    static var description = IntentDescription("Open Ember and record an idea, to be heard by your server.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        CaptureRequests.shared.pending = .record
        return .result()
    }
}

/// "Save an idea in Ember": Siri asks what it is and saves it, without
/// opening the app.
struct SaveIdeaIntent: AppIntent {
    static var title: LocalizedStringResource = "Save idea"
    static var description = IntentDescription("Save an idea to Ember without opening it.")

    @Parameter(title: "Idea", requestValueDialog: "What's the idea?")
    var idea: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let words = idea.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else {
            return .result(dialog: "Nothing to save.")
        }
        try NoteStore.save(text: words)
        Haptics.saved()
        // Siri is not kept waiting on the network: a quick try, and if the
        // server is not there, it syncs later as any note would.
        SyncEngine.shared.syncSoon()
        return .result(dialog: "Saved.")
    }
}

struct EmberShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: NewIdeaIntent(),
            phrases: [
                "New idea in \(.applicationName)",
                "\(.applicationName) new idea",
                "New \(.applicationName) idea",
            ],
            shortTitle: "New idea",
            systemImageName: "mic.fill")
        AppShortcut(
            intent: SaveIdeaIntent(),
            phrases: [
                "Save an idea in \(.applicationName)",
                "Save an idea to \(.applicationName)",
                "Tell \(.applicationName) an idea",
            ],
            shortTitle: "Save idea",
            systemImageName: "flame.fill")
        AppShortcut(
            intent: RecordIdeaIntent(),
            phrases: [
                "Record an idea in \(.applicationName)",
                "\(.applicationName) record",
            ],
            shortTitle: "Record idea",
            systemImageName: "waveform")
    }
}
