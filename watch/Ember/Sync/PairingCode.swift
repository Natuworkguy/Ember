import Foundation

/// The code `ember pair` prints: where the server is and a one-time
/// secret, in one string of digits, so nothing else needs typing.
///
///     [where][secret][check]
///
/// The secret is the last six digits before the check. Before it, a
/// number holds the server's IPv4 address, packed small for the ranges
/// home networks use, and its port when it is not 8765. The check digit
/// (Damm's) catches any one digit typed wrong and any two neighbours
/// swapped. Six digits alone are a bare secret, for a server already set.
///
/// The server makes it in server/ember_server/pairing.py: change one,
/// change both.
enum PairingCode {
    struct Contents: Equatable {
        /// Nil for a bare secret.
        let address: URL?
        let secret: String
    }

    enum Problem: LocalizedError {
        case wrong

        var errorDescription: String? {
            "That code isn't right. Check it, or run `ember pair` for a new one."
        }
    }

    static let secretDigits = 6

    // Damm's table: a totally anti-symmetric quasigroup of order 10.
    private static let damm: [[Int]] = [
        [0, 3, 1, 7, 5, 9, 8, 6, 4, 2],
        [7, 0, 9, 2, 1, 5, 4, 8, 6, 3],
        [4, 2, 0, 6, 8, 7, 1, 3, 5, 9],
        [1, 7, 5, 0, 9, 8, 3, 4, 2, 6],
        [6, 1, 2, 3, 0, 4, 5, 9, 7, 8],
        [3, 6, 7, 4, 2, 0, 9, 5, 8, 1],
        [5, 8, 6, 9, 7, 2, 0, 1, 3, 4],
        [8, 9, 4, 5, 3, 6, 2, 0, 1, 7],
        [9, 4, 3, 8, 6, 1, 7, 2, 0, 5],
        [2, 5, 8, 1, 4, 3, 6, 7, 9, 0],
    ]

    /// The digits in what was typed or dictated, spaces and all.
    static func digits(_ typed: String) -> [Int] {
        typed.compactMap { $0.isASCII ? $0.wholeNumberValue : nil }
    }

    /// Whether TYPED has the right number of digits to try.
    static func looksComplete(_ typed: String) -> Bool {
        let count = digits(typed).count
        return count == secretDigits || count >= secretDigits + 2
    }

    static func read(_ typed: String) throws -> Contents {
        let all = digits(typed)
        if all.count == secretDigits {
            return Contents(address: nil, secret: all.map(String.init).joined())
        }
        guard all.count >= secretDigits + 2, all.count <= 40,
              all.reduce(0, { damm[$0][$1] }) == 0
        else { throw Problem.wrong }

        let body = Array(all.dropLast())
        let secret = body.suffix(secretDigits).map(String.init).joined()
        let (halved, hasPort) = divide(Array(body.dropLast(secretDigits)), by: 2)
        var whereAt = halved
        var port = ServerSettings.defaultPort
        if hasPort == 1 {
            let (shorter, given) = divide(whereAt, by: 65_536)
            whereAt = shorter
            port = given
        }
        let (packed, kind) = divide(whereAt, by: 4)
        whereAt = packed
        // What is left is at most an IPv4 address: 10 digits.
        guard whereAt.count <= 10, port > 0 else { throw Problem.wrong }
        let rest = whereAt.reduce(0) { $0 * 10 + $1 }
        guard rest <= Int(UInt32.max) else { throw Problem.wrong }

        let host: String
        switch kind {
        case 0: host = "192.168.\(rest >> 8 & 255).\(rest & 255)"
        case 1: host = "10.\(rest >> 16 & 255).\(rest >> 8 & 255).\(rest & 255)"
        case 2: host = "172.\(16 + (rest >> 16 & 15)).\(rest >> 8 & 255).\(rest & 255)"
        default: host = "\(rest >> 24 & 255).\(rest >> 16 & 255).\(rest >> 8 & 255).\(rest & 255)"
        }
        guard let address = ServerSettings.address(from: "\(host):\(port)") else {
            throw Problem.wrong
        }
        return Contents(address: address, secret: secret)
    }

    /// DIGITS, a number too long for an Int, divided by a small one.
    private static func divide(_ digits: [Int], by divisor: Int) -> ([Int], Int) {
        var quotient: [Int] = []
        var remainder = 0
        for digit in digits {
            let current = remainder * 10 + digit
            let next = current / divisor
            remainder = current % divisor
            if !(quotient.isEmpty && next == 0) { quotient.append(next) }
        }
        return (quotient, remainder)
    }
}
