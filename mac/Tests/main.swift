import Foundation

// Mini test runner senza Xcode: compila con le sorgenti "pure" dell'app (vedi run_tests.sh).

var failures = 0
var passed = 0

func check(_ condition: Bool, _ message: @autoclosure () -> String) {
    if condition {
        passed += 1
    } else {
        failures += 1
        print("FALLITO: \(message())")
    }
}

func hex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

func loadJSON(_ name: String) -> [[String: Any]] {
    let root = URL(fileURLWithPath: CommandLine.arguments[1])
    let data = try! Data(contentsOf: root.appendingPathComponent("shared/\(name)"))
    return try! JSONSerialization.jsonObject(with: data) as! [[String: Any]]
}

// MARK: - Framing

for vector in loadJSON("framing-vectors.json") {
    let name = vector["name"] as! String
    let payload = Data((vector["payload"] as! String).utf8)
    let frames = Framing.frames(
        for: payload,
        messageID: UInt8(vector["messageId"] as! Int),
        maxFrameSize: vector["maxFrameSize"] as! Int
    )
    let expected = vector["frames"] as! [String]
    check(frames?.map(hex) == expected, "framing '\(name)': \(frames?.map(hex) ?? []) != \(expected)")
}

check(Framing.frames(for: Data(count: 10), messageID: 1, maxFrameSize: 3)?.count == 10,
      "frame minuscoli: almeno 1 byte di dati per frame")
check(Framing.frames(for: Data(count: 70_000), messageID: 1, maxFrameSize: 6) == nil,
      "oltre 65535 frame il messaggio viene rifiutato")

// MARK: - Comandi

for vector in loadJSON("command-vectors.json") {
    let text = vector["text"] as! String
    let expected = vector["expect"] as? String
    check(Command(text: text)?.wireText == expected,
          "comando '\(text)': \(Command(text: text)?.wireText ?? "nil") != \(expected ?? "nil")")
}

check(Command(text: String(repeating: "x", count: 200)) == nil, "comandi troppo lunghi rifiutati")

// MARK: - Codice di accoppiamento

let start = Date(timeIntervalSince1970: 1_000)
let gate = PairingGate(pin: "4821", maxFailures: 3, lockout: 60)

check(gate.verify("4821", at: start).result == .accepted, "PIN giusto accettato")

let afterWrong = (1...3).reduce(gate) { current, _ in current.verify("0000", at: start).gate }
check(afterWrong.verify("4821", at: start.addingTimeInterval(10)).result == .locked(retryIn: 50),
      "dopo 3 errori blocca anche il PIN giusto")
check(afterWrong.verify("4821", at: start.addingTimeInterval(61)).result == .accepted,
      "il blocco scade dopo 60 secondi")
check(afterWrong.totalFailures == 3, "errori totali contati")

let secondLock = (1...3).reduce(afterWrong) { current, _ in current.verify("0000", at: start.addingTimeInterval(61)).gate }
check(secondLock.verify("4821", at: start.addingTimeInterval(62)).result == .locked(retryIn: 119),
      "il secondo blocco dura il doppio")
check(secondLock.totalFailures == 6, "gli errori totali continuano a salire tra un blocco e l'altro")

let twoWrong = gate.verify("1111", at: start).gate.verify("2222", at: start).gate
let reset = twoWrong.verify("4821", at: start).gate
check(reset.failures == 0 && reset.totalFailures == 0 && reset.lockouts == 0, "un PIN giusto azzera gli errori")
check(gate.failures == 0, "verify non modifica il gate originale")

check(PairingGate.randomPIN().count == 4, "PIN casuale di 4 cifre")
check(PairingGate.randomPIN().allSatisfy(\.isNumber), "PIN casuale solo cifre")

// MARK: - Token di riconnessione

let token = TokenStore.randomToken()
check(TokenStore.isWellFormed(token), "token casuale ben formato")
check(TokenStore.randomToken() != token, "token diversi a ogni emissione")
let store = (1...7).reduce(TokenStore(tokens: [])) { current, _ in current.issuing(TokenStore.randomToken()) }
check(store.tokens.count == TokenStore.maxTokens, "al massimo \(TokenStore.maxTokens) token")
check(TokenStore(tokens: []).issuing(token).contains(token), "token emesso riconosciuto")

// MARK: - Pulizia testo

check(TextCleanup.normalize("Uno\rDue\u{0B}Tre  \r\n") == "Uno\nDue\nTre",
      "a capo di PowerPoint convertiti e spazi finali tolti")
check(TextCleanup.normalize("A\u{2028}B\u{2029}C") == "A\nB\nC", "separatori Unicode convertiti")
check(TextCleanup.normalize(String(repeating: "a", count: 30_000)).count == TextCleanup.maxLength,
      "note troppo lunghe tagliate")

// MARK: - Stato e note

func state(slide: Int, elapsed: Double = 10, key: String = "a#5", slideID: Int = 0) -> PresentationState {
    PresentationState(ppt: true, running: true, slide: slide, count: 5, black: false, elapsed: elapsed, key: key, slideID: slideID)
}

check(!state(slide: 2).differs(from: state(slide: 2, elapsed: 11)), "il solo tempo trascorso non conta come cambio")
check(state(slide: 2).differs(from: state(slide: 3)), "cambio slide rilevato")
check(state(slide: 2, slideID: 7).differs(from: state(slide: 2, slideID: 8)), "cambio di slide ID rilevato")

let deck = Deck(key: "a#5", name: "x", slides: (1...5).map { SlideInfo(title: "", notes: "", hidden: false, id: 100 + $0) })
check(!deck.isStale(for: state(slide: 2, slideID: 102)), "note allineate")
check(deck.isStale(for: state(slide: 2, slideID: 104)), "slide riordinate: note da rileggere")
check(deck.isStale(for: state(slide: 2, key: "b#5", slideID: 102)), "altra presentazione: note da rileggere")
check(!deck.isStale(for: state(slide: 0, slideID: 0)), "schermata finale: niente da rileggere")
let noIDs = Deck(key: "a#5", name: "x", slides: (1...5).map { _ in SlideInfo(title: "", notes: "", hidden: false, id: 0) })
check(!noIDs.isStale(for: state(slide: 2, slideID: 55)), "ID non disponibili: nessun ricaricamento continuo")

runControllerTests()
runStartFromTests()

print("\(passed) ok, \(failures) falliti")
exit(failures == 0 ? 0 : 1)
