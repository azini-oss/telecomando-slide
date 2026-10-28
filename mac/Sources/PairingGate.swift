import Foundation

/// Controllo del codice di accoppiamento con blocco dopo troppi tentativi sbagliati.
/// È un valore immutabile: ogni verifica restituisce il nuovo stato.
struct PairingGate: Equatable {
    enum Result: Equatable {
        case accepted
        case rejected
        case locked(retryIn: Int)
    }

    let pin: String
    let maxFailures: Int
    let lockout: TimeInterval
    let failures: Int
    let lockedUntil: Date?

    init(pin: String, maxFailures: Int = 5, lockout: TimeInterval = 60, failures: Int = 0, lockedUntil: Date? = nil) {
        self.pin = pin
        self.maxFailures = maxFailures
        self.lockout = lockout
        self.failures = failures
        self.lockedUntil = lockedUntil
    }

    static func isWellFormed(_ pin: String) -> Bool {
        pin.count == 4 && pin.allSatisfy { $0.isASCII && $0.isNumber }
    }

    static func randomPIN() -> String {
        String(format: "%04d", Int.random(in: 0...9_999))
    }

    func verify(_ candidate: String, at now: Date) -> (result: Result, gate: PairingGate) {
        if let lockedUntil, now < lockedUntil {
            let seconds = Int(lockedUntil.timeIntervalSince(now).rounded(.up))
            return (.locked(retryIn: seconds), self)
        }
        if candidate == pin {
            return (.accepted, with(failures: 0, lockedUntil: nil))
        }
        let newFailures = failures + 1
        guard newFailures >= maxFailures else {
            return (.rejected, with(failures: newFailures, lockedUntil: nil))
        }
        return (.locked(retryIn: Int(lockout)), with(failures: 0, lockedUntil: now.addingTimeInterval(lockout)))
    }

    private func with(failures: Int, lockedUntil: Date?) -> PairingGate {
        PairingGate(pin: pin, maxFailures: maxFailures, lockout: lockout, failures: failures, lockedUntil: lockedUntil)
    }
}
