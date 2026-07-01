import Foundation
import ImageIO

enum AttachmentMetadataExtractor {
    static func imageMetadata(for url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }

        var lines = ["content_type: image_metadata"]
        lines.append("pixel_width: \(properties[kCGImagePropertyPixelWidth] ?? "unknown")")
        lines.append("pixel_height: \(properties[kCGImagePropertyPixelHeight] ?? "unknown")")
        lines.append("orientation: \(properties[kCGImagePropertyOrientation] ?? "unknown")")

        if let colorModel = properties[kCGImagePropertyColorModel] {
            lines.append("color_model: \(colorModel)")
        }
        if let depth = properties[kCGImagePropertyDepth] {
            lines.append("bit_depth: \(depth)")
        }
        if let hasAlpha = properties[kCGImagePropertyHasAlpha] {
            lines.append("has_alpha: \(hasAlpha)")
        }
        if let dpiWidth = properties[kCGImagePropertyDPIWidth],
           let dpiHeight = properties[kCGImagePropertyDPIHeight] {
            lines.append("dpi: \(dpiWidth)x\(dpiHeight)")
        }

        return lines.joined(separator: "\n")
    }
}
