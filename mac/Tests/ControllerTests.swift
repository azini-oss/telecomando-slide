import Foundation

// Test del Controller con PowerPoint e Bluetooth finti.

final class FakeBridge: PresentationBridge {
    var state = PresentationState(ppt: true, running: true, slide: 1, count: 3, black: false, elapsed: 0, key: "k#3", slideID: 101)
    var slides: [SlideInfo] = (1...3).map { SlideInfo(title: "T\($0)", notes: "N\($0)", hidden: $0 == 3, id: 100 + $0) }
    var failSlideReads = 0
    var slideReads = 0
    var performed: [Command] = []
    var starts: [(slide: Int, restart: Bool)] = []
    var exports = 0
    /// Prima slide raggiungibile: come PowerPoint quando la presentazione parte da un intervallo.
    var rangeStart = 1

    func show(at slide: Int) {
        state = PresentationState(ppt: true, running: true, slide: slide, count: slides.count, black: false,
                                  elapsed: 0, key: state.key, slideID: slides[slide - 1].id)
    }

    func readState() -> Result<PresentationState, BridgeError> { .success(state) }

    func readDeckInfo() -> Result<DeckInfo, BridgeError> {
        .success(DeckInfo(name: "Prova", key: state.key, count: slides.count))
    }

    func readSlides(from: Int, to: Int) -> Result<(key: String, slides: [SlideInfo]), BridgeError> {
        slideReads += 1
        if failSlideReads > 0 {
            failSlideReads -= 1
            return .failure(.timeout)
        }
        return .success((key: state.key, slides: Array(slides[(from - 1)..<min(to, slides.count)])))
    }

    func perform(_ command: Command) -> Result<Void, BridgeError> {
        performed.append(command)
        return .success(())
    }

    func startShow(from slide: Int, restart: Bool) -> Result<Void, BridgeError> {
        starts.append((slide: slide, restart: restart))
        if state.running && !restart { return .failure(.alreadyRunning) }
        rangeStart = slide
        show(at: slide)
        return .success(())
    }

    /// Come PowerPoint: scrive davvero un file (il servizio controlla che sia nuovo).
    func exportPDF(to url: URL) -> Result<String, BridgeError> {
        exports += 1
        try? Data("pdf finto".utf8).write(to: url)
        return .success(state.key)
    }

    func step(toward slide: Int, maxSteps: Int, stuck: Int) -> Result<JumpProgress, BridgeError> {
        guard !slides[slide - 1].hidden else { return .failure(.hiddenSlide) }
        if slide < state.slide && state.slide == rangeStart { return .failure(.beforeShowStart) }
        let next = state.slide < slide ? state.slide + 1 : state.slide - 1
        show(at: next)
        return .success(JumpProgress(slide: next, done: next == slide, stuck: 0))
    }
}

/// Una "miniatura" per pagina; le pagine sono quelle che PowerPoint esporterebbe (solo le visibili).
struct FakeRenderer: ThumbnailRendering {
    let pages: () -> Int
    func render(pdf: URL, width: CGFloat, completion: @escaping ([Data]?) -> Void) {
        completion((0..<pages()).map { Data([UInt8($0 + 1)]) })
    }
}

func runThumbnailTests() {
    let suite = "telecomando-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let pdf = FileManager.default.temporaryDirectory.appendingPathComponent("telecomando-test-\(UUID().uuidString).pdf")
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: pdf)
    }
    defaults.set("4821", forKey: Controller.Keys.pin)
    var pending: [() -> Void] = []
    func drain() {
        while !pending.isEmpty { pending.removeFirst()() }
    }

    let bridge = FakeBridge() // 3 slide, la terza nascosta, proiettata la 1
    var pages = 2
    let link = FakeLink()
    let controller = Controller(bridge: bridge, link: link, renderer: FakeRenderer(pages: { pages }),
                                thumbnailPDF: pdf, defaults: defaults, schedule: { pending.append($0) })
    controller.start()
    let phone = UUID()
    link.onSubscribe?(phone)
    link.onCommand?(phone, "hello:4821")
    drain()

    // Ordine slide → pagine: solo le visibili
    let deck = Deck(key: "k", name: "", slides: [
        SlideInfo(title: "", notes: "", hidden: false, id: 1),
        SlideInfo(title: "", notes: "", hidden: true, id: 2),
        SlideInfo(title: "", notes: "", hidden: false, id: 3),
    ])
    check(ThumbnailService.slideIDs(forPages: 2, deck: deck) == [1, 3], "pagine = slide visibili")
    check(ThumbnailService.slideIDs(forPages: 3, deck: deck) == [1, 2, 3], "pagine = tutte le slide")
    check(ThumbnailService.slideIDs(forPages: 5, deck: deck) == nil, "pagine che non tornano: nessuna miniatura sbagliata")
    check(Controller.thumbnailOrder(deck: deck, current: 2) == [2, 3, 1], "prima la proiettata e la successiva visibile")

    link.onCommand?(phone, "thumbs")
    check(link.messages(phone, "thumbs").last?["status"] as? String == "export", "avviso «esportazione» prima di occupare PowerPoint")
    check(bridge.exports == 0, "esportazione rimandata al giro successivo")
    drain()
    check(bridge.exports == 1, "PowerPoint esporta una volta")
    let thumbs = link.messages(phone, "thumb")
    check(thumbs.map { $0["id"] as? Int } == [101, 102], "una miniatura per slide visibile, prima la proiettata")
    check(thumbs.allSatisfy { $0["_bulk"] as? Bool == true }, "miniature in coda a bassa priorità")
    check(link.messages(phone, "thumbs").last?["status"] as? String == "done", "fine miniature segnalata")
    check(!FileManager.default.fileExists(atPath: pdf.path), "PDF temporaneo cancellato")

    link.onCommand?(phone, "thumbs")
    drain()
    check(bridge.exports == 2 && link.messages(phone, "thumb").count == 4, "ogni richiesta riesporta (miniature sempre aggiornate)")

    pages = 5
    link.onCommand?(phone, "thumbs")
    drain()
    check(bridge.exports == 3, "terza esportazione")
    check(link.messages(phone, "thumbs").last?["status"] as? String == "error", "pagine che non corrispondono: errore, non miniature sbagliate")
    check((link.messages(phone, "err").last?["msg"] as? String ?? "").contains("non corrispondono"), "errore spiegato")
}

