import AppKit
import os

enum BridgeError: Error, Equatable {
    case notPermitted
    case notRunning
    case noSlideShow
    case noPresentation
    case invalidSlide
    case hiddenSlide
    case endOfShow
    case jumpFailed
    case alreadyRunning
    case beforeShowStart
    case timeout
    case script(String)

    var userMessage: String {
        switch self {
        case .notPermitted:
            return "Manca il permesso: Impostazioni di Sistema › Privacy e sicurezza › Automazione › Telecomando Slide › PowerPoint"
        case .notRunning: return "PowerPoint non è aperto"
        case .noSlideShow: return "La presentazione non è avviata"
        case .noPresentation: return "Nessuna presentazione aperta in PowerPoint"
        case .invalidSlide: return "Questa slide non esiste"
        case .hiddenSlide: return "La slide è nascosta: in presentazione non ci si può andare"
        case .endOfShow: return "Raggiunta la fine della presentazione"
        case .jumpFailed: return "Salto alla slide non riuscito"
        case .alreadyRunning: return "La presentazione è già avviata"
        case .beforeShowStart: return "La presentazione è partita da una slide successiva"
        case .timeout: return "PowerPoint non risponde"
        case .script(let message): return "Errore PowerPoint: \(message)"
        }
    }
}

/// Cosa serve al Controller da PowerPoint (sostituibile con un finto nei test).
protocol PresentationBridge: AnyObject {
    func readState() -> Result<PresentationState, BridgeError>
    func readDeckInfo() -> Result<DeckInfo, BridgeError>
    func readSlides(from: Int, to: Int) -> Result<(key: String, slides: [SlideInfo]), BridgeError>
    func perform(_ command: Command) -> Result<Void, BridgeError>
    /// `restart`: chiude la presentazione in corso e la riavvia da `slide`.
    func startShow(from slide: Int, restart: Bool) -> Result<Void, BridgeError>
    func step(toward slide: Int, maxSteps: Int, stuck: Int) -> Result<JumpProgress, BridgeError>
    /// Esporta la presentazione corrente in PDF; restituisce la sua chiave.
    func exportPDF(to url: URL) -> Result<String, BridgeError>
}

/// Legge lo stato e comanda PowerPoint tramite AppleScript eseguito in-process.
/// Va usato solo dal main thread (NSAppleScript non è thread-safe); ogni chiamata è breve.
final class PowerPointBridge: PresentationBridge {
    static let bundleID = "com.microsoft.Powerpoint"

    private let log = Logger(subsystem: AppInfo.subsystem, category: "powerpoint")
    private var compiled: NSAppleScript?

