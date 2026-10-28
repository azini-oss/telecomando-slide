import CoreBluetooth
import os

enum BluetoothStatus: Equatable {
    case starting
    case ready
    case off
    case unauthorized
    case unsupported
}

/// Il Mac si annuncia come periferica Bluetooth LE con un servizio dedicato:
/// - comando (scrittura): testo breve inviato dal telefono
/// - eventi (notifiche): messaggi JSON divisi in frame (vedi Framing)
/// Usa il main queue, come il resto dell'app.
final class BLEPeripheral: NSObject, CBPeripheralManagerDelegate {
    static let serviceUUID = CBUUID(string: "e42b5411-b077-4060-b77f-1fdc51501853")
    static let commandUUID = CBUUID(string: "3589d7a0-018d-4575-bcd8-3ad5e6fa1996")
    static let eventUUID = CBUUID(string: "b3646ad2-5c8f-40f3-8905-5a5a9842889d")

    var onStatusChange: ((BluetoothStatus) -> Void)?
    var onCommand: ((CBCentral, String) -> Void)?
    var onDisconnect: ((CBCentral) -> Void)?

    private let log = Logger(subsystem: AppInfo.subsystem, category: "bluetooth")
    private var manager: CBPeripheralManager?
    private var subscribers: [UUID: CBCentral] = [:]
    private var outbox: [(central: CBCentral, frame: Data)] = []
    private var messageCounter: UInt8 = 0

    private let commandCharacteristic = CBMutableCharacteristic(
        type: BLEPeripheral.commandUUID, properties: [.write], value: nil, permissions: [.writeable]
    )
    private let eventCharacteristic = CBMutableCharacteristic(
        type: BLEPeripheral.eventUUID, properties: [.notify], value: nil, permissions: []
    )

    func start() {
        guard manager == nil else { return }
        manager = CBPeripheralManager(delegate: self, queue: nil)
    }

    func send(_ payload: Data, to central: CBCentral) {
        guard subscribers[central.identifier] != nil else { return }
        messageCounter &+= 1
        guard let frames = Framing.frames(for: payload, messageID: messageCounter, maxFrameSize: central.maximumUpdateValueLength) else {
            log.error("Messaggio troppo grande, non inviato (\(payload.count) byte)")
            return
        }
        outbox.append(contentsOf: frames.map { (central: central, frame: $0) })
        flush()
    }

    private func flush() {
        guard let manager else { return }
        while let next = outbox.first {
            guard subscribers[next.central.identifier] != nil else {
                outbox.removeFirst()
                continue
            }
            // false = coda di invio piena: si riprende in peripheralManagerIsReady.
            guard manager.updateValue(next.frame, for: eventCharacteristic, onSubscribedCentrals: [next.central]) else { return }
            outbox.removeFirst()
        }
    }

    private func publishService(on manager: CBPeripheralManager) {
        let service = CBMutableService(type: Self.serviceUUID, primary: true)
        service.characteristics = [commandCharacteristic, eventCharacteristic]
        manager.removeAllServices()
        manager.add(service)
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
        log.info("Stato Bluetooth: \(String(describing: status), privacy: .public)")
        if status == .ready {
            publishService(on: manager)
        } else {
            subscribers.values.forEach { onDisconnect?($0) }
            subscribers = [:]
            outbox = []
        }
        onStatusChange?(status)
    }

    func peripheralManager(_ manager: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error {
            log.error("Servizio non pubblicato: \(error.localizedDescription, privacy: .public)")
            return
        }
        manager.startAdvertising([
            CBAdvertisementDataLocalNameKey: AppInfo.displayName,
            CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID],
        ])
    }

    func peripheralManagerDidStartAdvertising(_ manager: CBPeripheralManager, error: Error?) {
        if let error {
            log.error("Annuncio Bluetooth fallito: \(error.localizedDescription, privacy: .public)")
        } else {
            log.info("Annuncio Bluetooth avviato")
        }
    }

    func peripheralManager(_ manager: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        subscribers[central.identifier] = central
        log.info("Telefono collegato")
    }

    func peripheralManager(_ manager: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        subscribers[central.identifier] = nil
        outbox.removeAll { $0.central.identifier == central.identifier }
        log.info("Telefono scollegato")
        onDisconnect?(central)
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
            onCommand?(request.central, text)
        }
    }
}