func runStartFromTests() {
    let suite = "telecomando-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("4821", forKey: Controller.Keys.pin)
    var pending: [() -> Void] = []
    func drain() {
        while !pending.isEmpty { pending.removeFirst()() }
    }

    let bridge = FakeBridge()
    bridge.slides = (1...5).map { SlideInfo(title: "T\($0)", notes: "N\($0)", hidden: false, id: 100 + $0) }
    bridge.state = PresentationState(ppt: true, running: false, slide: 0, count: 5, black: false, elapsed: 0, key: "k#5", slideID: 0)
    let link = FakeLink()
    let controller = Controller(bridge: bridge, link: link, defaults: defaults, schedule: { pending.append($0) })
    controller.start()
    let phone = UUID()
    link.onSubscribe?(phone)
    link.onCommand?(phone, "hello:4821")
    drain()

    link.onCommand?(phone, "start:3")
    drain()
    check(bridge.starts.last?.slide == 3 && bridge.starts.last?.restart == false, "avvio dalla slide 3")
    let started = link.messages(phone, "state").last
    check(started?["slide"] as? Int == 3 && started?["from"] as? Int == 3, "il telefono sa da che slide è partita")

    link.onCommand?(phone, "goto:5")
    drain()
    check(bridge.state.slide == 5 && bridge.starts.count == 1, "a presentazione avviata si salta senza riavviare")

    link.onCommand?(phone, "goto:1")
    drain()
    check(bridge.starts.last?.slide == 1 && bridge.starts.last?.restart == true, "prima della partenza: riavvio dalla slide scelta")
    check(bridge.state.slide == 1, "riavviata dalla slide 1")
    check(link.messages(phone, "state").last?["from"] as? Int == 0, "riavviata dall'inizio: nessuna slide di partenza")
    check(link.messages(phone, "err").isEmpty, "nessun errore mostrato per il riavvio")

    link.onCommand?(phone, "start:2")
    drain()
    check(bridge.starts.count == 2 && bridge.state.slide == 2, "«avvia da» a presentazione già avviata = salto")
}

final class FakeLink: PhoneLink {
    var onStatusChange: ((BluetoothStatus) -> Void)?
    var onSubscribe: ((UUID) -> Void)?
    var onDisconnect: ((UUID) -> Void)?
    var onCommand: ((UUID, String) -> Void)?
    private(set) var inbox: [UUID: [[String: Any]]] = [:]

    func start(encrypted: Bool) {}
    func restart(encrypted: Bool) {}

    func send(_ payload: Data, to phone: UUID, bulk: Bool) -> Bool {
        var message = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] ?? [:]
        message["_bulk"] = bulk
        inbox[phone, default: []].append(message)
        return true
    }

    func messages(_ phone: UUID, _ type: String) -> [[String: Any]] {
        (inbox[phone] ?? []).filter { $0["t"] as? String == type }
    }
}

