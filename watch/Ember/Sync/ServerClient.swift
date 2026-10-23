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

/// The token for the server, as kept in the Keychain. Where the server
/// is needs no keeping: the watch finds it over Bluetooth.
struct ServerSettings {
    var token: String

    static func load() -> ServerSettings {
        ServerSettings(token: Keychain.read("token") ?? "")
    }

    var ready: Bool { !token.isEmpty }
}

/// The server's API, over Bluetooth (BluetoothLink): the same requests
/// as HTTP, answered by the same server.
struct ServerClient {
    let token: String
    var timeout: TimeInterval = 20

    init?(_ settings: ServerSettings = .load(), timeout: TimeInterval = 20) {
        guard settings.ready else { return nil }
        self.token = settings.token
        self.timeout = timeout
    }

    init(token: String, timeout: TimeInterval = 20) {
        self.token = token
        self.timeout = timeout
    }

    private func send(_ method: String, _ path: String, query: [URLQueryItem] = [],
                      body: Data = Data(), kind: String? = nil,
                      signed: Bool = true) async throws -> Data {
        var headers: [String: String] = [:]
        if signed { headers["Authorization"] = "Bearer \(token)" }
        if let kind { headers["Content-Type"] = kind }
        var parts = URLComponents()
        parts.queryItems = query.isEmpty ? nil : query
        let answer: BluetoothLink.Answer
        do {
            // A recording takes longer to send: about 4 KB a second.
            answer = try await BluetoothLink.shared.send(
                method, path, query: parts.percentEncodedQuery ?? "",
                headers: headers, body: body,
                timeout: timeout + Double(body.count) / 4_000)
        } catch let error as BluetoothLink.LinkError {
            throw ServerError.unreachable(error.localizedDescription)
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

    func health() async throws {
        _ = try await send("GET", "/health")
    }

    struct Paired: Decodable {
        let token: String
        let name: String?
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
