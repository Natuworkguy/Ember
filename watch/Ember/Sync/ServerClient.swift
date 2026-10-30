import Foundation

/// A note as the server has it.
struct RemoteNote: Decodable {
    let id: String
    let text: String
    let created_at: String
    let updated_at: String
    let source: String
    let tags: [String]
    let audio: Bool
    let transcription: String
    let deleted: Bool
    let rev: Int
}

/// A note on its way to the server: a copy, so it can leave the main
/// actor, where the stored note lives.
struct Outgoing {
    let id: UUID
    let text: String
    let createdAt: Date
    let source: String
    let tags: [String]
    let audio: Bool

    @MainActor
    init(_ note: Note) {
        id = note.id
        text = note.text
        createdAt = note.createdAt
        source = note.source
        tags = note.tags
        audio = note.audioFile != nil
    }
}

struct Changes: Decodable {
    let notes: [RemoteNote]
    let cursor: Int
    let more: Bool
}

enum ServerError: LocalizedError {
    case notSetUp
    case unauthorized
    /// The server will not take it as it is, and says why. Trying again
    /// will not help.
    case rejected(String)
    /// The server could not be reached: not nearby, or not running. It
    /// is tried again later.
    case unreachable(String)
    case failed(Int)

    var errorDescription: String? {
        switch self {
        case .notSetUp: return "Pair in Settings, with a code from ember pair."
        case .unauthorized: return "The server did not take the token. Pair again in Settings."
        case .rejected(let why): return why
        case .unreachable(let why): return why
        case .failed(let status): return "The server had a problem (\(status))."
        }
    }
}

/// The token for the server, as kept in the Keychain, and where it can be
/// reached over Wi-Fi when Bluetooth can't find it. The watch learns those
/// addresses from the server itself, over Bluetooth, or from Settings.
struct ServerSettings {
    var token: String
    var addresses: [String]

    static let addressesKey = "wifiAddresses"

    static func load() -> ServerSettings {
        ServerSettings(token: Keychain.read("token") ?? "",
                       addresses: UserDefaults.standard.stringArray(forKey: addressesKey) ?? [])
    }

    static func keep(addresses: [String]) {
        let clean = addresses.compactMap(normalized)
        UserDefaults.standard.set(clean.isEmpty ? nil : clean, forKey: addressesKey)
    }

    /// "192.168.1.5", "mac.local:8765" or a full http:// address, as a URL
    /// string with a scheme and port.
    static func normalized(_ text: String) -> String? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "http://" + text }
        guard var parts = URLComponents(string: text), let host = parts.host, !host.isEmpty,
              parts.scheme == "http" || parts.scheme == "https"
        else { return nil }
        if parts.port == nil { parts.port = 8765 }
        parts.path = ""
        return parts.string
    }

    var ready: Bool { !token.isEmpty }
}

/// The server's API, over Bluetooth (BluetoothLink): the same requests
/// as HTTP, answered by the same server. When Bluetooth can't reach it,
/// the same request goes over Wi-Fi, to an address the server gave.
struct ServerClient {
    let token: String
    var timeout: TimeInterval = 20
    var addresses: [String] = []

    init?(_ settings: ServerSettings = .load(), timeout: TimeInterval = 20) {
        guard settings.ready else { return nil }
        self.token = settings.token
        self.timeout = timeout
        self.addresses = settings.addresses
    }

    init(token: String, timeout: TimeInterval = 20) {
        self.token = token
        self.timeout = timeout
        self.addresses = ServerSettings.load().addresses
    }

    private struct Answer {
        let status: Int
        let body: Data
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = false
        config.allowsExpensiveNetworkAccess = true
        return URLSession(configuration: config)
    }()

    /// The request over Wi-Fi, to each address in turn.
    private func overWiFi(_ method: String, _ path: String, query: String,
                          headers: [String: String], body: Data,
                          timeout: TimeInterval) async throws -> Answer {
        var last = "Bluetooth and Wi-Fi couldn't reach your computer."
        for address in addresses {
            guard var parts = URLComponents(string: address) else { continue }
            parts.path = path
            parts.percentEncodedQuery = query.isEmpty ? nil : query
            guard let url = parts.url else { continue }
            var request = URLRequest(url: url, timeoutInterval: timeout)
            request.httpMethod = method
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
            do {
                let (data, response) = try await method == "GET" || method == "DELETE"
                    ? Self.session.data(for: request)
                    : Self.session.upload(for: request, from: body)
                guard let http = response as? HTTPURLResponse else { continue }
                return Answer(status: http.statusCode, body: data)
            } catch {
                last = "Over Wi-Fi: \(error.localizedDescription)"
            }
        }
        throw ServerError.unreachable(last)
    }

