import AppKit
import PDFKit

enum ThumbnailError: Error, Equatable {
    case busy
    case exportFailed
    case unreadable
    case mismatch
    case bridge(BridgeError)

    var userMessage: String {
        switch self {
        case .busy: return "Miniature già in preparazione"
        case .exportFailed: return "PowerPoint non ha esportato le slide: salva la presentazione e riprova"
        case .unreadable: return "Non riesco a leggere le miniature: consenti a Telecomando Slide l'accesso ai dati di altre app"
        case .mismatch: return "Le miniature non corrispondono alle slide: tocca «Ricarica le note» e riprova"
        case .bridge(let error): return error.userMessage
        }
    }
}

/// Trasforma un PDF in miniature JPEG (sostituibile con un finto nei test).
protocol ThumbnailRendering {
    func render(pdf: URL, width: CGFloat, completion: @escaping ([Data]?) -> Void)
}

/// Miniature con PDFKit, fuori dal main thread. JPEG piccoli: viaggiano via Bluetooth.
struct PDFThumbnailRenderer: ThumbnailRendering {
    static let maxBytes = 30_000

    func render(pdf: URL, width: CGFloat, completion: @escaping ([Data]?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let images: [Data]? = PDFDocument(url: pdf).map { document in
                (0..<document.pageCount).compactMap { index in
                    document.page(at: index).flatMap { Self.jpeg(for: $0, width: width) }
                }
            }
            DispatchQueue.main.async { completion(images) }
        }
    }

    private static func jpeg(for page: PDFPage, width: CGFloat) -> Data? {
        let image = page.thumbnail(of: NSSize(width: width, height: width), for: .mediaBox)
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        // Si abbassa la qualità finché la miniatura non è abbastanza leggera.
        for quality in [0.6, 0.45, 0.3] {
            if let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality]),
               data.count <= maxBytes || quality == 0.3 {
                return data
            }
        }
        return nil
    }
}

/// Miniature della presentazione: PowerPoint esporta un PDF nella propria cartella (è in sandbox e
/// non può scrivere altrove), l'app lo legge, ne ricava le miniature e lo cancella.
/// Ogni richiesta riesporta: le miniature riflettono sempre le slide di quel momento.
final class ThumbnailService {
    struct Batch: Equatable {
        let key: String
        let images: [Int: Data] // ID slide → JPEG
    }

    static let width: CGFloat = 320

    private let bridge: PresentationBridge
    private let renderer: ThumbnailRendering
    private let pdfURL: URL
    private let now: () -> Date
    private(set) var isBusy = false

    init(bridge: PresentationBridge, renderer: ThumbnailRendering, pdfURL: URL, now: @escaping () -> Date = Date.init) {
        self.bridge = bridge
        self.renderer = renderer
        self.pdfURL = pdfURL
        self.now = now
    }

    /// Le pagine del PDF sono le slide visibili in ordine (PowerPoint non esporta le nascoste);
    /// se ci sono tutte, corrispondono una a una.
    static func slideIDs(forPages pages: Int, deck: Deck) -> [Int]? {
        let visible = deck.slides.filter { !$0.hidden }.map(\.id)
        if pages == visible.count { return visible }
        if pages == deck.slides.count { return deck.slides.map(\.id) }
        return nil
    }

    func load(deck: Deck, completion: @escaping (Result<Batch, ThumbnailError>) -> Void) {
        guard !isBusy else { return completion(.failure(.busy)) }
        isBusy = true
        let started = now()
        try? FileManager.default.removeItem(at: pdfURL)

        switch bridge.exportPDF(to: pdfURL) {
        case .failure(let error):
            finish(.failure(.bridge(error)), completion)
        case .success(let key) where key != deck.key:
            finish(.failure(.mismatch), completion)
        case .success:
            guard isFresh(since: started) else { return finish(.failure(.exportFailed), completion) }
            renderer.render(pdf: pdfURL, width: Self.width) { [weak self] images in
                guard let self else { return }
                try? FileManager.default.removeItem(at: self.pdfURL)
                guard let images, !images.isEmpty else { return self.finish(.failure(.unreadable), completion) }
                guard let ids = Self.slideIDs(forPages: images.count, deck: deck) else {
                    return self.finish(.failure(.mismatch), completion)
                }
                let batch = Batch(key: deck.key, images: Dictionary(zip(ids, images), uniquingKeysWith: { first, _ in first }))
                self.finish(.success(batch), completion)
            }
        }
    }

    private func isFresh(since start: Date) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: pdfURL.path),
              let modified = attributes[.modificationDate] as? Date else { return false }
        return modified >= start.addingTimeInterval(-2)
    }

    private func finish(_ result: Result<Batch, ThumbnailError>, _ completion: (Result<Batch, ThumbnailError>) -> Void) {
        isBusy = false
        completion(result)
    }
}
