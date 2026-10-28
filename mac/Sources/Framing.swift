import Foundation

/// Divide un messaggio in frame da inviare come notifiche Bluetooth.
/// Formato di ogni frame: [id messaggio u8][indice u16 BE][totale u16 BE][dati].
enum Framing {
    static let headerSize = 5

    /// Restituisce nil se il messaggio richiederebbe più di 65535 frame.
    static func frames(for payload: Data, messageID: UInt8, maxFrameSize: Int) -> [Data]? {
        let chunkSize = max(1, maxFrameSize - headerSize)
        let count = max(1, (payload.count + chunkSize - 1) / chunkSize)
        guard count <= Int(UInt16.max) else { return nil }

        let bytes = [UInt8](payload)
        return (0..<count).map { index in
            let start = index * chunkSize
            let end = min(start + chunkSize, bytes.count)
            let header: [UInt8] = [
                messageID,
                UInt8(index >> 8), UInt8(index & 0xFF),
                UInt8(count >> 8), UInt8(count & 0xFF),
            ]
            return Data(header + bytes[start..<end])
        }
    }
}
