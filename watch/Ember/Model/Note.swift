import Foundation
import SwiftData

/// Where a note is on its way to the server.
enum SyncState: String {
    /// Saved on the watch, not yet on the server.
    case waiting
    /// The server would not take it, and said why. It stays here until
    /// you try again or delete it.
    case failed
    /// On the server.
    case synced
    /// Deleted here; the server still has to hear.
    case deleting
}

@Model
final class Note {
    @Attribute(.unique) var id: UUID
    var text: String
    var createdAt: Date
    var updatedAt: Date
    var tags: [String]
    var source: String
    /// The recording's file name in `NoteStore.recordings`, for a note
    /// that was recorded rather than dictated.
    var audioFile: String?
    var audioDuration: Double
    /// Whether the server has the note, and its recording.
    var onServer: Bool
    var audioSent: Bool
    /// none, pending, done or failed: how hearing the recording went.
    var transcription: String
    var syncStateRaw: String
    var lastError: String?
    var attempts: Int
    var rev: Int

    init(
        id: UUID = UUID(), text: String, createdAt: Date = .now,
        source: String = "watch", audioFile: String? = nil,
        audioDuration: Double = 0
    ) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.tags = Note.hashtags(in: text)
        self.source = source
        self.audioFile = audioFile
        self.audioDuration = audioDuration
        self.onServer = false
        self.audioSent = audioFile == nil
        self.transcription = audioFile != nil && text.isEmpty ? "pending" : "none"
        self.syncStateRaw = SyncState.waiting.rawValue
        self.lastError = nil
        self.attempts = 0
        self.rev = 0
    }

    var syncState: SyncState {
        get { SyncState(rawValue: syncStateRaw) ?? .waiting }
        set { syncStateRaw = newValue.rawValue }
    }

    /// What to show for it: its words, or what is happening to its
    /// recording.
    var title: String {
        if !text.isEmpty { return text }
        let length = Duration.seconds(audioDuration).formatted(.time(pattern: .minuteSecond))
        switch transcription {
        case "failed": return "Recording, \(length). It could not be heard."
        default: return "Recording, \(length). Words once it syncs."
        }
    }

    static func hashtags(in text: String) -> [String] {
        var found: [String] = []
        for word in text.split(whereSeparator: { $0.isWhitespace }) where word.hasPrefix("#") {
            let tag = word.dropFirst().lowercased()
                .trimmingCharacters(in: .punctuationCharacters)
            if !tag.isEmpty, !found.contains(tag) { found.append(tag) }
        }
        return found
    }
}

enum NoteStore {
    static let container: ModelContainer = {
        do {
            return try ModelContainer(for: Note.self)
        } catch {
            fatalError("Ember could not open its notes: \(error)")
        }
    }()

    static var recordings: URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Recordings", isDirectory: true)
    }

    static func recording(_ name: String) -> URL {
        recordings.appendingPathComponent(name)
    }

    /// Save a new note, here first: it is safe once this returns, with or
    /// without a network.
    @MainActor
    @discardableResult
    static func save(
        text: String, audioFile: String? = nil, audioDuration: Double = 0
    ) throws -> Note {
        let context = container.mainContext
        let note = Note(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            audioFile: audioFile, audioDuration: audioDuration)
        context.insert(note)
        try context.save()
        return note
    }

    /// Delete a note: here at once, and on the server when it next syncs.
    @MainActor
    static func delete(_ note: Note) {
        let context = container.mainContext
        if note.onServer {
            note.syncState = .deleting
        } else {
            removeRecording(of: note)
            context.delete(note)
        }
        try? context.save()
    }

    static func removeRecording(of note: Note) {
        if let file = note.audioFile {
            try? FileManager.default.removeItem(at: recording(file))
        }
    }
}
