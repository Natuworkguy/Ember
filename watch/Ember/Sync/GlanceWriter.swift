import Foundation
import SwiftData
import WidgetKit

extension Glance {
    /// How things stand now, from the notes on the watch.
    @MainActor
    static func now(lastSynced: Date?) -> Glance {
        let context = NoteStore.container.mainContext
        let gone = SyncState.deleting.rawValue
        var newest = FetchDescriptor<Note>(
            predicate: #Predicate<Note> { $0.syncStateRaw != gone },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        newest.fetchLimit = 1
        let latest = (try? context.fetch(newest))?.first

        let synced = SyncState.synced.rawValue
        let waiting = (try? context.fetchCount(FetchDescriptor<Note>(
            predicate: #Predicate<Note> { $0.syncStateRaw != synced }))) ?? 0

        let morning = Calendar.current.startOfDay(for: .now)
        let today = (try? context.fetchCount(FetchDescriptor<Note>(
            predicate: #Predicate<Note> { $0.createdAt >= morning && $0.syncStateRaw != gone }))) ?? 0

        return Glance(
            latest: latest?.title, latestAt: latest?.createdAt,
            waiting: waiting, today: today,
            lastSynced: lastSynced,
            paired: ServerSettings.load().ready)
    }

    /// Tell the widget, when anything it shows has changed. LAST_SYNCED
    /// comes from the sync engine, which calls this while it starts up.
    @MainActor
    static func refresh(lastSynced: Date?) {
        if Glance.now(lastSynced: lastSynced).write() {
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}
