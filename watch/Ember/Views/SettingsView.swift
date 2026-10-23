import SwiftUI

/// Pairing with the server, and the token for it, kept in the Keychain.
///
/// `ember pair` on the computer prints a six-digit code; with the watch
/// near the computer, the code is traded for the token over Bluetooth.
/// The token can still be typed by hand.
struct SettingsView: View {
    @Environment(SyncEngine.self) private var sync
    @State private var code = ""
    @State private var token = ""
    @State private var paired = false
    @State private var working = false
    @State private var message: String?
    @State private var good = false

    var body: some View {
        Form {
            Section {
                TextField("Pairing code", text: $code)
                    .onSubmit { pair() }
                Button("Pair") { pair() }
                    .disabled(working || !PairingCode.looksComplete(code))
            } header: {
                Text(paired ? "Paired" : "Pair")
            } footer: {
                if paired {
                    Text("Ember syncs over Bluetooth when the watch is near your computer. To pair again, enter a new code from ember pair.")
                } else {
                    Text("Run ember pair on your computer, and keep the watch near it.")
                }
            }

            Section {
                Button {
                    check()
                } label: {
                    HStack {
                        Text("Test connection")
                        if working { Spacer(); ProgressView().frame(width: 20) }
                    }
                }
                .disabled(working)
                if let message {
                    Label(message, systemImage: good ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(good ? .green : .yellow)
                }
            }

            Section("Or the token") {
                SecureField("Token", text: $token)
                    .onSubmit {
                        Keychain.write(token.trimmingCharacters(in: .whitespacesAndNewlines), for: "token")
                        paired = !token.isEmpty
                        check()
                    }
            }

            if paired {
                Section {
                    Button("Forget this server", role: .destructive) { forget() }
                }
            }
        }
        .navigationTitle("Settings")
        .onAppear { paired = ServerSettings.load().ready }
    }

    private func pair() {
        let secret: String
        do {
            secret = try PairingCode.read(code)
        } catch {
            good = false
            message = error.localizedDescription
            Haptics.failed()
            return
        }
        working = true
        message = nil
        Task {
            defer { working = false }
            do {
                let answer = try await ServerClient(token: "").pair(secret: secret)
                // Only paired once the token is really kept. A new server
                // starts syncing from the beginning.
                let before = Keychain.read("token")
                guard Keychain.write(answer.token, for: "token"),
                      Keychain.read("token") == answer.token
                else {
                    good = false
                    message = "The server said yes, but the watch couldn't keep its token. Try again."
                    Haptics.failed()
                    return
                }
                if before != answer.token { sync.forgetServer() }
                paired = true
                code = ""
                good = true
                message = answer.name.map { "Paired with \($0)." } ?? "Paired."
                Haptics.saved()
                await sync.sync()
            } catch {
                good = false
                message = error.localizedDescription
                Haptics.failed()
            }
        }
    }

    private func check() {
        let settings = ServerSettings.load()
        guard settings.ready else {
            good = false
            message = "Pair first, or type the token."
            return
        }
        working = true
        message = nil
        Task {
            defer { working = false }
            do {
                try await ServerClient(token: settings.token, timeout: 10).health()
                good = true
                message = "Connected."
                await sync.sync()
            } catch {
                good = false
                message = error.localizedDescription
            }
        }
    }

    private func forget() {
        Keychain.write(nil, for: "token")
        sync.forgetServer()
        token = ""
        paired = false
        message = nil
    }
}