    /// Controllato prima di ogni chiamata: un Apple Event verso un'app chiusa la riaprirebbe.
    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty
    }

    func readState() -> Result<PresentationState, BridgeError> {
        guard isRunning else { return .success(.closed) }
        return call("readstate").flatMap(Self.parseState)
    }

    func readDeckInfo() -> Result<DeckInfo, BridgeError> {
        guard isRunning else { return .failure(.notRunning) }
        return call("deckinfo").flatMap { d in
            guard d.numberOfItems == 3 else { return .failure(.script("presentazione inattesa")) }
            return .success(DeckInfo(
                name: d.atIndex(1)?.stringValue ?? "",
                key: d.atIndex(2)?.stringValue ?? "",
                count: Int(d.atIndex(3)?.int32Value ?? 0)
            ))
        }
    }

    func readSlides(from: Int, to: Int) -> Result<(key: String, slides: [SlideInfo]), BridgeError> {
        guard isRunning else { return .failure(.notRunning) }
        return call("readslides", [Self.int(from), Self.int(to)]).flatMap(Self.parseSlides)
    }

    func perform(_ command: Command) -> Result<Void, BridgeError> {
        guard let handler = Self.handler(for: command) else { return .success(()) }
        guard isRunning else { return .failure(.notRunning) }
        return call(handler).map { _ in () }
    }

    func startShow(from slide: Int, restart: Bool) -> Result<Void, BridgeError> {
        guard isRunning else { return .failure(.notRunning) }
        return call(restart ? "restartfrom" : "startfrom", [Self.int(slide)]).map { _ in () }
    }

    func step(toward slide: Int, maxSteps: Int, stuck: Int) -> Result<JumpProgress, BridgeError> {
        guard isRunning else { return .failure(.notRunning) }
        return call("steptoward", [Self.int(slide), Self.int(maxSteps), Self.int(stuck)]).flatMap { d in
            guard d.numberOfItems == 3 else { return .failure(.script("risposta inattesa al salto")) }
            return .success(JumpProgress(
                slide: Int(d.atIndex(1)?.int32Value ?? 0),
                done: d.atIndex(2)?.booleanValue ?? false,
                stuck: Int(d.atIndex(3)?.int32Value ?? 0)
            ))
        }
    }

    func exportPDF(to url: URL) -> Result<String, BridgeError> {
        guard isRunning else { return .failure(.notRunning) }
        return call("exportpdf", [NSAppleEventDescriptor(string: url.path)]).map { $0.stringValue ?? "" }
    }

    // MARK: - Esecuzione

    private static func handler(for command: Command) -> String? {
        switch command {
        case .next: return "gonext"
        case .previous: return "goprev"
        case .first: return "gofirst"
        case .start: return "startshow"
        case .stop: return "endshow"
        case .black: return "toggleblack"
        case .hello, .resume, .reload, .goTo, .startFrom, .thumbs: return nil
        }
    }

    private static func int(_ value: Int) -> NSAppleEventDescriptor {
        NSAppleEventDescriptor(int32: Int32(clamping: value))
    }

    private func script() -> Result<NSAppleScript, BridgeError> {
        if let compiled { return .success(compiled) }
        guard let script = NSAppleScript(source: PowerPointScript.source) else {
            return .failure(.script("script non valido"))
        }
        var error: NSDictionary?
        guard script.compileAndReturnError(&error) else {
            let message = error?[NSAppleScript.errorMessage] as? String ?? "compilazione fallita"
            log.error("Compilazione AppleScript fallita: \(message, privacy: .public)")
            return .failure(.script(message))
        }
        compiled = script
        return .success(script)
    }

    private func call(_ handler: String, _ arguments: [NSAppleEventDescriptor] = []) -> Result<NSAppleEventDescriptor, BridgeError> {
        dispatchPrecondition(condition: .onQueue(.main))
        return script().flatMap { script in
            let event = Self.subroutineEvent(named: handler, arguments: arguments)
            var error: NSDictionary?
            let result = script.executeAppleEvent(event, error: &error)
            if let error {
                let mapped = Self.mapError(error)
                log.error("\(handler, privacy: .public) fallito: \(mapped.userMessage, privacy: .public)")
                return .failure(mapped)
            }
            return .success(result)
        }
    }

    private static func subroutineEvent(named name: String, arguments: [NSAppleEventDescriptor]) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(
            eventClass: fourCC("ascr"),
            eventID: fourCC("psbr"),
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setDescriptor(NSAppleEventDescriptor(string: name.lowercased()), forKeyword: fourCC("snam"))
        let list = NSAppleEventDescriptor.list()
        for (offset, argument) in arguments.enumerated() {
            list.insert(argument, at: offset + 1)
        }
        event.setParam(list, forKeyword: fourCC("----"))
        return event
    }

    private static func mapError(_ error: NSDictionary) -> BridgeError {
        let code = error[NSAppleScript.errorNumber] as? Int ?? 0
        let message = error[NSAppleScript.errorMessage] as? String ?? "sconosciuto"
        switch code {
        case -1743, -10004: return .notPermitted
        case -600, -609, 1004: return .notRunning
        case -1712: return .timeout
        case 1001: return .noSlideShow
        case 1002: return .invalidSlide
        case 1003: return .noPresentation
        case 1005: return .hiddenSlide
        case 1006: return .endOfShow
        case 1007: return .jumpFailed
        case 1008: return .alreadyRunning
        case 1009: return .beforeShowStart
        default: return .script(message)
        }
    }

    // MARK: - Lettura risultati

    private static func parseState(_ d: NSAppleEventDescriptor) -> Result<PresentationState, BridgeError> {
        guard d.numberOfItems == 7 else { return .failure(.script("stato inatteso")) }
        return .success(PresentationState(
            ppt: true,
            running: d.atIndex(1)?.booleanValue ?? false,
            slide: Int(d.atIndex(2)?.int32Value ?? 0),
            count: Int(d.atIndex(3)?.int32Value ?? 0),
            black: d.atIndex(4)?.booleanValue ?? false,
            elapsed: d.atIndex(5)?.doubleValue ?? 0,
            key: d.atIndex(6)?.stringValue ?? "",
            slideID: Int(d.atIndex(7)?.int32Value ?? 0)
        ))
    }

    private static func parseSlides(_ d: NSAppleEventDescriptor) -> Result<(key: String, slides: [SlideInfo]), BridgeError> {
        guard d.numberOfItems == 2, let list = d.atIndex(2) else { return .failure(.script("elenco slide inatteso")) }
        let slides = list.numberOfItems < 1 ? [] : (1...list.numberOfItems).compactMap { index -> SlideInfo? in
            guard let item = list.atIndex(index), item.numberOfItems == 4 else { return nil }
            return SlideInfo(
                title: TextCleanup.normalize(item.atIndex(1)?.stringValue ?? ""),
                notes: TextCleanup.normalize(item.atIndex(2)?.stringValue ?? ""),
                hidden: item.atIndex(3)?.booleanValue ?? false,
                id: Int(item.atIndex(4)?.int32Value ?? 0)
            )
        }
        return .success((key: d.atIndex(1)?.stringValue ?? "", slides: slides))
    }
}

private func fourCC(_ code: String) -> FourCharCode {
    code.utf8.reduce(0) { ($0 << 8) | FourCharCode($1) }
}
