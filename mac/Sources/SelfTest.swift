import Foundation

/// Verifica da Terminale del collegamento con PowerPoint, senza Bluetooth.
///   --selftest       legge stato e note
///   --selftest-nav   in più prova avanti/indietro/salto/schermo nero (presentazione avviata)
enum SelfTest {
    static func run(navigate: Bool) -> Never {
        let bridge = PowerPointBridge()
        print("PowerPoint aperto: \(bridge.isRunning)")
        printState(bridge)

        switch bridge.readDeck() {
        case .success(let deck):
            print("Presentazione: \(deck.name) — \(deck.slides.count) slide — chiave \(deck.key)")
            for (index, slide) in deck.slides.enumerated() {
                let notes = slide.notes.replacingOccurrences(of: "\n", with: " ⏎ ")
                print("  \(index + 1). [\(slide.title)]\(slide.hidden ? " (nascosta)" : "") note: \(notes)")
            }
        case .failure(let error):
            print("Note: ERRORE \(error.userMessage)")
        }

        if navigate {
            let steps: [Command] = [
                .start, .first, .next, .next, .next, .previous, .goTo(slide: 3), .goTo(slide: 1), .black, .black, .stop,
            ]
            for step in steps {
                let outcome = bridge.perform(step)
                Thread.sleep(forTimeInterval: step == .start ? 1.5 : 0.4)
                if case .failure(let error) = outcome {
                    print("\(step.wireText): ERRORE \(error.userMessage)")
                } else {
                    print("\(step.wireText): ok")
                }
                printState(bridge)
            }
        }
        exit(0)
    }

    private static func printState(_ bridge: PowerPointBridge) {
        switch bridge.readState() {
        case .success(let s):
            print("  stato: avviata=\(s.running) slide=\(s.slide)/\(s.count) nero=\(s.black) tempo=\(Int(s.elapsed))s")
        case .failure(let error):
            print("  stato: ERRORE \(error.userMessage)")
        }
    }
}
