import AppKit
import os

enum BridgeError: Error, Equatable {
    case notPermitted
    case notRunning
    case noSlideShow
    case noPresentation
    case timeout
    case script(String)

    var userMessage: String {
        switch self {
        case .notPermitted:
            return "Manca il permesso: Impostazioni di Sistema › Privacy e sicurezza › Automazione › Telecomando Slide › PowerPoint"
        case .notRunning: return "PowerPoint non è aperto"
        case .noSlideShow: return "La presentazione non è avviata"
        case .noPresentation: return "Nessuna presentazione aperta in PowerPoint"
        case .timeout: return "PowerPoint non risponde"
        case .script(let message): return "Errore PowerPoint: \(message)"
        }
    }
}

/// Legge lo stato e comanda PowerPoint tramite AppleScript eseguito in-process.
/// Va usato solo dal main thread (NSAppleScript non è thread-safe).
final class PowerPointBridge {
    static let bundleID = "com.microsoft.Powerpoint"

    private let log = Logger(subsystem: AppInfo.subsystem, category: "powerpoint")
    private var compiled: NSAppleScript?

    /// Controllato prima di ogni comando: un Apple Event verso un'app chiusa la aprirebbe.
    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty
    }

    func readState() -> Result<PresentationState, BridgeError> {
        guard isRunning else { return .success(.closed) }
        return call("readstate").flatMap(Self.parseState)
    }

    func readDeck() -> Result<Deck, BridgeError> {
        guard isRunning else { return .failure(.notRunning) }
        return call("readdeck").flatMap(Self.parseDeck)
    }

    func perform(_ command: Command) -> Result<Void, BridgeError> {
        guard let (handler, arguments) = Self.handler(for: command) else { return .success(()) }
        guard isRunning else { return .failure(.notRunning) }
        return call(handler, arguments).map { _ in () }
    }

    // MARK: - Esecuzione

    private static func handler(for command: Command) -> (String, [NSAppleEventDescriptor])? {
        switch command {
        case .next: return ("gonext", [])
        case .previous: return ("goprev", [])
        case .first: return ("gofirst", [])
        case .goTo(let slide): return ("goslide", [NSAppleEventDescriptor(int32: Int32(slide))])
        case .start: return ("startshow", [])
        case .stop: return ("endshow", [])
        case .black: return ("toggleblack", [])
        case .hello, .reload: return nil
        }
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
        case -600, -609: return .notRunning
        case -1712: return .timeout
        case 1001: return .noSlideShow
        case 1003: return .noPresentation
        default: return .script(message)
        }
    }

    // MARK: - Lettura risultati

    private static func parseState(_ d: NSAppleEventDescriptor) -> Result<PresentationState, BridgeError> {
        guard d.numberOfItems == 6 else { return .failure(.script("stato inatteso")) }
        let state = PresentationState(
            ppt: true,
            running: d.atIndex(1)?.booleanValue ?? false,
            slide: Int(d.atIndex(2)?.int32Value ?? 0),
            count: Int(d.atIndex(3)?.int32Value ?? 0),
            black: d.atIndex(4)?.booleanValue ?? false,
            elapsed: d.atIndex(5)?.doubleValue ?? 0,
            key: d.atIndex(6)?.stringValue ?? ""
        )
        return .success(state)
    }

    private static func parseDeck(_ d: NSAppleEventDescriptor) -> Result<Deck, BridgeError> {
        guard d.numberOfItems == 3, let list = d.atIndex(3) else { return .failure(.script("elenco slide inatteso")) }
        let slides = list.numberOfItems < 1 ? [] : (1...list.numberOfItems).compactMap { index -> SlideInfo? in
            guard let item = list.atIndex(index), item.numberOfItems == 3 else { return nil }
            return SlideInfo(
                title: TextCleanup.normalize(item.atIndex(1)?.stringValue ?? ""),
                notes: TextCleanup.normalize(item.atIndex(2)?.stringValue ?? ""),
                hidden: item.atIndex(3)?.booleanValue ?? false
            )
        }
        return .success(Deck(key: d.atIndex(2)?.stringValue ?? "", name: d.atIndex(1)?.stringValue ?? "", slides: slides))
    }
}

private func fourCC(_ code: String) -> FourCharCode {
    code.utf8.reduce(0) { ($0 << 8) | FourCharCode($1) }
}
