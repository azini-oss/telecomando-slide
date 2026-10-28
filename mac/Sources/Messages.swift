import Foundation

/// Stato della presentazione letto da PowerPoint.
struct PresentationState: Equatable {
    let ppt: Bool
    let running: Bool
    let slide: Int
    let count: Int
    let black: Bool
    let elapsed: Double
    let key: String

    static let closed = PresentationState(ppt: false, running: false, slide: 0, count: 0, black: false, elapsed: 0, key: "")

    /// Il tempo trascorso cambia sempre: non basta da solo per inviare un aggiornamento.
    func differs(from other: PresentationState) -> Bool {
        ppt != other.ppt || running != other.running || slide != other.slide
            || count != other.count || black != other.black || key != other.key
    }
}

struct SlideInfo: Codable, Equatable {
    let title: String
    let notes: String
    let hidden: Bool
}

struct Deck: Equatable {
    let key: String
    let name: String
    let slides: [SlideInfo]
}

// MARK: - Messaggi Mac → telefono (JSON)

struct StateMessage: Encodable {
    let t = "state"
    let ppt: Bool
    let running: Bool
    let slide: Int
    let count: Int
    let black: Bool
    let elapsed: Double
    let key: String

    init(_ state: PresentationState) {
        ppt = state.ppt
        running = state.running
        slide = state.slide
        count = state.count
        black = state.black
        elapsed = state.elapsed
        key = state.key
    }
}

struct DeckMessage: Encodable {
    let t = "deck"
    let key: String
    let name: String
    let slides: [SlideInfo]

    init(_ deck: Deck) {
        key = deck.key
        name = deck.name
        slides = deck.slides
    }
}

struct AuthMessage: Encodable {
    let t = "auth"
    let ok: Bool
    let retryIn: Int?
}

struct ErrorMessage: Encodable {
    let t = "err"
    let msg: String
}

enum MessageEncoder {
    static func encode<T: Encodable>(_ message: T) -> Data? {
        try? JSONEncoder().encode(message)
    }
}
