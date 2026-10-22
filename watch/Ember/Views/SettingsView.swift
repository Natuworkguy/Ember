import SwiftUI

/// Where the server is, and the token for it, kept in the Keychain.
///
/// Pairing is the whole of it: `ember pair` on the computer prints a code
/// that holds its address and a one-time secret. The address and the token
/// can still be typed by hand, for a server the code can't describe.
struct SettingsView: View {
    @Environment(SyncEngine.self) private var sync
    @State private var address = ""
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
                if paired, !address.isEmpty {
                    Text("Paired with \(address). To pair again, enter a new code from ember pair.")
                } else {
                    Text("Run scripts/server.sh, or ember pair, on your computer. Its code has the address in it.")
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

            Section {
                TextField("mac.local", text: $address)
                    .onSubmit { keepAddress() }
            } header: {
                Text("Server")
            } footer: {
                Text("Pairing sets this. Change it only if you need to.")
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
        .onAppear(perform: load)
    }

    private func load() {
        let settings = ServerSettings.load()
        address = settings.address.map(Self.shown) ?? ""
        paired = !settings.token.isEmpty
    }

    /// The address as typed: without http:// and the usual port.
    private static func shown(_ url: URL) -> String {
        var text = url.absoluteString.replacingOccurrences(of: "http://", with: "")
        if text.hasSuffix(":\(ServerSettings.defaultPort)") {
            text = String(text.dropLast(":\(ServerSettings.defaultPort)".count))
        }
        return text
    }

    /// Keep URL as the server's address: a new server starts syncing from
    /// the beginning.
    private func use(_ url: URL) {
        if Keychain.read("server") != url.absoluteString {
            Keychain.write(url.absoluteString, for: "server")
            Keychain.write(nil, for: "server-fallback")
            sync.forgetServer()
        }
        address = Self.shown(url)
    }

    @discardableResult
    private func keepAddress() -> URL? {
        guard let url = ServerSettings.address(from: address) else {
            good = false
            message = address.isEmpty ? "Pair with a code, or type the server's address." : "That is not an address."
            return nil
        }
        use(url)
        return url
    }

    private func pair() {
        let contents: PairingCode.Contents
        do {
            contents = try PairingCode.read(code)
        } catch {
            good = false
            message = error.localizedDescription
            Haptics.failed()
            return
        }
        // A bare six-digit secret needs the address typed below.
        let url: URL
        if let found = contents.address {
            url = found
        } else if let typed = keepAddress() {
            url = typed
        } else {
            return
        }
        working = true
        message = nil
        Task {
            defer { working = false }
            do {
                let paired = try await ServerClient(address: url, token: "").pair(secret: contents.secret)
                use(url)
                // Only paired once the token is really kept.
                guard Keychain.write(paired.token, for: "token"),
                      Keychain.read("token") == paired.token
                else {
                    good = false
                    message = "The server said yes, but the watch couldn't keep its token. Try again."
                    Haptics.failed()
                    return
                }
                // Its .local name, with the same port: where to look if the
                // router gives the computer a new address.
                if let name = paired.name, !name.isEmpty,
                   let fallback = ServerSettings.address(from: "\(name):\(url.port ?? ServerSettings.defaultPort)"),
                   fallback != url {
                    Keychain.write(fallback.absoluteString, for: "server-fallback")
                }
                self.paired = true
                code = ""
                good = true
                message = "Paired."
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
        guard let url = keepAddress() else { return }
        let settings = ServerSettings.load()
        guard !settings.token.isEmpty else {
            good = false
            message = "Pair first, or type the token."
            return
        }
        working = true
        message = nil
        Task {
            defer { working = false }
            do {
                try await ServerClient(address: url, token: settings.token, timeout: 8).health()
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
        Keychain.write(nil, for: "server")
        Keychain.write(nil, for: "server-fallback")
        Keychain.write(nil, for: "token")
        sync.forgetServer()
        address = ""
        token = ""
        paired = false
        message = nil
    }
}
