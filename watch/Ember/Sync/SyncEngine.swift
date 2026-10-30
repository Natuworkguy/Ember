import Foundation
import Observation
import SwiftData
import WatchKit

/// Sends what was saved here to the server, and brings back what changed
/// there: words heard in a recording, notes an AI tool saved, deletions.
///
/// It talks to your computer over Bluetooth (BluetoothLink), so it syncs
/// when the watch is near it. It runs when Ember opens, when a note is
/// saved, every minute or so while Ember is open and the computer is out
/// of reach, and in the background now and then. A note that cannot be
/// sent waits here, and is tried again each time; nothing is ever
/// dropped.
@Observable
@MainActor
final class SyncEngine {
    static let shared = SyncEngine()

    enum Status: Equatable {
        case idle
        case syncing
        case notSetUp
        case offline(String)
        case failed(String)
        case synced
    }

    private(set) var status: Status = .idle
    private(set) var lastSynced: Date?
    /// Notes saved here and not yet on the server.
    private(set) var waiting = 0
    /// Recordings on the server that it is still finding the words in.
    private(set) var hearing = 0

    @ObservationIgnored private var running = false
    @ObservationIgnored private var again = false
    @ObservationIgnored private var listening: Task<Void, Never>?
    @ObservationIgnored private var retrying: Task<Void, Never>?

    /// How long to wait before trying again, while Ember is open and the
    /// computer is out of reach.
    private static let retrySeconds = 60.0

    /// Notes from elsewhere are brought to the watch when they are this
    /// new; older ones stay on the server.
    private static let keepDays = 30.0
    private static let keepCount = 300
    /// How long to wait before each look for the words in a recording
    /// the server is hearing, in seconds: often at first, since a short
    /// one takes it a second or two, then less, about two and a half
    /// minutes in all.
    private static let hearingWaits: [Double] = [2, 2, 3, 3, 5, 5, 10, 10, 20, 30, 60]

    private init() {
        lastSynced = UserDefaults.standard.object(forKey: "lastSynced") as? Date
        countWaiting()
    }

    private var context: ModelContext { NoteStore.container.mainContext }

    private var cursor: Int {
        get { UserDefaults.standard.integer(forKey: "cursor") }
        set { UserDefaults.standard.set(newValue, forKey: "cursor") }
    }

    /// Start again from the beginning: for a new server.
    func forgetServer() {
        cursor = 0
        status = .idle
    }

    func syncSoon() {
        Task { await sync() }
    }

    /// Sync now. One sync at a time: asked while one runs, it runs once
    /// more after.
    func sync() async {
        if running {
            again = true
            return
        }
        running = true
        defer { running = false }
        repeat {
            again = false
            await syncOnce()
        } while again
    }

    private func syncOnce() async {
        guard let client = ServerClient() else {
            status = .notSetUp
            countWaiting()
            return
        }
        status = .syncing
        do {
            try await push(client)
            try await pull(client)
            lastSynced = .now
            UserDefaults.standard.set(lastSynced, forKey: "lastSynced")
            status = .synced
            // Learn where the server is on Wi-Fi, for when Bluetooth can't reach it.
            try? await client.health()
        } catch ServerError.unreachable(let why) {
            status = .offline(why)
        } catch {
            status = .failed(error.localizedDescription)
        }
        countWaiting()
        if status == .synced { waitForWords() }
        if case .offline = status { retryLater() }
    }

    /// Out of reach: try again in a minute, while Ember is open and
    /// something is waiting to go.
    private func retryLater() {
        guard retrying == nil, waiting > 0 else { return }
        retrying = Task { @MainActor in
            defer { retrying = nil }
            try? await Task.sleep(for: .seconds(Self.retrySeconds))
            if Task.isCancelled { return }
            if WKApplication.shared().applicationState == .active { syncSoon() }
        }
    }

