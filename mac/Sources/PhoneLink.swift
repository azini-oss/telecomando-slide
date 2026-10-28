import Foundation

enum BluetoothStatus: Equatable {
    case starting
    case ready
    case off
    case unauthorized
    case unsupported
}

/// Canale verso i telefoni (Bluetooth nell'app, finto nei test). I telefoni sono identificati da UUID.
protocol PhoneLink: AnyObject {
    var onStatusChange: ((BluetoothStatus) -> Void)? { get set }
    var onSubscribe: ((UUID) -> Void)? { get set }
    var onDisconnect: ((UUID) -> Void)? { get set }
    var onCommand: ((UUID, String) -> Void)? { get set }

    func start(encrypted: Bool)
    /// Ripubblica il servizio (es. cambio cifratura): i telefoni collegati vengono scollegati.
    func restart(encrypted: Bool)
    /// false se il messaggio è troppo grande per essere inviato.
    @discardableResult
    func send(_ payload: Data, to phone: UUID) -> Bool
}
