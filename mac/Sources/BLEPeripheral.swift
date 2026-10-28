import CoreBluetooth
import os

/// Il Mac si annuncia come periferica Bluetooth LE con un servizio dedicato:
/// - comando (scrittura): testo breve inviato dal telefono
/// - eventi (notifiche): messaggi JSON divisi in frame (vedi Framing)
/// Con `encrypted` le due caratteristiche richiedono il collegamento cifrato (abbinamento di sistema).
/// Usa il main queue, come il resto dell'app.
final class BLEPeripheral: NSObject, PhoneLink, CBPeripheralManagerDelegate {
    static let serviceUUID = CBUUID(string: "e42b5411-b077-4060-b77f-1fdc51501853")
    static let commandUUID = CBUUID(string: "3589d7a0-018d-4575-bcd8-3ad5e6fa1996")
    static let eventUUID = CBUUID(string: "b3646ad2-5c8f-40f3-8905-5a5a9842889d")
    /// Oltre questo numero di frame un messaggio non si invia (e il telefono lo rifiuterebbe).
    static let maxFramesPerMessage = 4_096
    /// Coda massima per telefono: oltre, il telefono è troppo lento e la sua coda si svuota.
    static let maxQueuedFrames = 8_192

    var onStatusChange: ((BluetoothStatus) -> Void)?
    var onSubscribe: ((UUID) -> Void)?
    var onDisconnect: ((UUID) -> Void)?
    var onCommand: ((UUID, String) -> Void)?

    private let log = Logger(subsystem: AppInfo.subsystem, category: "bluetooth")
    private let advertisedName: String
    private var encrypted = false
    private var manager: CBPeripheralManager?
    private var eventCharacteristic: CBMutableCharacteristic?
    private var subscribers: [UUID: CBCentral] = [:]
    /// Due code per telefono: `urgent` (stato, note, comandi) passa sempre prima di `bulk` (miniature).
    private var urgent: [UUID: [Data]] = [:]
    private var bulk: [UUID: [Data]] = [:]
    /// ID dei messaggi in due spazi separati (0–127 urgenti, 128–255 miniature): un messaggio urgente
    /// che si intercala a una miniatura non ne riusa mai l'ID.
    private var urgentCounter: UInt8 = 0
    private var bulkCounter: UInt8 = 0

    init(advertisedName: String) {
        self.advertisedName = advertisedName
    }

    func start(encrypted: Bool) {
        self.encrypted = encrypted
        guard manager == nil else { return }
        manager = CBPeripheralManager(delegate: self, queue: nil)
    }

    func restart(encrypted: Bool) {
        self.encrypted = encrypted
        dropAllSubscribers()
        guard let manager, manager.state == .poweredOn else { return }
        manager.stopAdvertising()
        publishService(on: manager)
    }

    @discardableResult
    func send(_ payload: Data, to phone: UUID, bulk isBulk: Bool) -> Bool {
        guard subscribers[phone] != nil else { return true }
        let messageID: UInt8
        if isBulk {
            bulkCounter = (bulkCounter &+ 1) & 0x7F
            messageID = 0x80 | bulkCounter
        } else {
            urgentCounter = (urgentCounter &+ 1) & 0x7F
            messageID = urgentCounter
        }
        guard let frames = Framing.frames(for: payload, messageID: messageID,
                                          maxFrameSize: subscribers[phone]?.maximumUpdateValueLength ?? 20),
              frames.count <= Self.maxFramesPerMessage else {
            log.error("Messaggio troppo grande, non inviato (\(payload.count) byte)")
            return false
        }
        let queue = ((isBulk ? bulk[phone] : urgent[phone]) ?? []) + frames
        guard queue.count <= Self.maxQueuedFrames else {
            log.error("Telefono troppo lento: coda svuotata")
            if isBulk { bulk[phone] = [] } else { urgent[phone] = [] }
            return true
        }
        if isBulk { bulk[phone] = queue } else { urgent[phone] = queue }
        flush()
        return true
    }