    private func send(_ method: String, _ path: String, query: [URLQueryItem] = [],
                      body: Data = Data(), kind: String? = nil,
                      signed: Bool = true) async throws -> Data {
        var headers: [String: String] = [:]
        if signed { headers["Authorization"] = "Bearer \(token)" }
        if let kind { headers["Content-Type"] = kind }
        var parts = URLComponents()
        parts.queryItems = query.isEmpty ? nil : query
        let query = parts.percentEncodedQuery ?? ""
        let answer: Answer
        do {
            // A recording takes longer to send: about 4 KB a second.
            let got = try await BluetoothLink.shared.send(
                method, path, query: query,
                headers: headers, body: body,
                timeout: timeout + Double(body.count) / 4_000)
            answer = Answer(status: got.status, body: got.body)
        } catch let error as BluetoothLink.LinkError {
            guard !addresses.isEmpty else {
                throw ServerError.unreachable(error.localizedDescription)
            }
            answer = try await overWiFi(method, path, query: query, headers: headers,
                                        body: body, timeout: timeout)
        }
        switch answer.status {
        case 200..<300: return answer.body
        case 401: throw ServerError.unauthorized
        case 400, 403, 404, 409, 413, 422:
            throw ServerError.rejected(Self.detail(answer.body)
                ?? "The server would not take it (\(answer.status)).")
        default: throw ServerError.failed(answer.status)
        }
    }

    private static func detail(_ data: Data) -> String? {
        struct Detail: Decodable { let detail: String }
        return (try? JSONDecoder().decode(Detail.self, from: data))?.detail
    }

    private static func json(_ value: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: value)) ?? Data()
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw ServerError.rejected("That does not look like an Ember server.")
        }
    }

    // MARK: The calls

    struct Health: Decodable {
        let addresses: [String]?
    }

    /// Whether the server and the token work. Keeps the Wi-Fi addresses
    /// the server gives, for when Bluetooth can't reach it.
    func health() async throws {
        let data = try await send("GET", "/health")
        if let given = (try? JSONDecoder().decode(Health.self, from: data))?.addresses,
           !given.isEmpty {
            ServerSettings.keep(addresses: given)
        }
    }

    struct Paired: Decodable {
        let token: String
        let name: String?
        let addresses: [String]?
    }

    /// The token, for the secret in a code from `ember pair`.
    func pair(secret: String) async throws -> Paired {
        let data = try await send("POST", "/pair", body: Self.json(["code": secret]),
                                  kind: "application/json", signed: false)
        return try decode(Paired.self, data)
    }

    /// Send a note. The server keeps it under its id, so sending it again
    /// after a lost answer does no harm.
    func create(_ note: Outgoing) async throws -> RemoteNote {
        let body = Self.json([
            "id": note.id.uuidString,
            "text": note.text,
            "created_at": Stamp.string(note.createdAt),
            "source": note.source,
            "tags": note.tags,
            "audio": note.audio,
        ])
        let data = try await send("POST", "/notes", body: body, kind: "application/json")
        return try decode(RemoteNote.self, data)
    }

    func upload(recording file: URL, for id: UUID) async throws -> RemoteNote {
        let wav = try Data(contentsOf: file)
        let data = try await send("PUT", "/notes/\(id.uuidString)/audio", body: wav, kind: "audio/wav")
        return try decode(RemoteNote.self, data)
    }

    /// Change a note's words on the server, and its tags to the ones in
    /// them: a hashtag taken out of the words is taken off the note.
    func update(_ id: UUID, text: String, tags: [String]) async throws -> RemoteNote {
        let data = try await send("PATCH", "/notes/\(id.uuidString)",
                                  body: Self.json(["text": text, "tags": tags]),
                                  kind: "application/json")
        return try decode(RemoteNote.self, data)
    }

    func delete(_ id: UUID) async throws {
        do {
            _ = try await send("DELETE", "/notes/\(id.uuidString)")
        } catch ServerError.rejected {
            // Already gone there.
        }
    }

    func changes(since cursor: Int) async throws -> Changes {
        let data = try await send("GET", "/notes", query: [
            URLQueryItem(name: "since", value: String(cursor)),
            URLQueryItem(name: "limit", value: "200"),
        ])
        return try decode(Changes.self, data)
    }
}

/// Times as the server writes them: UTC, ISO 8601.
enum Stamp {
    private static let withFraction: ISO8601DateFormatter = {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return format
    }()

    private static let plain: ISO8601DateFormatter = {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime]
        return format
    }()

    static func string(_ date: Date) -> String {
        withFraction.string(from: date)
    }

    static func date(_ text: String) -> Date? {
        // The server writes microseconds; the formatter reads milliseconds.
        var trimmed = text
        if let dot = text.firstIndex(of: "."),
           let zone = text[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) {
            let digits = String(text[text.index(after: dot)..<zone].prefix(3))
            let fraction = digits.padding(toLength: 3, withPad: "0", startingAt: 0)
            trimmed = String(text[..<dot]) + "." + fraction + String(text[zone...])
        }
        return withFraction.date(from: trimmed) ?? plain.date(from: text)
    }
}
