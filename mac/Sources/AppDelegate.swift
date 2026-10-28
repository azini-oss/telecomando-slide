import AppKit

/// App da barra dei menu: nessuna finestra fissa, nessun avvio automatico al login.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = Controller(
        bridge: PowerPointBridge(),
        link: BLEPeripheral(advertisedName: AppInfo.advertisedName)
    )
    private var statusItem: NSStatusItem?
    private var qrWindow: QRWindowController?

    private let bluetoothItem = AppDelegate.infoItem()
    private let slideItem = AppDelegate.infoItem()
    private let problemItem = AppDelegate.infoItem()
    private let pinItem = AppDelegate.infoItem()
    private let nameItem = AppDelegate.infoItem("Nome sul telefono: \(AppInfo.advertisedName)")
    private lazy var encryptedItem = actionItem("Collegamento cifrato (abbinamento Bluetooth)", #selector(toggleEncrypted))

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isAlreadyRunning() else {
            NSApp.terminate(nil)
            return
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.menu = buildMenu()
        statusItem = item

        controller.onChange = { [weak self] snapshot in self?.render(snapshot) }
        render(controller.snapshot)
        controller.start()
    }

    // MARK: - Menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(Self.infoItem(AppInfo.displayName, bold: true))
        menu.addItem(.separator())
        [bluetoothItem, slideItem, problemItem].forEach(menu.addItem)
        menu.addItem(.separator())
        menu.addItem(pinItem)
        menu.addItem(nameItem)
        menu.addItem(actionItem("Mostra QR e codice per il telefono…", #selector(showQR)))
        menu.addItem(actionItem("Genera un nuovo codice (scollega i telefoni)", #selector(newPIN)))
        menu.addItem(.separator())
        menu.addItem(encryptedItem)
        menu.addItem(.separator())
        menu.addItem(actionItem("Esci", #selector(quit), key: "q"))
        return menu
    }

    private func render(_ snapshot: StatusSnapshot) {
        let symbol = snapshot.phones > 0 ? "play.rectangle.fill" : "play.rectangle"
        statusItem?.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: AppInfo.displayName)
        bluetoothItem.title = Self.bluetoothText(snapshot)
        slideItem.title = Self.slideText(snapshot.state)
        problemItem.title = snapshot.problem.map { "⚠️ \($0)" } ?? ""
        problemItem.isHidden = snapshot.problem == nil
        pinItem.title = "Codice per il telefono: \(snapshot.pin)"
        encryptedItem.state = snapshot.encrypted ? .on : .off
        qrWindow?.update(pin: snapshot.pin)
    }

    private static func bluetoothText(_ snapshot: StatusSnapshot) -> String {
        switch snapshot.bluetooth {
        case .starting: return "Bluetooth: avvio…"
        case .off: return "Bluetooth spento: accendilo dal Centro di Controllo"
        case .unauthorized: return "Bluetooth non autorizzato: Impostazioni › Privacy › Bluetooth"
        case .unsupported: return "Bluetooth LE non disponibile su questo Mac"
        case .ready:
            switch snapshot.phones {
            case 0: return "In attesa del telefono…"
            case 1: return "Telefono collegato"
            default: return "\(snapshot.phones) telefoni collegati"
            }
        }
    }

    private static func slideText(_ state: PresentationState) -> String {
        guard state.ppt else { return "PowerPoint: chiuso" }
        guard state.count > 0 else { return "PowerPoint: nessuna presentazione aperta" }
        guard state.running else { return "Presentazione pronta (\(state.count) slide), non avviata" }
        return "Slide \(state.slide) di \(state.count)" + (state.black ? " · schermo nero" : "")
    }

    // MARK: - Azioni

    @objc private func showQR() {
        let window = qrWindow ?? QRWindowController(url: AppInfo.phonePageURL, pin: controller.snapshot.pin)
        qrWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.showWindow(nil)
        window.window?.center()
        window.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func newPIN() {
        controller.regeneratePIN()
    }

    @objc private func toggleEncrypted() {
        controller.setEncrypted(!controller.snapshot.encrypted)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Helper

    private static func isAlreadyRunning() -> Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        others.first?.activate()
        return !others.isEmpty
    }

    /// Voce informativa: abilitata (testo ben leggibile) ma senza azione.
    private static func infoItem(_ title: String = "", bold: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        if bold {
            item.attributedTitle = NSAttributedString(
                string: title, attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)]
            )
        }
        return item
    }

    private func actionItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }
}