    private func countWaiting() {
        let synced = SyncState.synced.rawValue
        let count = try? context.fetchCount(FetchDescriptor<Note>(
            predicate: #Predicate<Note> { $0.syncStateRaw != synced }))
        waiting = count ?? 0
        let pending = "pending"
        let heard = try? context.fetchCount(FetchDescriptor<Note>(
            predicate: #Predicate<Note> {
                $0.syncStateRaw == synced && $0.transcription == pending
            }))
        hearing = heard ?? 0
        Glance.refresh(lastSynced: lastSynced)
    }

    /// A recording just went up, and the server is finding its words:
    /// look again soon, and again, until they come back to the watch.
    private func waitForWords() {
        guard listening == nil, hearing > 0 else { return }
        listening = Task { @MainActor in
            defer { listening = nil }
            for wait in Self.hearingWaits {
                try? await Task.sleep(for: .seconds(wait))
                if Task.isCancelled { return }
                await sync()
                if hearing == 0 { return }
            }
        }
    }

    // MARK: Sending

    private func push(_ client: ServerClient) async throws {
        let synced = SyncState.synced.rawValue
        var unsent = FetchDescriptor<Note>(
            predicate: #Predicate<Note> { $0.syncStateRaw != synced },
            sortBy: [SortDescriptor(\.createdAt)])
        unsent.includePendingChanges = true
        for note in try context.fetch(unsent) {
            do {
                try await send(note, client)
            } catch ServerError.rejected(let why) {
                // Kept, and shown, until you try again or delete it.
                note.syncState = .failed
                note.lastError = why
            }
            try? context.save()
        }
    }

    private func send(_ note: Note, _ client: ServerClient) async throws {
        note.attempts += 1
        if note.syncState == .deleting {
            try await client.delete(note.id)
            NoteStore.removeRecording(of: note)
            context.delete(note)
            return
        }
        if !note.onServer {
            // Sent with its words as they are now, edited or not.
            let remote = try await client.create(Outgoing(note))
            note.onServer = true
            note.rev = remote.rev
            note.edited = false
        } else if note.edited {
            let remote = try await client.update(note.id, text: note.text, tags: note.tags)
            note.rev = remote.rev
            note.tags = remote.tags
            note.edited = false
        }
        if !note.audioSent, let file = note.audioFile {
            let url = NoteStore.recording(file)
            if FileManager.default.fileExists(atPath: url.path) {
                let remote = try await client.upload(recording: url, for: note.id)
                note.rev = remote.rev
            }
            note.audioSent = true
        }
        note.syncState = .synced
        note.lastError = nil
    }

    /// Try a note the server would not take once more.
    func retry(_ note: Note) {
        note.syncState = .waiting
        note.lastError = nil
        try? context.save()
        syncSoon()
    }

    // MARK: Bringing back

    private func pull(_ client: ServerClient) async throws {
        var heard = false
        while true {
            let changes = try await client.changes(since: cursor)
            for remote in changes.notes {
                heard = merge(remote) || heard
            }
            try context.save()
            cursor = changes.cursor
            if !changes.more { break }
        }
        trim()
        // The words in something you recorded, back while you're looking.
        if heard, WKApplication.shared().applicationState == .active {
            WKInterfaceDevice.current().play(.success)
        }
    }

    /// Bring REMOTE in. Returns whether it brought the words for a
    /// recording that was being heard.
    private func merge(_ remote: RemoteNote) -> Bool {
        guard let id = UUID(uuidString: remote.id) else { return false }
        let found = try? context.fetch(FetchDescriptor<Note>(
            predicate: #Predicate<Note> { $0.id == id })).first
        if remote.deleted {
            if let found, found.syncState == .synced || found.syncState == .deleting {
                NoteStore.removeRecording(of: found)
                context.delete(found)
            }
            return false
        }
        if let found {
            // A note still on its way there keeps what was said here.
            guard found.syncState == .synced, remote.rev > found.rev else { return false }
            let heard = found.transcription == "pending" && remote.transcription == "done"
                && !remote.text.isEmpty
            found.text = remote.text
            found.tags = remote.tags
            found.transcription = remote.transcription
            found.updatedAt = Stamp.date(remote.updated_at) ?? .now
            found.rev = remote.rev
            return heard
        }
        let made = Stamp.date(remote.created_at) ?? .now
        guard Date.now.timeIntervalSince(made) < Self.keepDays * 86_400 else { return false }
        let note = Note(id: id, text: remote.text, createdAt: made, source: remote.source)
        note.tags = remote.tags
        note.transcription = remote.transcription
        note.onServer = true
        note.audioSent = true
        note.rev = remote.rev
        note.syncState = .synced
        context.insert(note)
        return false
    }

    /// Keep the watch light: only the newest synced notes stay on it.
    /// They are all still on the server.
    private func trim() {
        let synced = SyncState.synced.rawValue
        var old = FetchDescriptor<Note>(
            predicate: #Predicate<Note> { $0.syncStateRaw == synced },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        old.fetchOffset = Self.keepCount
        for note in (try? context.fetch(old)) ?? [] {
            NoteStore.removeRecording(of: note)
            context.delete(note)
        }
        try? context.save()
    }

    // MARK: In the background

    /// Ask watchOS to wake Ember to sync in a while, so notes saved away
    /// from home go up soon after you get there, even if Ember stays shut.
    /// Sooner while a recording is being heard, so its words are on the
    /// watch when you next look.
    static func scheduleRefresh(in minutes: Double? = nil) {
        let minutes = minutes ?? (shared.hearing > 0 ? 5 : 30)
        WKApplication.shared().scheduleBackgroundRefresh(
            withPreferredDate: Date(timeIntervalSinceNow: minutes * 60),
            userInfo: "sync" as NSString
        ) { _ in }
    }
}
