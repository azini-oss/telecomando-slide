import Foundation

/// Comandi che il telefono può inviare. Tutto ciò che non è in questo elenco viene scartato.
enum Command: Equatable {
    case hello(pin: String)
    case resume(token: String)
    case next
    case previous
    case first
    case goTo(slide: Int)
    case start
    case stop
    case black
    case reload

    static let maxLength = 64
    static let maxSlide = 9_999

    init?(text: String) {
        guard text.utf8.count <= Self.maxLength else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let name = parts[0]
        let argument = parts.count > 1 ? parts[1] : nil

        switch (name, argument) {
        case ("next", nil): self = .next
        case ("prev", nil): self = .previous
        case ("first", nil): self = .first
        case ("start", nil): self = .start
        case ("stop", nil): self = .stop
        case ("black", nil): self = .black
        case ("reload", nil): self = .reload
        case ("hello", let pin?) where PairingGate.isWellFormed(pin):
            self = .hello(pin: pin)
        case ("resume", let token?) where TokenStore.isWellFormed(token):
            self = .resume(token: token)
        case ("goto", let value?):
            guard value.allSatisfy(\.isASCII), let slide = Int(value), (1...Self.maxSlide).contains(slide) else {
                return nil
            }
            self = .goTo(slide: slide)
        default:
            return nil
        }
    }

    /// Forma testuale canonica, uguale a quella che invia il telefono.
    var wireText: String {
        switch self {
        case .hello(let pin): return "hello:\(pin)"
        case .resume(let token): return "resume:\(token)"
        case .next: return "next"
        case .previous: return "prev"
        case .first: return "first"
        case .goTo(let slide): return "goto:\(slide)"
        case .start: return "start"
        case .stop: return "stop"
        case .black: return "black"
        case .reload: return "reload"
        }
    }

    var isNavigation: Bool {
        switch self {
        case .next, .previous, .first, .goTo, .start, .stop: return true
        default: return false
        }
    }
}
