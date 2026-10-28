import AppKit
import CoreImage.CIFilterBuiltins

/// Finestra con il QR della pagina per il telefono e il codice di accoppiamento.
final class QRWindowController: NSWindowController {
    private let pinLabel = NSTextField(labelWithString: "")

    convenience init(url: String, pin: String) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Collega il telefono"
        window.isReleasedWhenClosed = false
        self.init(window: window)
        window.contentView = buildContent(url: url)
        update(pin: pin)
    }

    func update(pin: String) {
        pinLabel.stringValue = pin
    }

    private func buildContent(url: String) -> NSView {
        let intro = NSTextField(wrappingLabelWithString: "1. Inquadra il QR con la fotocamera del telefono.\n2. Inserisci il codice e tocca «Connetti al Mac».\n3. Nell'elenco scegli «\(AppInfo.advertisedName)».")
        intro.font = .systemFont(ofSize: 13)

        let qr = NSImageView(image: Self.qrImage(for: url, side: 240) ?? NSImage())
        qr.imageScaling = .scaleNone

        let link = NSTextField(labelWithString: url)
        link.isSelectable = true
        link.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        link.textColor = .secondaryLabelColor

        let pinTitle = NSTextField(labelWithString: "Codice")
        pinTitle.font = .systemFont(ofSize: 13, weight: .medium)
        pinLabel.font = .monospacedDigitSystemFont(ofSize: 44, weight: .bold)

        let note = NSTextField(wrappingLabelWithString: "Android: Chrome. iPhone: app Bluefy (Safari non supporta il Bluetooth web).")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.alignment = .center

        let stack = NSStackView(views: [intro, qr, link, pinTitle, pinLabel, note])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        stack.setCustomSpacing(4, after: pinTitle)
        return stack
    }

    private static func qrImage(for text: String, side: CGFloat) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scale = (side / output.extent.width).rounded(.down)
        let scaled = output.samplingNearest().transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }
}