func runControllerTests() {
    let suite = "telecomando-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("4821", forKey: Controller.Keys.pin)

    var clock = Date(timeIntervalSince1970: 10_000)
    var pending: [() -> Void] = []
    func drain() {
        while !pending.isEmpty { pending.removeFirst()() }
    }

    let bridge = FakeBridge()
    let link = FakeLink()
    let controller = Controller(bridge: bridge, link: link, defaults: defaults, now: { clock }, schedule: { pending.append($0) })
    controller.start()

    let phone = UUID()
    let stranger = UUID()

    // Telefoni non autenticati
    link.onCommand?(phone, "next")
    check(bridge.performed.isEmpty && link.inbox[phone] == nil, "comandi senza codice ignorati e senza risposta")
    link.onCommand?(phone, "hello:4821")
    check(link.inbox[phone] == nil, "codice ignorato se il telefono non si è iscritto alle notifiche")

    // Codice giusto → token + note lette a blocchi senza bloccare
    link.onSubscribe?(phone)
    link.onCommand?(phone, "hello:0000")
    check(link.messages(phone, "auth").last?["ok"] as? Bool == false, "codice errato rifiutato")
    link.onCommand?(phone, "hello:4821")
    let auth = link.messages(phone, "auth").last
    let token = auth?["token"] as? String ?? ""
    check(auth?["ok"] as? Bool == true && TokenStore.isWellFormed(token), "codice giusto: accesso con token")
    check(link.messages(phone, "deck").isEmpty, "le note non sono ancora lette: arrivano a passi")
    drain()
    let deck = link.messages(phone, "deck").last
    check((deck?["slides"] as? [[String: Any]])?.count == 3, "note complete dopo i passi")
    check(link.messages(phone, "state").last?["slideId"] as? Int == 101, "stato con slide ID")

    // Comandi del telefono autenticato
    link.onCommand?(phone, "next")
    check(bridge.performed == [.next], "avanti eseguito")

    // Riconnessione con token, anche da un nuovo identificativo
    let sameDeviceLater = UUID()
    link.onSubscribe?(sameDeviceLater)
    link.onCommand?(sameDeviceLater, "resume:\(token)")
    check(link.messages(sameDeviceLater, "auth").last?["ok"] as? Bool == true, "riconnessione con token senza codice")
    check(link.messages(sameDeviceLater, "deck").count == 1, "il telefono riconnesso riceve subito le note")
    link.onSubscribe?(stranger)
    link.onCommand?(stranger, "resume:\(TokenStore.randomToken())")
    check(link.messages(stranger, "auth").last?["ok"] as? Bool == false, "token sconosciuto rifiutato")

    // Salto: a passi, e mai su una slide nascosta
    link.onCommand?(phone, "goto:2")
    drain()
    check(bridge.state.slide == 2, "salto alla slide 2 completato")
    link.onCommand?(phone, "goto:3")
    drain()
    check((link.messages(phone, "err").last?["msg"] as? String ?? "").contains("nascosta"), "salto a slide nascosta: errore chiaro")
    check(bridge.state.slide == 2, "salto a slide nascosta: la presentazione non si muove")

    // Slide riordinate durante le prove: le note si rileggono
    let deckCount = link.messages(phone, "deck").count
    bridge.slides = [bridge.slides[1], bridge.slides[0], bridge.slides[2]]
    // La slide proiettata (ID 102) ora è la prima: stessa chiave, ordine diverso.
    bridge.state = PresentationState(ppt: true, running: true, slide: 1, count: 3, black: false,
                                     elapsed: 0, key: bridge.state.key, slideID: 102)
    clock = clock.addingTimeInterval(5)
    controller.tick()
    drain()
    check(link.messages(phone, "deck").count == deckCount + 1, "riordino rilevato: note rilette")

    // Lettura fallita: nuovo tentativo dopo l'attesa
    link.onCommand?(phone, "reload")
    bridge.failSlideReads = 1
    clock = clock.addingTimeInterval(5)
    link.onCommand?(phone, "reload")
    drain()
    let readsAfterFailure = bridge.slideReads
    controller.tick()
    drain()
    check(bridge.slideReads == readsAfterFailure, "nessun nuovo tentativo prima dell'attesa")
    clock = clock.addingTimeInterval(5)
    controller.tick()
    drain()
    check(bridge.slideReads > readsAfterFailure, "nuovo tentativo dopo l'attesa")

    // Molti tentativi da un estraneo: codice nuovo, ma il telefono collegato resta valido
    let pinBefore = controller.snapshot.pin
    for _ in 0..<Controller.Timing.newPINAfterFailures {
        link.onCommand?(stranger, "hello:0000")
        clock = clock.addingTimeInterval(4_000) // oltre ogni blocco
    }
    check(controller.snapshot.pin != pinBefore, "dopo troppi errori il codice cambia")
    check((controller.snapshot.problem ?? "").contains("codice nuovo"), "il menu avvisa dei tentativi")
    bridge.performed = []
    link.onCommand?(phone, "prev")
    check(bridge.performed == [.previous], "il telefono già collegato continua a funzionare")
    link.onCommand?(sameDeviceLater, "resume:\(token)")
    check(link.messages(sameDeviceLater, "auth").last?["ok"] as? Bool == true, "il token resta valido dopo il cambio automatico")

    // Codice nuovo scelto dall'utente: tutti fuori, token revocati
    controller.regeneratePIN()
    check(link.messages(phone, "auth").last?["ok"] as? Bool == false, "codice nuovo: il telefono viene avvisato")
    bridge.performed = []
    link.onCommand?(phone, "next")
    check(bridge.performed.isEmpty, "codice nuovo: i vecchi telefoni non comandano più")
    link.onCommand?(phone, "resume:\(token)")
    check(link.messages(phone, "auth").last?["ok"] as? Bool == false, "codice nuovo: token revocati")
}
