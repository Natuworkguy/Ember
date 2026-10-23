import SwiftData
import SwiftUI

/// Recent notes, newest first, each with where it is on its way to the
/// server.
struct NotesView: View {
    @Environment(SyncEngine.self) private var sync
    @Query(
        filter: #Predicate<Note> { $0.syncStateRaw != "deleting" },
        sort: \Note.createdAt, order: .reverse
    ) private var notes: [Note]

    var body: some View {
        List {
            Section {
                SyncRow()
            }
            if notes.isEmpty {
                Text("No ideas yet. Tap the big button and say one.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(notes) { note in
                NavigationLink {
                    NoteDetailView(note: note)
                } label: {
                    NoteRow(note: note)
                }
            }
            .onDelete { places in
                for place in places { NoteStore.delete(notes[place]) }
                sync.syncSoon()
            }
        }
        .navigationTitle("Notes")
        .refreshable { await sync.sync() }
    }
}

struct SyncRow: View {
    @Environment(SyncEngine.self) private var sync

    var body: some View {
        Button {
            sync.syncSoon()
        } label: {
            HStack {
                Image(systemName: symbol)
                    .foregroundStyle(color)
                    .symbolEffect(.pulse, isActive: sync.status == .syncing)
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline).font(.footnote)
                    if let detail {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
            }
        }
        .disabled(sync.status == .syncing)
    }

    private var symbol: String {
        switch sync.status {
        case .syncing: return "arrow.triangle.2.circlepath"
        case .offline: return "antenna.radiowaves.left.and.right.slash"
        case .failed, .notSetUp: return "exclamationmark.triangle.fill"
        default: return sync.waiting > 0 ? "clock" : "checkmark.icloud"
        }
    }

    private var color: Color {
        switch sync.status {
        case .failed, .notSetUp: return .yellow
        case .offline: return .secondary
        default: return sync.waiting > 0 ? Theme.ember : .green
        }
    }

    private var headline: String {
        switch sync.status {
        case .syncing: return "Syncing…"
        case .notSetUp: return "Not set up"
        case .offline:
            return sync.waiting > 0 ? "\(sync.waiting) waiting for home" : "Away from the server"
        case .failed: return "Sync stopped"
        default:
            if sync.waiting > 0 { return "\(sync.waiting) waiting to sync" }
            return "All synced"
        }
    }

    private var detail: String? {
        switch sync.status {
        case .notSetUp: return "Pair in Settings, with a code from ember pair."
        case .offline(let why), .failed(let why): return why
        default:
            guard let last = sync.lastSynced else { return "Tap to sync." }
            return "Synced \(last.formatted(.relative(presentation: .named)))"
        }
    }
}

struct NoteRow: View {
    let note: Note

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(note.title)
                .font(.footnote)
                .lineLimit(3)
                .foregroundStyle(note.text.isEmpty ? .secondary : .primary)
            HStack(spacing: 4) {
                SyncBadge(note: note)
                Text(note.createdAt, format: .relative(presentation: .named))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if note.source != "watch" {
                    Text("· \(note.source)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

struct SyncBadge: View {
    let note: Note

    var body: some View {
        Image(systemName: symbol)
            .font(.caption2)
            .foregroundStyle(color)
            .accessibilityLabel(label)
    }

    private var symbol: String {
        switch note.syncState {
        case .synced: return note.transcription == "pending" ? "ear" : "checkmark"
        case .waiting: return "clock"
        case .failed: return "exclamationmark.triangle.fill"
        case .deleting: return "trash"
        }
    }

    private var color: Color {
        switch note.syncState {
        case .synced: return .green
        case .waiting: return Theme.ember
        case .failed: return .yellow
        case .deleting: return .secondary
        }
    }

    private var label: String {
        switch note.syncState {
        case .synced: return note.transcription == "pending" ? "Synced, being heard" : "Synced"
        case .waiting: return "Waiting to sync"
        case .failed: return "Not taken by the server"
        case .deleting: return "Being deleted"
        }
    }
}

struct NoteDetailView: View {
    @Environment(SyncEngine.self) private var sync
    @Environment(\.dismiss) private var dismiss
    let note: Note

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(note.title)
                    .foregroundStyle(note.text.isEmpty ? .secondary : .primary)
                if !note.tags.isEmpty {
                    Text(note.tags.map { "#" + $0 }.joined(separator: " "))
                        .font(.caption)
                        .foregroundStyle(Theme.ember)
                }
                HStack(spacing: 4) {
                    SyncBadge(note: note)
                    Text(note.createdAt.formatted(date: .abbreviated, time: .shortened))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                if let why = note.lastError {
                    Text(why)
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                }
                if note.syncState == .failed {
                    Button("Try again") { sync.retry(note) }
                }
                Button("Delete", role: .destructive) {
                    NoteStore.delete(note)
                    sync.syncSoon()
                    dismiss()
                }
            }
        }
        .navigationTitle(note.createdAt.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
    }
}
