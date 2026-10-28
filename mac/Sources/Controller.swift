import CoreBluetooth
import os

/// Quello che il menu mostra all'utente.
struct StatusSnapshot: Equatable {
    let bluetooth: BluetoothStatus
    let phones: Int
    let state: PresentationState
    let problem: String?
    let pin: String
}

/// Collega telefono (Bluetooth) e PowerPoint: autentica, esegue i comandi, invia stato e note.
final class Controller {
    private enum Keys {
        static let pin = "pairingPIN"
    }

    static let pollInterval: TimeInterval = 0.5
    static let heartbeatInterval: TimeInterval = 10
    static let errorPause: TimeInterval = 3

    var onChange: ((StatusSnapshot) -> Void)?

    private let log = Logger(subsystem: AppInfo.subsystem, category: "controller")
    private let defaults: UserDefaults
    private let bridge = PowerPointBridge()
    private let ble = BLEPeripheral()

    private var gate: PairingGate
    private var trusted: [UUID: CBCentral] = [:]
    private var bluetooth = BluetoothStatus.starting
    private var lastState = PresentationState.closed
    private var deck: Deck?
    private var deckAttemptKey: String?
    private var problem: String?
    private var pollTimer: Timer?
    private var pausedUntil: Date?
    private var lastHeartbeat = Date.distantPast

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.string(forKey: Keys.pin).flatMap { PairingGate.isWellFormed($0) ? $0 : nil }
        let pin = saved ?? PairingGate.randomPIN()
        defaults.set(pin, forKey: Keys.pin)
        gate = PairingGate(pin: pin)
    }

    var snapshot: StatusSnapshot {
        StatusSnapshot(bluetooth: bluetooth, phones: trusted.count, state: lastState, problem: problem, pin: gate.pin)
    }

    func start() {
        ble.onStatusChange = { [weak self] status in
            self?.bluetooth = status
            self?.notify()
        }
        ble.onCommand = { [weak self] central, text in self?.handle(text, from: central) }
        ble.onDisconnect = { [weak self] central in self?.forget(central) }
        ble.start()
    }

    /// Nuovo codice: i telefoni già collegati devono reinserirlo.
    func regeneratePIN() {
        let pin = PairingGate.randomPIN()
        defaults.set(pin, forKey: Keys.pin)
        gate = PairingGate(pin: pin)
        trusted.values.forEach { send(AuthMessage(ok: false, retryIn: nil), to: $0) }
        trusted = [:]
        stopPolling()
        notify()
    }

    // MARK: - Comandi dal telefono

    private func handle(_ text: String, from central: CBCentral) {
        guard let command = Command(text: text) else {
            send(ErrorMessage(msg: "Comando non valido"), to: central)
            return
        }
        if case .hello(let pin) = command {
            authenticate(pin, central: central)
            return
        }
        guard trusted[central.identifier] != nil else {
            send(AuthMessage(ok: false, retryIn: nil), to: central)
            return
        }
        if command == .reload {
            deck = nil
            deckAttemptKey = nil
        }
        if case .failure(let error) = bridge.perform(command) {
            report(error)
        }
        refresh(force: true)
    }

    private func authenticate(_ pin: String, central: CBCentral) {
        let (result, newGate) = gate.verify(pin, at: Date())
        gate = newGate
        switch result {
        case .accepted:
            trusted[central.identifier] = central
            send(AuthMessage(ok: true, retryIn: nil), to: central)
            if let deck { send(DeckMessage(deck), to: central) }
            startPolling()
            refresh(force: true)
        case .rejected:
            log.notice("Codice errato da un telefono")
            send(AuthMessage(ok: false, retryIn: nil), to: central)
        case .locked(let seconds):
            log.notice("Troppi codici errati: blocco per \(seconds) s")
            send(AuthMessage(ok: false, retryIn: seconds), to: central)
        }
        notify()
    }

    private func forget(_ central: CBCentral) {
        guard trusted.removeValue(forKey: central.identifier) != nil else { return }
        if trusted.isEmpty { stopPolling() }
        notify()
    }

    // MARK: - Lettura periodica di PowerPoint

    private func startPolling() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.refresh(force: false)
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func refresh(force: Bool) {
        guard !trusted.isEmpty else { return }
        if !force, let pausedUntil, Date() < pausedUntil { return }

        switch bridge.readState() {
        case .success(let state):
            pausedUntil = nil
            if problem != nil, state.ppt {
                problem = nil
            }
            if state.key != deckAttemptKey {
                loadDeck(for: state)
            }
            let changed = state.differs(from: lastState)
            let heartbeatDue = Date().timeIntervalSince(lastHeartbeat) > Self.heartbeatInterval
            lastState = state
            if changed || force || heartbeatDue {
                broadcast(StateMessage(state))
                lastHeartbeat = Date()
            }
            if changed { notify() }
        case .failure(let error):
            pausedUntil = Date().addingTimeInterval(Self.errorPause)
            report(error)
        }
    }

    private func loadDeck(for state: PresentationState) {
        deckAttemptKey = state.key
        guard state.ppt, !state.key.isEmpty else {
            let empty = Deck(key: "", name: "", slides: [])
            deck = empty
            broadcast(DeckMessage(empty))
            return
        }
        switch bridge.readDeck() {
        case .success(let loaded):
            deck = loaded
            deckAttemptKey = loaded.key
            broadcast(DeckMessage(loaded))
        case .failure(let error):
            report(error)
        }
    }

    private func report(_ error: BridgeError) {
        let message = error.userMessage
        guard message != problem else { return }
        problem = message
        broadcast(ErrorMessage(msg: message))
        notify()
    }

    // MARK: - Invio

    private func broadcast<T: Encodable>(_ message: T) {
        trusted.values.forEach { send(message, to: $0) }
    }

    private func send<T: Encodable>(_ message: T, to central: CBCentral) {
        guard let data = MessageEncoder.encode(message) else { return }
        ble.send(data, to: central)
    }

    private func notify() {
        onChange?(snapshot)
    }
}
