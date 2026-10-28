import Foundation
import os

/// Quello che il menu mostra all'utente.
struct StatusSnapshot: Equatable {
    let bluetooth: BluetoothStatus
    let phones: Int
    let state: PresentationState
    let problem: String?
    let pin: String
    let encrypted: Bool
}

/// Collega telefoni e PowerPoint: autentica, esegue i comandi, invia stato e note.
/// Le operazioni lunghe sono spezzate in passi brevi (`schedule`) per non bloccare l'app.
final class Controller {
    enum Keys {
        static let pin = "pairingPIN"
        static let tokens = "resumeTokens"
        static let encrypted = "encryptedLink"
    }

    enum Timing {
        static let pollInterval: TimeInterval = 0.5
        static let heartbeat: TimeInterval = 10
        static let errorPause: TimeInterval = 3
        static let minDeckReload: TimeInterval = 2
        static let maxDeckBackoff: TimeInterval = 15
        static let deckChunk = 8
        static let jumpStepsPerRound = 6
        static let maxJumpRounds = 80
        static let newPINAfterFailures = 20
    }

    private struct DeckLoad {
        let generation: Int
        let info: DeckInfo
        let slides: [SlideInfo]
    }

    var onChange: ((StatusSnapshot) -> Void)?

    private let log = Logger(subsystem: AppInfo.subsystem, category: "controller")
    private let bridge: PresentationBridge
    private let link: PhoneLink
    private let thumbnails: ThumbnailService
    private var thumbRequesters: Set<UUID> = []
    private let defaults: UserDefaults
    private let now: () -> Date
    private let schedule: (@escaping () -> Void) -> Void

    private var gate: PairingGate
    private var tokens: TokenStore
    private var encrypted: Bool
    private var subscribed: Set<UUID> = []
    private var trusted: Set<UUID> = []
    private var bluetooth = BluetoothStatus.starting
    private var lastState = PresentationState.closed
    private var deck: Deck?
    private var deckLoad: DeckLoad?
    private var loadGeneration = 0
    private var deckFailures = 0
    private var deckRetryAt = Date.distantPast
    private var jumpTarget: Int?
    private var jumpGeneration = 0
    private var jumpRounds = 0
    private var jumpStuck = 0
    /// Slide da cui l'app ha avviato la presentazione (nil = dall'inizio).
    private var showStart: Int?
    private var bridgeProblem: String?
    private var pairingProblem: String?
    private var pollTimer: Timer?
    private var pausedUntil: Date?
    private var lastHeartbeat = Date.distantPast
    private var activity: NSObjectProtocol?

