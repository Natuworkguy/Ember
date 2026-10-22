import Foundation
import Observation
import WatchKit

/// A way into capture from outside the app: the complication, Siri, a
/// shortcut, or the Action Button. The capture screen sees it and starts.
@Observable
@MainActor
final class CaptureRequests {
    static let shared = CaptureRequests()

    enum Kind: Equatable {
        case dictate
        case record
    }

    var pending: Kind?

    func open(_ url: URL) {
        guard url.scheme == "ember" else { return }
        pending = url.host == "record" ? .record : .dictate
    }
}

/// The watch's own dictation, asked for from code: for Retry, and for
/// Siri and the complication, which should land straight in it.
enum Dictation {
    /// Whether dictation could be opened. DONE gets the words, or nil when
    /// nothing was said.
    @MainActor
    @discardableResult
    static func ask(_ done: @escaping (String?) -> Void) -> Bool {
        guard let screen = WKApplication.shared().visibleInterfaceController else {
            return false
        }
        screen.presentTextInputController(withSuggestions: nil, allowedInputMode: .plain) { results in
            let text = (results?.first as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                done(text?.isEmpty == false ? text : nil)
            }
        }
        return true
    }
}

/// Plays the wrist tap for a saved note.
enum Haptics {
    static func saved() { WKInterfaceDevice.current().play(.success) }
    static func failed() { WKInterfaceDevice.current().play(.failure) }
    static func started() { WKInterfaceDevice.current().play(.start) }
}
