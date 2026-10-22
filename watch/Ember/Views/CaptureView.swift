import SwiftData
import SwiftUI

enum Theme {
    static let ember = Color(red: 1.0, green: 0.42, blue: 0.13)
    static let glow = LinearGradient(
        colors: [Color(red: 1.0, green: 0.62, blue: 0.20), Color(red: 0.93, green: 0.27, blue: 0.10)],
        startPoint: .top, endPoint: .bottom)
}

/// A small round button's face: a white symbol on a soft disc, readable
/// whatever the tint.
struct RoundIcon: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 36, height: 36)
            .background(Circle().fill(.white.opacity(0.16)))
            .contentShape(Circle())
    }
}

/// Words to look over before saving.
struct Draft: Identifiable {
    let id = UUID()
    let text: String
}

enum Route: Hashable {
    case notes
    case settings
}

/// The first screen: one big button that opens dictation.
struct CaptureView: View {
    @Environment(SyncEngine.self) private var sync
    @Environment(CaptureRequests.self) private var requests
    @State private var draft: Draft?
    @State private var recording = false
    @State private var savedAt: Date?
    @State private var problem: String?

    /// The row of small buttons, and the status line, take this much;
    /// the mic gets what is left, so nothing overlaps on any watch.
    private static let rowHeight: CGFloat = 36
    private static let lineHeight: CGFloat = 18
    private static let gap: CGFloat = 6

