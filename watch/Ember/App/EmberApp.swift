import SwiftData
import SwiftUI

@main
struct EmberApp: App {
    @Environment(\.scenePhase) private var phase
    @State private var sync = SyncEngine.shared
    @State private var requests = CaptureRequests.shared
    /// Bumped by a shortcut, Siri or the complication: the stack starts
    /// again at the capture screen, wherever Ember was left (the notes,
    /// a note, Settings), so the request lands without a tap on Back.
    @State private var stack = 0

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                CaptureView()
                    .navigationDestination(for: Route.self) { route in
                        switch route {
                        case .notes: NotesView()
                        case .settings: SettingsView()
                        }
                    }
            }
            .id(stack)
            .tint(Theme.ember)
            .environment(sync)
            .environment(requests)
            .onOpenURL { requests.open($0) }
            .onChange(of: requests.pending) { _, now in
                if now != nil { stack += 1 }
            }
        }
        .modelContainer(NoteStore.container)
        .onChange(of: phase) { _, now in
            switch now {
            case .active: sync.syncSoon()
            case .background: SyncEngine.scheduleRefresh()
            default: break
            }
        }
        .backgroundTask(.appRefresh("sync")) {
            await SyncEngine.shared.sync()
            await SyncEngine.scheduleRefresh()
        }
    }
}
