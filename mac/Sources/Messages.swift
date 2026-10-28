import Foundation

/// Stato della presentazione letto da PowerPoint.
/// `slide` = 0 a presentazione avviata indica la schermata finale (dopo l'ultima slide).
struct PresentationState: Equatable {
    let ppt: Bool
    let running: Bool
    let slide: Int
    let count: Int
    let black: Bool
    let elapsed: Double
    let key: String
    let slideID: Int

    static let closed = PresentationState(
        ppt: false, running: false, slide: 0, count: 0, black: false, elapsed: 0, key: "", slideID: 0
    )

    /// Il tempo trascorso cambia sempre: non basta da solo per inviare un aggiornamento.
    func differs(from other: PresentationState) -> Bool {
        ppt != other.ppt || running != other.running || slide != other.slide || count != other.count
            || black != other.black || key != other.key || slideID != other.slideID
    }
}

struct SlideInfo: Codable, Equatable {
    let title: String
    let notes: String
    let hidden: Bool
    let id: Int
}

struct Deck: Equatable {
    let key: String
    let name: String
    let slides: [SlideInfo]

    /// Le note non corrispondono più alle slide (riordinate, aggiunte, tolte) anche se la chiave è uguale.
    func isStale(for state: PresentationState) -> Bool {
        guard state.key == key else { return true }
        guard state.running, state.slide > 0, state.slideID != 0 else { return false }
        guard state.slide <= slides.count else { return true }
        let id = slides[state.slide - 1].id
        return id != 0 && id != state.slideID // 0 = ID non disponibile: nessun confronto
    }
}

struct DeckInfo: Equatable {
    let name: String
    let key: String
    let count: Int
}

struct JumpProgress: Equatable {
    let slide: Int
    let done: Bool
    /// Passi indietro senza cambio di slide, da ripassare al giro successivo.
    let stuck: Int
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
    let slideId: Int
    /// Slide da cui è partita la presentazione (0 = dall'inizio): prima di questa PowerPoint non torna.
    let from: Int

    init(_ state: PresentationState, from: Int = 0) {
        self.from = from
        ppt = state.ppt
        running = state.running
        slide = state.slide
        count = state.count
        black = state.black
        elapsed = state.elapsed
        key = state.key
        slideId = state.slideID
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
    let token: String?

    static let rejected = AuthMessage(ok: false, retryIn: nil, token: nil)
}

/// Una miniatura (JPEG in base64), inviata con priorità bassa.
struct ThumbMessage: Encodable {
    let t = "thumb"
    let key: String
    let id: Int
    let jpg: String

    init(key: String, id: Int, jpeg: Data) {
        self.key = key
        self.id = id
        jpg = jpeg.base64EncodedString()
    }
}

/// Avanzamento delle miniature: "export" (PowerPoint esporta), "sending" (in arrivo), "done", "error".
struct ThumbsStatusMessage: Encodable {
    let t = "thumbs"
    let key: String
    let status: String
    let total: Int
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
