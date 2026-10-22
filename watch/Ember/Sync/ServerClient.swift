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
    /// The server could not be reached: not on the same network, or not
    /// running. It is tried again later.
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

/// The server's address and token, as kept in the Keychain.
struct ServerSettings {
    static let defaultPort = 8765

    var address: URL?
    var token: String
    /// Another way to the same server, by its .local name, for when the
    /// router gives the computer a new address.
    var fallback: URL?

    static func load() -> ServerSettings {
        ServerSettings(
            address: Keychain.read("server").flatMap(URL.init(string:)),
            token: Keychain.read("token") ?? "",
            fallback: Keychain.read("server-fallback").flatMap(URL.init(string:)))
    }

    var ready: Bool { address != nil && !token.isEmpty }

    /// What was typed, as an address: `mac.local` is
    /// `http://mac.local:8765`.
    static func address(from typed: String) -> URL? {
        var text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "http://" + text }
        guard var parts = URLComponents(string: text),
              let host = parts.host, !host.isEmpty,
              parts.scheme == "http" || parts.scheme == "https"
        else { return nil }
        if parts.port == nil, parts.scheme == "http" { parts.port = defaultPort }
        parts.path = parts.path.hasSuffix("/") ? String(parts.path.dropLast()) : parts.path
        parts.query = nil
        parts.fragment = nil
        return parts.url
    }
}

struct ServerClient {
    let address: URL
    let token: String
    var timeout: TimeInterval = 15

    init?(_ settings: ServerSettings = .load(), timeout: TimeInterval = 15) {
        guard let address = settings.address, !settings.token.isEmpty else { return nil }
        self.address = address
        self.token = settings.token
        self.timeout = timeout
    }

    init(address: URL, token: String, timeout: TimeInterval = 15) {
        self.address = address
        self.token = token
        self.timeout = timeout
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    private func url(_ path: String, _ query: [URLQueryItem] = []) -> URL {
        var parts = URLComponents(url: address, resolvingAgainstBaseURL: false)!
        parts.path += path
        if !query.isEmpty { parts.queryItems = query }
        return parts.url!
    }

    private func request(_ path: String, method: String = "GET",
                         query: [URLQueryItem] = [], signed: Bool = true) -> URLRequest {
        var made = URLRequest(url: url(path, query), timeoutInterval: timeout)
        made.httpMethod = method
        if signed { made.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return made
    }

    private func perform(_ request: URLRequest, body: Data?, file: URL?) async throws -> (Data, URLResponse) {
        if let file {
            return try await Self.session.upload(for: request, fromFile: file)
        }
        if let body {
            return try await Self.session.upload(for: request, from: body)
        }
        return try await Self.session.data(for: request)
    }

    private func send(_ request: URLRequest, body: Data? = nil, file: URL? = nil) async throws -> Data {
        let answer: (Data, URLResponse)
        do {
            answer = try await perform(request, body: body, file: file)
        } catch let error as URLError {
            throw ServerError.unreachable(Self.why(error))
        }
        let (data, response) = answer
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300: return data
        case 401: throw ServerError.unauthorized
        case 400, 403, 404, 409, 413, 422:
            throw ServerError.rejected(Self.detail(data) ?? "The server would not take it (\(status)).")
        default: throw ServerError.failed(status)
        }
    }

    private static func why(_ error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
            return "No network. It will sync when there is one."
        case .timedOut, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
            return "The server is not reachable from here. It will sync when it is."
        case .appTransportSecurityRequiresSecureConnection:
            return "Use the server's address on your home network, or https."
        default:
            return error.localizedDescription
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
        _ = try await send(request("/health"))
    }

    struct Paired: Decodable {
        let token: String
        /// The computer's .local name: where to look if its address changes.
        let name: String?
    }

    /// The token, for the secret in a code from `ember pair`.
    func pair(secret: String) async throws -> Paired {
        var made = request("/pair", method: "POST", signed: false)
        made.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let data = try await send(made, body: Self.json(["code": secret]))
        return try decode(Paired.self, data)
    }

    /// Send a note. The server keeps it under its id, so sending it again
    /// after a lost answer does no harm.
    func create(_ note: Outgoing) async throws -> RemoteNote {
        var made = request("/notes", method: "POST")
        made.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = Self.json([
            "id": note.id.uuidString,
            "text": note.text,
            "created_at": Stamp.string(note.createdAt),
            "source": note.source,
            "tags": note.tags,
            "audio": note.audio,
        ])
        let data = try await send(made, body: body)
        return try decode(RemoteNote.self, data)
    }

    func upload(recording file: URL, for id: UUID) async throws -> RemoteNote {
        var made = request("/notes/\(id.uuidString)/audio", method: "PUT")
        made.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        let data = try await send(made, file: file)
        return try decode(RemoteNote.self, data)
    }

    func delete(_ id: UUID) async throws {
        do {
            _ = try await send(request("/notes/\(id.uuidString)", method: "DELETE"))
        } catch ServerError.rejected {
            // Already gone there.
        }
    }

    func changes(since cursor: Int) async throws -> Changes {
        let data = try await send(request("/notes", query: [
            URLQueryItem(name: "since", value: String(cursor)),
            URLQueryItem(name: "limit", value: "200"),
        ]))
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