    init(
        bridge: PresentationBridge,
        link: PhoneLink,
        renderer: ThumbnailRendering = PDFThumbnailRenderer(),
        thumbnailPDF: URL = AppInfo.thumbnailPDFURL,
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        schedule: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }
    ) {
        self.bridge = bridge
        self.link = link
        thumbnails = ThumbnailService(bridge: bridge, renderer: renderer, pdfURL: thumbnailPDF, now: now)
        self.defaults = defaults
        self.now = now
        self.schedule = schedule
        let saved = defaults.string(forKey: Keys.pin).flatMap { PairingGate.isWellFormed($0) ? $0 : nil }
        let pin = saved ?? PairingGate.randomPIN()
        defaults.set(pin, forKey: Keys.pin)
        gate = PairingGate(pin: pin)
        tokens = TokenStore(tokens: (defaults.stringArray(forKey: Keys.tokens) ?? []).filter(TokenStore.isWellFormed))
        encrypted = defaults.bool(forKey: Keys.encrypted)
    }

    var snapshot: StatusSnapshot {
        StatusSnapshot(bluetooth: bluetooth, phones: trusted.count, state: lastState,
                       problem: bridgeProblem ?? pairingProblem, pin: gate.pin, encrypted: encrypted)
    }

    func start() {
        link.onStatusChange = { [weak self] status in
            self?.bluetooth = status
            self?.notify()
        }
        link.onSubscribe = { [weak self] phone in self?.subscribed.insert(phone) }
        link.onDisconnect = { [weak self] phone in self?.forget(phone) }
        link.onCommand = { [weak self] phone, text in self?.handle(text, from: phone) }
        link.start(encrypted: encrypted)
    }

    /// Codice nuovo scelto dall'utente: revoca anche le riconnessioni salvate dei telefoni.
    func regeneratePIN() {
        pairingProblem = nil
        rotatePIN(revokeAll: true)
    }

    func setEncrypted(_ on: Bool) {
        encrypted = on
        defaults.set(on, forKey: Keys.encrypted)
        subscribed = []
        trusted = []
        stopPolling()
        link.restart(encrypted: on)
        notify()
    }

    /// Un giro di lettura (chiamato dal timer; i test lo chiamano direttamente).
    func tick() {
        refresh(force: false)
    }

    // MARK: - Comandi dal telefono

    private func handle(_ text: String, from phone: UUID) {
        guard let command = Command(text: text) else {
            if trusted.contains(phone) { send(ErrorMessage(msg: "Comando non valido"), to: phone) }
            return
        }
        switch command {
        case .hello(let pin): authenticate(pin: pin, phone: phone)
        case .resume(let token): resume(token: token, phone: phone)
        default:
            guard trusted.contains(phone) else { return } // telefoni non autenticati: ignorati
            execute(command, from: phone)
        }
    }

    private func execute(_ command: Command, from phone: UUID) {
        if command.isNavigation { jumpTarget = nil }
        switch command {
        case .reload:
            deck = nil
            deckLoad = nil
            deckFailures = 0
            deckRetryAt = .distantPast
            refresh(force: true)
        case .thumbs:
            requestThumbnails(for: phone)
        case .goTo(let slide):
            startJump(to: slide)
        case .startFrom(let slide):
            if lastState.running {
                startJump(to: slide)
            } else {
                startShow(from: slide, restart: false)
            }
        case .start:
            showStart = nil
            if case .failure(let error) = bridge.perform(command) { report(error) }
            refresh(force: true)
        default:
            if case .failure(let error) = bridge.perform(command) { report(error) }
            refresh(force: true)
        }
    }

    private func authenticate(pin: String, phone: UUID) {
        guard subscribed.contains(phone) else { return }
        let (result, newGate) = gate.verify(pin, at: now())
        gate = newGate
        switch result {
        case .accepted:
            pairingProblem = nil
            let token = TokenStore.randomToken()
            tokens = tokens.issuing(token)
            defaults.set(tokens.tokens, forKey: Keys.tokens)
            trust(phone, token: token)
        case .rejected:
            log.notice("Codice errato da un telefono")
            send(AuthMessage.rejected, to: phone)
            noteFailedAttempt()
        case .locked(let seconds):
            log.notice("Troppi codici errati: blocco per \(seconds) s")
            send(AuthMessage(ok: false, retryIn: seconds, token: nil), to: phone)
            noteFailedAttempt()
        }
        notify()
    }

    private func resume(token: String, phone: UUID) {
        guard subscribed.contains(phone) else { return }
        guard tokens.contains(token) else {
            send(AuthMessage.rejected, to: phone)
            return
        }
        trust(phone, token: token)
        notify()
    }

    private func trust(_ phone: UUID, token: String) {
        trusted.insert(phone)
        send(AuthMessage(ok: true, retryIn: nil, token: token), to: phone)
        if let deck { send(DeckMessage(deck), to: phone) }
        startPolling()
        refresh(force: true)
    }

    /// Molti tentativi sbagliati = qualcuno vicino prova a indovinare: codice nuovo,
    /// ma i telefoni già collegati (e le loro riconnessioni) restano validi.
    private func noteFailedAttempt() {
        guard gate.totalFailures < Timing.newPINAfterFailures else {
            rotatePIN(revokeAll: false)
            pairingProblem = "Troppi codici errati da telefoni vicini: ho generato un codice nuovo"
            return
        }
        pairingProblem = "\(gate.totalFailures) codici errati da telefoni vicini"
    }

    private func rotatePIN(revokeAll: Bool) {
        let pin = PairingGate.randomPIN()
        defaults.set(pin, forKey: Keys.pin)
        gate = PairingGate(pin: pin)
        if revokeAll {
            tokens = TokenStore(tokens: [])
            defaults.set([String](), forKey: Keys.tokens)
            trusted.forEach { send(AuthMessage.rejected, to: $0) }
            trusted = []
            stopPolling()
        }
        notify()
    }

    private func forget(_ phone: UUID) {
        subscribed.remove(phone)
        guard trusted.remove(phone) != nil else { return }
        if trusted.isEmpty { stopPolling() }
        notify()
    }

    // MARK: - Avvio da una slide e salto (a passi brevi)

    private func startShow(from slide: Int, restart: Bool) {
        switch bridge.startShow(from: slide, restart: restart) {
        case .success:
            showStart = slide > 1 ? slide : nil
        case .failure(let error):
            report(error)
        }
        refresh(force: true)
    }

    private func startJump(to slide: Int) {
        jumpGeneration += 1
        jumpTarget = slide
        jumpRounds = 0
        jumpStuck = 0
        continueJump(jumpGeneration)
    }

    private func continueJump(_ generation: Int) {
        guard let target = jumpTarget, generation == jumpGeneration else { return }
        switch bridge.step(toward: target, maxSteps: Timing.jumpStepsPerRound, stuck: jumpStuck) {
        case .success(let progress):
            jumpRounds += 1
            jumpStuck = progress.stuck
            if progress.done {
                jumpTarget = nil
            } else if jumpRounds >= Timing.maxJumpRounds {
                jumpTarget = nil
                report(.jumpFailed)
            } else {
                schedule { [weak self] in self?.continueJump(generation) }
            }
        case .failure(.beforeShowStart):
            // Partita da una slide successiva: PowerPoint non torna indietro, si riavvia da quella voluta.
            jumpTarget = nil
            startShow(from: target, restart: true)
            return
        case .failure(let error):
            jumpTarget = nil
            report(error)
        }
        refresh(force: true)
    }

    // MARK: - Lettura periodica di PowerPoint

    private func startPolling() {
        guard pollTimer == nil else { return }
        let timer = Timer(timeInterval: Timing.pollInterval, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common) // continua anche con il menu aperto
        pollTimer = timer
        // Evita che App Nap rallenti la lettura mentre PowerPoint è in primo piano.
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Telefono collegato alla presentazione")
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    private func refresh(force: Bool) {
        guard !trusted.isEmpty else { return }
        if !force, let pausedUntil, now() < pausedUntil { return }

        switch bridge.readState() {
        case .success(let state):
            let hadProblem = bridgeProblem != nil
            pausedUntil = nil
            bridgeProblem = nil
            let changed = state.differs(from: lastState)
            let heartbeatDue = now().timeIntervalSince(lastHeartbeat) >= Timing.heartbeat
            if lastState.running && !state.running { showStart = nil } // presentazione chiusa
            lastState = state
            if changed || force || heartbeatDue {
                broadcast(StateMessage(state, from: showStart ?? 0))
                lastHeartbeat = now()
            }
            ensureDeck(for: state)
            if changed || hadProblem { notify() }
        case .failure(let error):
            pausedUntil = now().addingTimeInterval(Timing.errorPause)
            report(error)
        }
    }

    // MARK: - Note (lette a blocchi)

    private func ensureDeck(for state: PresentationState) {
        guard deckLoad == nil, now() >= deckRetryAt else { return }
        guard deck.map({ $0.isStale(for: state) }) ?? true else { return }
        guard state.ppt, !state.key.isEmpty, state.count > 0 else {
            finishDeck(Deck(key: state.key, name: "", slides: []))
            return
        }
        switch bridge.readDeckInfo() {
        case .success(let info):
            guard !info.key.isEmpty, info.count > 0 else {
                finishDeck(Deck(key: info.key, name: info.name, slides: []))
                return
            }
            loadGeneration += 1
            let generation = loadGeneration
            deckLoad = DeckLoad(generation: generation, info: info, slides: [])
            schedule { [weak self] in self?.continueDeckLoad(generation) }
        case .failure(let error):
            deckLoadFailed(error)
        }
    }

    private func continueDeckLoad(_ generation: Int) {
        guard let load = deckLoad, load.generation == generation else { return }
        let from = load.slides.count + 1
        let to = min(load.info.count, from + Timing.deckChunk - 1)
        switch bridge.readSlides(from: from, to: to) {
        case .success(let chunk):
            guard chunk.key == load.info.key, !chunk.slides.isEmpty else {
                deckLoad = nil // presentazione cambiata durante la lettura: si riparte al prossimo giro
                return
            }
            let slides = load.slides + chunk.slides
            if slides.count >= load.info.count {
                deckLoad = nil
                finishDeck(Deck(key: load.info.key, name: load.info.name, slides: slides))
            } else {
                deckLoad = DeckLoad(generation: generation, info: load.info, slides: slides)
                schedule { [weak self] in self?.continueDeckLoad(generation) }
            }
        case .failure(let error):
            deckLoad = nil
            deckLoadFailed(error)
        }
    }

    private func finishDeck(_ loaded: Deck) {
        let changed = loaded != deck
        deck = loaded
        deckFailures = 0
        deckRetryAt = now().addingTimeInterval(Timing.minDeckReload)
        guard changed else { return }
        if !broadcast(DeckMessage(loaded)) {
            broadcast(ErrorMessage(msg: "Presentazione troppo grande per il Bluetooth: note non inviate"))
        }
    }

    private func deckLoadFailed(_ error: BridgeError) {
        deckFailures += 1
        deckRetryAt = now().addingTimeInterval(min(Timing.maxDeckBackoff, pow(2, Double(deckFailures))))
        report(error)
        if deckFailures == 3 {
            broadcast(ErrorMessage(msg: "Note non disponibili: riprova con «Ricarica le note»"))
        }
    }

    private func report(_ error: BridgeError) {
        let message = error.userMessage
        guard message != bridgeProblem else { return }
        bridgeProblem = message
        broadcast(ErrorMessage(msg: message))
        notify()
    }

    // MARK: - Miniature (solo su richiesta del telefono)

    private func requestThumbnails(for phone: UUID) {
        guard let deck, !deck.slides.isEmpty, !deck.isStale(for: lastState) else {
            send(ThumbsStatusMessage(key: lastState.key, status: "error", total: 0), to: phone)
            send(ErrorMessage(msg: "Aspetta che le note siano caricate, poi riprova"), to: phone)
            return
        }
        thumbRequesters.insert(phone)
        guard !thumbnails.isBusy else { return }
        send(ThumbsStatusMessage(key: deck.key, status: "export", total: 0), to: phone)
        // Al giro successivo: l'avviso parte prima che PowerPoint resti occupato con l'esportazione.
        schedule { [weak self] in
            self?.thumbnails.load(deck: deck) { result in self?.thumbnailsLoaded(result, deck: deck) }
        }
    }

    private func thumbnailsLoaded(_ result: Result<ThumbnailService.Batch, ThumbnailError>, deck: Deck) {
        let phones = thumbRequesters.filter(trusted.contains)
        thumbRequesters = []
        switch result {
        case .success(let batch):
            sendThumbnails(batch, deck: deck, to: phones)
        case .failure(.busy):
            break
        case .failure(let error):
            log.error("Miniature non riuscite: \(error.userMessage, privacy: .public)")
            phones.forEach { phone in
                send(ThumbsStatusMessage(key: deck.key, status: "error", total: 0), to: phone)
                send(ErrorMessage(msg: error.userMessage), to: phone)
            }
        }
    }

    private func sendThumbnails(_ batch: ThumbnailService.Batch, deck: Deck, to phones: Set<UUID>) {
        let ids = Self.thumbnailOrder(deck: deck, current: lastState.slide).filter { batch.images[$0] != nil }
        for phone in phones {
            send(ThumbsStatusMessage(key: batch.key, status: "sending", total: ids.count), to: phone)
            for id in ids {
                guard let jpeg = batch.images[id] else { continue }
                send(ThumbMessage(key: batch.key, id: id, jpeg: jpeg), to: phone, bulk: true)
            }
            // Anche "fatto" in coda bassa: arriva dopo l'ultima miniatura.
            send(ThumbsStatusMessage(key: batch.key, status: "done", total: ids.count), to: phone, bulk: true)
        }
    }

    /// Prima la slide proiettata e la successiva, poi le altre in ordine.
    static func thumbnailOrder(deck: Deck, current: Int) -> [Int] {
        let ids = deck.slides.map(\.id)
        guard current >= 1, current <= ids.count else { return ids }
        let firsts = [ids[current - 1]] + (deck.slides.dropFirst(current).first { !$0.hidden }.map { [$0.id] } ?? [])
        return firsts + ids.filter { !firsts.contains($0) }
    }

    // MARK: - Invio

    @discardableResult
    private func broadcast<T: Encodable>(_ message: T) -> Bool {
        trusted.reduce(true) { ok, phone in send(message, to: phone) && ok }
    }

    @discardableResult
    private func send<T: Encodable>(_ message: T, to phone: UUID, bulk: Bool = false) -> Bool {
        guard let data = MessageEncoder.encode(message) else { return false }
        return link.send(data, to: phone, bulk: bulk)
    }

    private func notify() {
        onChange?(snapshot)
    }
}
