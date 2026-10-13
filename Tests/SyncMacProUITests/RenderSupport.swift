import AppKit
import SwiftUI
import UniformTypeIdentifiers
import XCTest

/// Rend une vue en image (sans toucher à l'écran) et l'enregistre en PNG pour inspection manuelle.
/// Ignoré (XCTSkip) si l'environnement ne sait pas rendre (runner sans session graphique).
@MainActor
func render<V: View>(_ view: V, name: String, size: CGSize, scheme: ColorScheme) throws -> CGImage {
    let content = view
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, scheme)
    let renderer = ImageRenderer(content: content)
    renderer.scale = 2
    guard let image = renderer.cgImage else {
        throw XCTSkip("ImageRenderer ne produit pas d'image dans cet environnement")
    }
    let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("syncmacpro-renders")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png")
    if let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) {
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
    return image
}

/// L'image doit contenir plusieurs couleurs distinctes : une vue qui n'a rien dessiné est unie.
func assertNotBlank(_ image: CGImage, file: StaticString = #filePath, line: UInt = #line) {
    let side = 64
    var pixels = [UInt8](repeating: 0, count: side * side * 4)
    guard let context = CGContext(
        data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return XCTFail("contexte graphique indisponible", file: file, line: line) }
    context.interpolationQuality = .low
    context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
    var colors = Set<UInt32>()
    for index in stride(from: 0, to: pixels.count, by: 4) {
        let quantized = (UInt32(pixels[index] >> 4) << 8) | (UInt32(pixels[index + 1] >> 4) << 4) | UInt32(pixels[index + 2] >> 4)
        colors.insert(quantized)
    }
    XCTAssertGreaterThanOrEqual(colors.count, 4, "l'image rendue est vide ou unie", file: file, line: line)
}
