// Disegna le icone (app Mac + pagina telefono) da codice, senza file scaricati.
// Uso: swiftc tools/make_icons.swift -o build/make_icons && build/make_icons <cartella progetto>
import AppKit

enum Shape {
    case macSquircle      // icona macOS: forma arrotondata con margine trasparente
    case roundedTransparent // icona PWA "any": angoli trasparenti
    case fullBleed(padding: CGFloat) // maskable / apple-touch: quadrato pieno
}

func render(size: Int, shape: Shape) -> Data {
    let side = CGFloat(size)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let (rect, radius, symbolScale): (NSRect, CGFloat, CGFloat) = {
        switch shape {
        case .macSquircle:
            let inset = side * 0.1
            let r = NSRect(x: inset, y: inset, width: side - 2 * inset, height: side - 2 * inset)
            return (r, r.width * 0.225, 0.5)
        case .roundedTransparent:
            return (NSRect(x: 0, y: 0, width: side, height: side), side * 0.225, 0.56)
        case .fullBleed(let padding):
            return (NSRect(x: 0, y: 0, width: side, height: side), 0, 0.56 * (1 - padding))
        }
    }()

    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    let gradient = NSGradient(
        starting: NSColor(srgbRed: 0.42, green: 0.40, blue: 0.98, alpha: 1),
        ending: NSColor(srgbRed: 0.20, green: 0.16, blue: 0.62, alpha: 1)
    )!
    gradient.draw(in: path, angle: -90)

    let pointSize = rect.width * symbolScale
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
    if let symbol = NSImage(systemSymbolName: "play.rectangle.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        // Simbolo monocromatico colorato di bianco: il triangolo "play" resta trasparente.
        let white = NSImage(size: symbol.size, flipped: false) { bounds in
            symbol.draw(in: bounds)
            NSColor.white.set()
            bounds.fill(using: .sourceAtop)
            return true
        }
        let s = white.size
        let origin = NSPoint(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2)
        white.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let fm = FileManager.default
func write(_ data: Data, _ relative: String) {
    let url = root.appendingPathComponent(relative)
    try! fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! data.write(to: url)
}

// Pagina telefono
write(render(size: 192, shape: .roundedTransparent), "web/icons/icon-192.png")
write(render(size: 512, shape: .roundedTransparent), "web/icons/icon-512.png")
write(render(size: 512, shape: .fullBleed(padding: 0.2)), "web/icons/icon-maskable-512.png")
write(render(size: 180, shape: .fullBleed(padding: 0)), "web/icons/apple-touch-icon.png")

// App Mac: iconset da convertire con iconutil
let iconset = "mac/build/AppIcon.iconset"
for base in [16, 32, 128, 256, 512] {
    write(render(size: base, shape: .macSquircle), "\(iconset)/icon_\(base)x\(base).png")
    write(render(size: base * 2, shape: .macSquircle), "\(iconset)/icon_\(base)x\(base)@2x.png")
}
print("Icone generate")
