import Foundation

/// The code `ember pair` prints: a one-time secret of six digits, which
/// the watch trades for the server's token. Where the server is needs no
/// code: the watch finds it over Bluetooth.
enum PairingCode {
    enum Problem: LocalizedError {
        case wrong

        var errorDescription: String? {
            "A pairing code is six digits. Run `ember pair` on your computer for one."
        }
    }

    static let secretDigits = 6

    /// The digits in what was typed or dictated, spaces and all.
    static func digits(_ typed: String) -> [Int] {
        typed.compactMap { $0.isASCII ? $0.wholeNumberValue : nil }
    }

    static func looksComplete(_ typed: String) -> Bool {
        digits(typed).count == secretDigits
    }

    /// The secret in TYPED.
    static func read(_ typed: String) throws -> String {
        let all = digits(typed)
        guard all.count == secretDigits else { throw Problem.wrong }
        return all.map(String.init).joined()
    }
}