    /// Invia a turno un frame per telefono (un telefono lento non blocca gli altri),
    /// sempre prima i frame urgenti e poi quelli delle miniature.
    private func flush() {
        guard let manager, let characteristic = eventCharacteristic else { return }
        var progressed = true
        while progressed {
            progressed = false
            for phone in Set(urgent.keys).union(bulk.keys) {
                guard let central = subscribers[phone] else {
                    urgent[phone] = nil
                    bulk[phone] = nil
                    continue
                }
                let fromUrgent = !(urgent[phone] ?? []).isEmpty
                guard let frame = fromUrgent ? urgent[phone]?.first : bulk[phone]?.first else { continue }
                // false = coda di sistema piena: si riprende in peripheralManagerIsReady.
                guard manager.updateValue(frame, for: characteristic, onSubscribedCentrals: [central]) else { return }
                if fromUrgent {
                    urgent[phone] = Array(urgent[phone]?.dropFirst() ?? [])
                } else {
                    bulk[phone] = Array(bulk[phone]?.dropFirst() ?? [])
                }
                progressed = true
            }
        }
    }

    private func publishService(on manager: CBPeripheralManager) {
        let commandPermissions: CBAttributePermissions = encrypted ? [.writeEncryptionRequired] : [.writeable]
        let eventProperties: CBCharacteristicProperties = encrypted ? [.notify, .notifyEncryptionRequired] : [.notify]
        let command = CBMutableCharacteristic(type: Self.commandUUID, properties: [.write], value: nil, permissions: commandPermissions)
        let event = CBMutableCharacteristic(type: Self.eventUUID, properties: eventProperties, value: nil, permissions: [])
        let service = CBMutableService(type: Self.serviceUUID, primary: true)
        service.characteristics = [command, event]
        eventCharacteristic = event
        manager.removeAllServices()
        manager.add(service)
    }

    private func dropAllSubscribers() {
        let phones = Array(subscribers.keys)
        subscribers = [:]
        urgent = [:]
        bulk = [:]
        phones.forEach { onDisconnect?($0) }
    }

    // MARK: - CBPeripheralManagerDelegate

    func peripheralManagerDidUpdateState(_ manager: CBPeripheralManager) {
        let status: BluetoothStatus
        switch manager.state {
        case .poweredOn: status = .ready
        case .poweredOff: status = .off
        case .unauthorized: status = .unauthorized
        case .unsupported: status = .unsupported
        default: status = .starting
        }
        log.notice("Stato Bluetooth: \(String(describing: status), privacy: .public)")
        if status == .ready {
            publishService(on: manager)
        } else {
            dropAllSubscribers()
        }
        onStatusChange?(status)
    }

    func peripheralManager(_ manager: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error {
            log.error("Servizio non pubblicato: \(error.localizedDescription, privacy: .public)")
            return
        }
        manager.startAdvertising([
            CBAdvertisementDataLocalNameKey: advertisedName,
            CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID],
        ])
    }

    func peripheralManagerDidStartAdvertising(_ manager: CBPeripheralManager, error: Error?) {
        if let error {
            log.error("Annuncio Bluetooth fallito: \(error.localizedDescription, privacy: .public)")
        } else {
            log.notice("Annuncio Bluetooth avviato come \(self.advertisedName, privacy: .public)")
        }
    }

    func peripheralManager(_ manager: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        subscribers[central.identifier] = central
        log.notice("Telefono collegato")
        onSubscribe?(central.identifier)
    }

    func peripheralManager(_ manager: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        subscribers[central.identifier] = nil
        urgent[central.identifier] = nil
        bulk[central.identifier] = nil
        log.notice("Telefono scollegato")
        onDisconnect?(central.identifier)
    }

    func peripheralManagerIsReady(toUpdateSubscribers manager: CBPeripheralManager) {
        flush()
    }

    func peripheralManager(_ manager: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        guard let first = requests.first else { return }
        let valid = requests.allSatisfy { request in
            request.characteristic.uuid == Self.commandUUID && request.offset == 0
                && (request.value?.count ?? 0) <= Command.maxLength
        }
        guard valid else {
            manager.respond(to: first, withResult: .invalidAttributeValueLength)
            return
        }
        manager.respond(to: first, withResult: .success)
        for request in requests {
            guard let value = request.value, let text = String(data: value, encoding: .utf8) else { continue }
            onCommand?(request.central.identifier, text)
        }
    }
}
