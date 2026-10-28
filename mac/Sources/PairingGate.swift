import Foundation

/// Controllo del codice di accoppiamento. Dopo `maxFailures` errori blocca, con attesa che raddoppia
/// a ogni blocco (60 s, 120 s, … fino a un'ora). È un valore immutabile: ogni verifica restituisce il nuovo stato.
struct PairingGate: Equatable {
    enum Result: Equatable {
        case accepted
        case rejected
        case locked(retryIn: Int)
    }

    let pin: String
    let maxFailures: Int
    let lockout: TimeInterval
    let maxLockout: TimeInterval
    let failures: Int
    let lockouts: Int
    /// Errori dall'ultimo codice giusto: oltre una soglia l'app genera un codice nuovo.
    let totalFailures: Int
    let lockedUntil: Date?

    init(
        pin: String, maxFailures: Int = 5, lockout: TimeInterval = 60, maxLockout: TimeInterval = 3_600,
        failures: Int = 0, lockouts: Int = 0, totalFailures: Int = 0, lockedUntil: Date? = nil
    ) {
        self.pin = pin
        self.maxFailures = maxFailures
        self.lockout = lockout
        self.maxLockout = maxLockout
        self.failures = failures
        self.lockouts = lockouts
        self.totalFailures = totalFailures
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
            return (.accepted, PairingGate(pin: pin, maxFailures: maxFailures, lockout: lockout, maxLockout: maxLockout))
        }
        let newFailures = failures + 1
        guard newFailures >= maxFailures else {
            return (.rejected, with(failures: newFailures, lockouts: lockouts, lockedUntil: nil))
        }
        let duration = min(maxLockout, lockout * pow(2, Double(lockouts)))
        let locked = with(failures: 0, lockouts: lockouts + 1, lockedUntil: now.addingTimeInterval(duration))
        return (.locked(retryIn: Int(duration)), locked)
    }

    private func with(failures: Int, lockouts: Int, lockedUntil: Date?) -> PairingGate {
        PairingGate(
            pin: pin, maxFailures: maxFailures, lockout: lockout, maxLockout: maxLockout,
            failures: failures, lockouts: lockouts, totalFailures: totalFailures + 1, lockedUntil: lockedUntil
        )
    }
}

/// Token di riconnessione consegnati ai telefoni dopo il codice giusto (128 bit, impossibili da indovinare).
/// Permettono di ricollegarsi senza codice e senza risentire del blocco anti-tentativi.
struct TokenStore: Equatable {
    static let maxTokens = 5

    let tokens: [String]

    static func isWellFormed(_ token: String) -> Bool {
        token.count == 32 && token.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    static func randomToken() -> String {
        (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    func contains(_ token: String) -> Bool {
        tokens.contains(token)
    }

    func issuing(_ token: String) -> TokenStore {
        TokenStore(tokens: Array((tokens.filter { $0 != token } + [token]).suffix(Self.maxTokens)))
    }
}
