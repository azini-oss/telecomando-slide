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

let twoWrong = gate.verify("1111", at: start).gate.verify("2222", at: start).gate
let reset = twoWrong.verify("4821", at: start).gate
check(reset.failures == 0, "un PIN giusto azzera gli errori")
check(gate.failures == 0, "verify non modifica il gate originale")

check(PairingGate.randomPIN().count == 4, "PIN casuale di 4 cifre")
check(PairingGate.randomPIN().allSatisfy(\.isNumber), "PIN casuale solo cifre")

// MARK: - Pulizia testo

check(TextCleanup.normalize("Uno\rDue\u{0B}Tre  \r\n") == "Uno\nDue\nTre",
      "a capo di PowerPoint convertiti e spazi finali tolti")
check(TextCleanup.normalize("A\u{2028}B\u{2029}C") == "A\nB\nC", "separatori Unicode convertiti")
check(TextCleanup.normalize(String(repeating: "a", count: 30_000)).count == TextCleanup.maxLength,
      "note troppo lunghe tagliate")

// MARK: - Stato

let base = PresentationState(ppt: true, running: true, slide: 2, count: 5, black: false, elapsed: 10, key: "a#5")
check(!base.differs(from: PresentationState(ppt: true, running: true, slide: 2, count: 5, black: false, elapsed: 11, key: "a#5")),
      "il solo tempo trascorso non conta come cambio")
check(base.differs(from: PresentationState(ppt: true, running: true, slide: 3, count: 5, black: false, elapsed: 10, key: "a#5")),
      "cambio slide rilevato")

print("\(passed) ok, \(failures) falliti")
exit(failures == 0 ? 0 : 1)
