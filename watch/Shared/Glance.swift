import Foundation

/// What the Smart Stack widget shows: the latest idea, and how syncing
/// stands. The app writes it to the app group's folder whenever it saves
/// or syncs; the widget reads it. Without the app group, as in an
/// unsigned build, there is nothing to share, and the widget shows a
/// plain way into capture instead.
struct Glance: Codable, Equatable {
    var latest: String?
    var latestAt: Date?
    /// Saved on the watch, not yet on the server.
    var waiting: Int
    /// Ideas saved today.
    var today: Int
    var lastSynced: Date?
    var paired: Bool

    static let empty = Glance(latest: nil, latestAt: nil, waiting: 0, today: 0,
                              lastSynced: nil, paired: false)

    /// The app group both targets share, from their Info.plist.
    static var group: String? {
        Bundle.main.object(forInfoDictionaryKey: "EmberAppGroup") as? String
    }

    private static var file: URL? {
        guard let group,
              let folder = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: group)
        else { return nil }
        return folder.appendingPathComponent("glance.json")
    }

    static func read() -> Glance? {
        guard let file, let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(Glance.self, from: data)
    }

    /// Whether it changed, so the widget needs drawing again.
    @discardableResult
    func write() -> Bool {
        guard let file = Self.file, Self.read() != self,
              let data = try? JSONEncoder().encode(self)
        else { return false }
        return (try? data.write(to: file, options: .atomic)) != nil
    }
}
