import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 描画済み画像の書き出し。
/// EXIF などの撮影情報を保持したまま JPEG / HEIF にエンコードする。
enum ImageExporter {

    static func render(_ image: CIImage, context: CIContext) -> CGImage? {
        let extent = image.extent.integral
        guard extent.width > 0, extent.height > 0 else { return nil }
        return context.createCGImage(image, from: extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    static func exportJPEG(_ cgImage: CGImage, quality: Double, metadata: [String: Any]) -> Data? {
        encode(cgImage, type: UTType.jpeg.identifier, quality: quality, metadata: metadata)
    }

    static func exportHEIF(_ cgImage: CGImage, quality: Double, metadata: [String: Any]) -> Data? {
        encode(cgImage, type: UTType.heic.identifier, quality: quality, metadata: metadata)
    }

    /// 選択フォーマットに応じた書き出し。HEIF が使えない環境では JPEG にフォールバックする。
    static func exportProcessed(_ cgImage: CGImage, format: PhotoFileFormat, metadata: [String: Any]) -> Data? {
        switch format {
        case .jpeg:
            return exportJPEG(cgImage, quality: 0.95, metadata: metadata)
        case .heif, .raw, .proRaw:
            return exportHEIF(cgImage, quality: 0.93, metadata: metadata) ?? exportJPEG(cgImage, quality: 0.95, metadata: metadata)
        }
    }

    /// レビュー表示用に長辺を制限した UIImage を生成する。
    static func reviewImage(_ cgImage: CGImage, maxDimension: CGFloat = 2048) -> CGImage? {
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let longest = max(width, height)
        guard longest > maxDimension else { return cgImage }
        let scale = maxDimension / longest
        let targetWidth = Int(width * scale)
        let targetHeight = Int(height * scale)
        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return cgImage }
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        return context.makeImage()
    }

    // MARK: - Metadata

    /// AVCapturePhoto の metadata をベースに、ルック情報を付与した書き出し用辞書を作る。
    static func metadataDictionary(from base: [String: Any]?, style: RenderStyle, snapshot: CaptureSnapshot, date: Date) -> [String: Any] {
        var metadata = base ?? [:]

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let dateString = formatter.string(from: date)

        var exif = metadata[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        exif[kCGImagePropertyExifDateTimeOriginal as String] = dateString
        exif[kCGImagePropertyExifDateTimeDigitized as String] = dateString
        exif[kCGImagePropertyExifISOSpeedRatings as String] = [Int(snapshot.iso.rounded())]
        exif[kCGImagePropertyExifExposureTime as String] = snapshot.shutterSeconds
        exif[kCGImagePropertyExifUserComment as String] =
            "OniichanCamera / Look: \(style.look.name) (\(Int((style.lookIntensity * 100).rounded()))%)"
        metadata[kCGImagePropertyExifDictionary as String] = exif

        var tiff = metadata[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        tiff[kCGImagePropertyTIFFDateTime as String] = dateString
        tiff[kCGImagePropertyTIFFSoftware as String] = "OniichanCamera"
        metadata[kCGImagePropertyTIFFDictionary as String] = tiff

        return metadata
    }

    // MARK: - Private

    private static func encode(_ cgImage: CGImage, type: String, quality: Double, metadata: [String: Any]) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else { return nil }
        var properties = metadata
        properties[kCGImageDestinationLossyCompressionQuality as String] = quality
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
