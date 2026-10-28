import Foundation

enum AppInfo {
    static let subsystem = "com.azini.telecomandoslide"
    static let displayName = "Telecomando Slide"
    /// Pagina da aprire sul telefono (Chrome su Android, Bluefy su iPhone).
    static let phonePageURL = "https://azini-oss.github.io/telecomando-slide/"

    /// PDF temporaneo per le miniature: PowerPoint è in sandbox e può scrivere solo nel suo contenitore.
    static let thumbnailPDFURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Containers/com.microsoft.Powerpoint/Data/telecomando-slide-miniature.pdf")

    /// Nome annunciato via Bluetooth con un codice breve di questo Mac, per distinguerlo da altri Mac vicini.
    static let advertisedName = "\(displayName) \(deviceTag)"

    private static let deviceTag: String = {
        let key = "deviceTag"
        if let saved = UserDefaults.standard.string(forKey: key), saved.count == 4 { return saved }
        let tag = String(format: "%04X", Int.random(in: 0...0xFFFF))
        UserDefaults.standard.set(tag, forKey: key)
        return tag
    }()
}
