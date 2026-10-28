import Foundation

/// Verifica da Terminale del collegamento con PowerPoint, senza Bluetooth.
///   --selftest       legge stato e note della presentazione ATTIVA
///   --selftest-nav   in più avvia la presentazione attiva e prova avanti/indietro/salto/nero:
///                    usarlo solo con una presentazione di prova in primo piano.
enum SelfTest {
    static func run(navigate: Bool) -> Never {
        let bridge = PowerPointBridge()
        print("PowerPoint aperto: \(bridge.isRunning)")
        printState(bridge)
        printDeck(bridge)

        if navigate {
            let steps: [Command] = [.start, .first, .next, .next, .next, .previous, .goTo(slide: 3), .goTo(slide: 1), .black, .black]
            steps.forEach { run($0, bridge) }
            if case .success(let info) = bridge.readDeckInfo(), info.count > 0 {
                run(.goTo(slide: info.count), bridge) // ultima slide: se nascosta deve dare errore, non uscire
            }
            run(.stop, bridge)
        }
        exit(0)
    }

    private static func run(_ step: Command, _ bridge: PowerPointBridge) {
        let outcome: Result<Void, BridgeError>
        if case .goTo(let slide) = step {
            outcome = jump(to: slide, bridge)
        } else {
            outcome = bridge.perform(step)
        }
        Thread.sleep(forTimeInterval: step == .start ? 1.5 : 0.4)
        if case .failure(let error) = outcome {
            print("\(step.wireText): ERRORE \(error.userMessage)")
        } else {
            print("\(step.wireText): ok")
        }
        printState(bridge)
    }

    private static func jump(to slide: Int, _ bridge: PowerPointBridge) -> Result<Void, BridgeError> {
        for _ in 0..<Controller.Timing.maxJumpRounds {
            switch bridge.step(toward: slide, maxSteps: Controller.Timing.jumpStepsPerRound) {
            case .success(let progress) where progress.done: return .success(())
            case .success: continue
            case .failure(let error): return .failure(error)
            }
        }
        return .failure(.jumpFailed)
    }

    private static func printDeck(_ bridge: PowerPointBridge) {
        switch bridge.readDeckInfo() {
        case .success(let info):
            print("Presentazione: \(info.name) — \(info.count) slide — chiave \(info.key)")
            guard info.count > 0 else { return }
            switch bridge.readSlides(from: 1, to: info.count) {
            case .success(let chunk):
                for (index, slide) in chunk.slides.enumerated() {
                    let notes = slide.notes.replacingOccurrences(of: "\n", with: " ⏎ ")
                    print("  \(index + 1). #\(slide.id) [\(slide.title)]\(slide.hidden ? " (nascosta)" : "") note: \(notes)")
                }
            case .failure(let error):
                print("Note: ERRORE \(error.userMessage)")
            }
        case .failure(let error):
            print("Presentazione: ERRORE \(error.userMessage)")
        }
    }

    private static func printState(_ bridge: PowerPointBridge) {
        switch bridge.readState() {
        case .success(let s):
            print("  stato: avviata=\(s.running) slide=\(s.slide)/\(s.count) id=\(s.slideID) nero=\(s.black) tempo=\(Int(s.elapsed))s")
        case .failure(let error):
            print("  stato: ERRORE \(error.userMessage)")
        }
    }
}
