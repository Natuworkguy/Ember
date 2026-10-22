import SwiftData
import SwiftUI

@main
struct EmberApp: App {
    @Environment(\.scenePhase) private var phase
    @State private var sync = SyncEngine.shared
    @State private var requests = CaptureRequests.shared

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
            .tint(Theme.ember)
            .environment(sync)
            .environment(requests)
            .onOpenURL { requests.open($0) }
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