    var body: some View {
        GeometryReader { space in
            let mic = max(56, min(space.size.width * 0.66,
                                  space.size.height - Self.rowHeight - Self.lineHeight - Self.gap * 3))
            VStack(spacing: Self.gap) {
                Spacer(minLength: 0)
                TextFieldLink(prompt: Text("Your idea")) {
                    ZStack {
                        Circle().fill(Theme.glow)
                        Image(systemName: "mic.fill")
                            .font(.system(size: mic * 0.34, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: mic, height: mic)
                    .shadow(color: Theme.ember.opacity(0.5), radius: mic * 0.09)
                    .accessibilityLabel("New idea")
                } onSubmit: { text in
                    review(text)
                }
                .buttonStyle(.plain)

                Group {
                    if savedAt != nil {
                        Label("Saved", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Text(statusLine).foregroundStyle(.secondary)
                    }
                }
                .font(.footnote)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(height: Self.lineHeight)
                .animation(.default, value: savedAt)

                Spacer(minLength: 0)

                // Its own row, not a toolbar: a toolbar floats over what is
                // under it, and the tint hid its icons.
                HStack {
                    NavigationLink(value: Route.notes) {
                        RoundIcon(symbol: "list.bullet")
                    }
                    .accessibilityLabel("Notes")
                    Spacer()
                    Button {
                        recording = true
                    } label: {
                        RoundIcon(symbol: "waveform")
                    }
                    .accessibilityLabel("Record instead")
                    Spacer()
                    NavigationLink(value: Route.settings) {
                        RoundIcon(symbol: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
                .buttonStyle(.plain)
                .frame(height: Self.rowHeight)
            }
            .frame(width: space.size.width, height: space.size.height)
        }
        .navigationTitle("Ember")
        .sheet(item: $draft) { draft in
            ReviewView(text: draft.text, save: { save($0) }, retry: retry)
        }
        .sheet(isPresented: $recording) {
            RecordView { saved in
                recording = false
                if saved { showSaved() }
            }
        }
        .alert("Not saved", isPresented: Binding(
            get: { problem != nil }, set: { if !$0 { problem = nil } })
        ) {
            Button("OK") { problem = nil }
        } message: {
            Text(problem ?? "")
        }
        .task(id: requests.pending) { await answer(requests.pending) }
    }

    private var statusLine: String {
        switch sync.status {
        case .notSetUp: return "Pair in Settings"
        case .syncing: return "Syncing…"
        default:
            if sync.waiting > 0 {
                return "\(sync.waiting) waiting to sync"
            }
            return "Tap and say it"
        }
    }

    private func review(_ text: String) {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        draft = Draft(text: words)
    }

    private func save(_ text: String) {
        do {
            try NoteStore.save(text: text)
            draft = nil
            showSaved()
        } catch {
            Haptics.failed()
            problem = error.localizedDescription
        }
    }

    private func showSaved() {
        Haptics.saved()
        let now = Date.now
        savedAt = now
        sync.syncSoon()
        Task {
            try? await Task.sleep(for: .seconds(2))
            if savedAt == now { savedAt = nil }
        }
    }

    private func retry() {
        draft = nil
        Task {
            // Let the sheet go before dictation comes up.
            try? await Task.sleep(for: .milliseconds(450))
            Dictation.ask { text in
                if let text { review(text) }
            }
        }
    }

    /// Start what Siri, the complication or a shortcut asked for.
    private func answer(_ request: CaptureRequests.Kind?) async {
        guard let request else { return }
        requests.pending = nil
        draft = nil
        // Let Ember finish coming up first.
        try? await Task.sleep(for: .milliseconds(500))
        switch request {
        case .record:
            recording = true
        case .dictate:
            Dictation.ask { text in
                if let text { review(text) }
            }
        }
    }
}

/// The words dictation heard, to save with one tap, or say again.
struct ReviewView: View {
    let text: String
    let save: (String) -> Void
    let retry: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Your idea")
            .toolbar {
                ToolbarItemGroup(placement: .bottomBar) {
                    Button(action: retry) {
                        Image(systemName: "arrow.counterclockwise")
                            .foregroundStyle(.white)
                    }
                    .accessibilityLabel("Retry")
                    Spacer()
                    Button {
                        save(text)
                    } label: {
                        Image(systemName: "checkmark")
                            .fontWeight(.bold)
                            .foregroundStyle(.white)
                    }
                    .tint(Theme.ember)
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("Save")
                }
            }
        }
    }
}

/// Recording, for when you would rather talk than dictate, or dictation
/// is not there. The server finds the words when the note syncs.
struct RecordView: View {
    let done: (Bool) -> Void
    @State private var recorder = Recorder()
    @State private var problem: String?
    @State private var stopping = false

    var body: some View {
        NavigationStack {
            content
        }
        .onDisappear {
            // Closed some other way: nothing is kept.
            if !stopping { recorder.discard() }
        }
    }

    private var content: some View {
        VStack(spacing: 12) {
            if let problem {
                Text(problem)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                Button("Close") { done(false) }
            } else {
                ZStack {
                    Circle()
                        .fill(Theme.ember.opacity(0.25))
                        .scaleEffect(0.7 + 0.3 * recorder.level)
                        .animation(.easeOut(duration: 0.1), value: recorder.level)
                    Circle()
                        .fill(Theme.glow)
                        .frame(width: 56, height: 56)
                    Image(systemName: "waveform")
                        .font(.title2)
                        .foregroundStyle(.white)
                }
                .frame(width: 96, height: 96)
                Text(Duration.seconds(recorder.elapsed), format: .time(pattern: .minuteSecond))
                    .font(.title3.monospacedDigit())
            }
        }
        .toolbar {
            if problem == nil {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        stopping = true
                        recorder.discard()
                        done(false)
                    } label: {
                        Image(systemName: "xmark").foregroundStyle(.white)
                    }
                    .accessibilityLabel("Cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { keep() } label: {
                        Image(systemName: "checkmark")
                            .fontWeight(.bold)
                            .foregroundStyle(.white)
                    }
                    .tint(Theme.ember)
                    .accessibilityLabel("Save")
                }
            }
        }
        .task {
            do {
                try await recorder.start()
                Haptics.started()
            } catch {
                problem = error.localizedDescription
            }
        }
        .onChange(of: recorder.recording) { was, now in
            // It reached the longest a recording can be: keep it.
            if was && !now && !stopping { keep() }
        }
    }

    private func keep() {
        guard !stopping else { return }
        stopping = true
        guard let made = recorder.finish() else {
            done(false)
            return
        }
        do {
            try NoteStore.save(text: "", audioFile: made.name, audioDuration: made.seconds)
            done(true)
        } catch {
            problem = error.localizedDescription
        }
    }
}
