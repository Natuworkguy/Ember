import Foundation
import Network
import Observation
import SwiftData
import WatchKit

/// Sends what was saved here to the server, and brings back what changed
/// there: words heard in a recording, notes an AI tool saved, deletions.
///
/// It runs when Ember opens, when a note is saved, when the network
/// changes (you walk in the door and the watch joins your Wi-Fi), and in
/// the background now and then. A note that cannot be sent waits here,
/// and is tried again each time; nothing is ever dropped.
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

    @ObservationIgnored private var running = false
    @ObservationIgnored private var again = false
    @ObservationIgnored private var triedOther = false
    private let monitor = NWPathMonitor()
    @ObservationIgnored private var online = false

    /// Notes from elsewhere are brought to the watch when they are this
    /// new; older ones stay on the server.
    private static let keepDays = 30.0
    private static let keepCount = 300

    private init() {
        lastSynced = UserDefaults.standard.object(forKey: "lastSynced") as? Date
        monitor.pathUpdateHandler = { path in
            let now = path.status == .satisfied
            Task { @MainActor in
                let came = now && !SyncEngine.shared.online
                SyncEngine.shared.online = now
                if came { SyncEngine.shared.syncSoon() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "ember.network"))
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
        triedOther = false
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
        } catch ServerError.unreachable(let why) {
            if await moved(from: client) {
                again = true
            } else {
                status = .offline(why)
            }
        } catch {
            status = .failed(error.localizedDescription)
        }
        countWaiting()
    }

    /// The address it paired with stopped answering: most likely the
    /// router gave the computer a new one. Try its .local name, once a
    /// sync, and keep whichever answers.
    private func moved(from client: ServerClient) async -> Bool {
        let settings = ServerSettings.load()
        guard !triedOther, let other = settings.fallback, other != client.address else {
            return false
        }
        triedOther = true
        do {
            try await ServerClient(address: other, token: client.token, timeout: 6).health()
        } catch {
            return false
        }
        Keychain.write(other.absoluteString, for: "server")
        Keychain.write(client.address.absoluteString, for: "server-fallback")
        return true
    }

    private func countWaiting() {
        let synced = SyncState.synced.rawValue
        let count = try? context.fetchCount(FetchDescriptor<Note>(
            predicate: #Predicate<Note> { $0.syncStateRaw != synced }))
        waiting = count ?? 0
        Glance.refresh(lastSynced: lastSynced)
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
            let remote = try await client.create(Outgoing(note))
            note.onServer = true
            note.rev = remote.rev
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
        while true {
            let changes = try await client.changes(since: cursor)
            for remote in changes.notes {
                merge(remote)
            }
            try context.save()
            cursor = changes.cursor
            if !changes.more { break }
        }
        trim()
    }

    private func merge(_ remote: RemoteNote) {
        guard let id = UUID(uuidString: remote.id) else { return }
        let found = try? context.fetch(FetchDescriptor<Note>(
            predicate: #Predicate<Note> { $0.id == id })).first
        if remote.deleted {
            if let found, found.syncState == .synced || found.syncState == .deleting {
                NoteStore.removeRecording(of: found)
                context.delete(found)
            }
            return
        }
        if let found {
            // A note still on its way there keeps what was said here.
            guard found.syncState == .synced, remote.rev > found.rev else { return }
            found.text = remote.text
            found.tags = remote.tags
            found.transcription = remote.transcription
            found.updatedAt = Stamp.date(remote.updated_at) ?? .now
            found.rev = remote.rev
            return
        }
        let made = Stamp.date(remote.created_at) ?? .now
        guard Date.now.timeIntervalSince(made) < Self.keepDays * 86_400 else { return }
        let note = Note(id: id, text: remote.text, createdAt: made, source: remote.source)
        note.tags = remote.tags
        note.transcription = remote.transcription
        note.onServer = true
        note.audioSent = true
        note.rev = remote.rev
        note.syncState = .synced
        context.insert(note)
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
    static func scheduleRefresh(in minutes: Double = 30) {
        WKApplication.shared().scheduleBackgroundRefresh(
            withPreferredDate: Date(timeIntervalSinceNow: minutes * 60),
            userInfo: "sync" as NSString
        ) { _ in }
    }
}
