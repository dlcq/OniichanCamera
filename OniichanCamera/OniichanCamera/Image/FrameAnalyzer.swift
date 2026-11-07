import CoreGraphics
import Foundation

/// ヒストグラム（RGB + 階調）の集計結果。
struct HistogramData: Equatable {
    static let binCount = 64

    var red: [Int]
    var green: [Int]
    var blue: [Int]
    var luma: [Int]

    /// 0..1。階調の端での飽和（白飛び / 黒つぶれ）の割合
    var clippedHighlightRatio: Double = 0
    var clippedShadowRatio: Double = 0

    static let empty = HistogramData(
        red: Array(repeating: 0, count: binCount),
        green: Array(repeating: 0, count: binCount),
        blue: Array(repeating: 0, count: binCount),
        luma: Array(repeating: 0, count: binCount)
    )

    var maxBin: Int {
        max(red.max() ?? 1, green.max() ?? 1, blue.max() ?? 1, luma.max() ?? 1)
    }
}

/// プレビューフレームからの解析（ヒストグラム・ゼブラ・フォーカスピーキング）。
/// 縮小したラスタを走査するため、実機でも負荷は軽い。
final class FrameAnalyzer {

    struct Result {
        var histogram: HistogramData
        var zebraImage: CGImage?
        var peakImage: CGImage?
    }

    /// 解析用に縮小するサイズ
    private let width = 160
    private let height = 120

    private var rgbaBuffer: [UInt8]
    private var grayBuffer: [Float]
    private var gradientBuffer: [Float]

    /// ゼブラのしきい値（0...1、輝度）
    var zebraThreshold: Double = 0.94
    /// ピーキングのしきい値（0...1、局所コントラスト）
    var peakThreshold: Double = 0.16
    var zebraEnabled = true
    var peakEnabled = true

    init() {
        rgbaBuffer = [UInt8](repeating: 0, count: width * height * 4)
        grayBuffer = [Float](repeating: 0, count: width * height)
        gradientBuffer = [Float](repeating: 0, count: width * height)
    }

    /// CGImage（縮小済みのプレビュー画像）を解析する。
    func analyze(_ cgImage: CGImage) -> Result {
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        let drew = rgbaBuffer.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            guard let context = CGContext(
                data: base,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else { return false }
            context.interpolationQuality = .low
            context.draw(cgImage, in: rect)
            return true
        }
        guard drew else {
            return Result(histogram: .empty, zebraImage: nil, peakImage: nil)
        }

        let pixelCount = width * height
        var redBins = [Int](repeating: 0, count: HistogramData.binCount)
        var greenBins = [Int](repeating: 0, count: HistogramData.binCount)
        var blueBins = [Int](repeating: 0, count: HistogramData.binCount)
        var lumaBins = [Int](repeating: 0, count: HistogramData.binCount)
        var highlightClips = 0
        var shadowClips = 0

        for i in 0..<pixelCount {
            let offset = i * 4
            let r = Float(rgbaBuffer[offset]) / 255.0
            let g = Float(rgbaBuffer[offset + 1]) / 255.0
            let b = Float(rgbaBuffer[offset + 2]) / 255.0
            let l = min(max(0.2126 * r + 0.7152 * g + 0.0722 * b, 0), 1)
            grayBuffer[i] = l

            redBins[min(Int(r * 63.999), 63)] += 1
            greenBins[min(Int(g * 63.999), 63)] += 1
            blueBins[min(Int(b * 63.999), 63)] += 1
            lumaBins[min(Int(l * 63.999), 63)] += 1

            if l >= 0.985 { highlightClips += 1 }
            if l <= 0.015 { shadowClips += 1 }
        }

        var histogram = HistogramData(red: redBins, green: greenBins, blue: blueBins, luma: lumaBins)
        histogram.clippedHighlightRatio = Double(highlightClips) / Double(pixelCount)
        histogram.clippedShadowRatio = Double(shadowClips) / Double(pixelCount)

        return Result(
            histogram: histogram,
            zebraImage: zebraEnabled ? makeZebraMask() : nil,
            peakImage: peakEnabled ? makeFocusPeakMask() : nil
        )
    }

    // MARK: - Zebra

    private func makeZebraMask() -> CGImage? {
        let pixelCount = width * height
        var mask = [UInt8](repeating: 0, count: pixelCount * 4)
        let threshold = Float(zebraThreshold)
        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                guard grayBuffer[index] >= threshold else { continue }
                // 斜め縞
                let stripe = (x + y) % 10 < 5
                let offset = index * 4
                mask[offset] = 255
                mask[offset + 1] = 255
                mask[offset + 2] = 255
                mask[offset + 3] = stripe ? 210 : 0
            }
        }
        return makeImage(from: mask, width: width, height: height)
    }

    // MARK: - Focus peaking

    private func makeFocusPeakMask() -> CGImage? {
        // Sobel に近い勾配抽出
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let i = y * width + x
                let gx = grayBuffer[i + 1] - grayBuffer[i - 1]
                let gy = grayBuffer[i + width] - grayBuffer[i - width]
                gradientBuffer[i] = (gx * gx + gy * gy).squareRoot()
            }
        }
        let threshold = Float(peakThreshold)
        let pixelCount = width * height
        var mask = [UInt8](repeating: 0, count: pixelCount * 4)
        for i in 0..<pixelCount {
            guard gradientBuffer[i] >= threshold else { continue }
            let offset = i * 4
            mask[offset] = 255
            mask[offset + 1] = 64
            mask[offset + 2] = 32
            mask[offset + 3] = 235
        }
        return makeImage(from: mask, width: width, height: height)
    }

    private func makeImage(from buffer: [UInt8], width: Int, height: Int) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }
        buffer.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                context.data?.copyMemory(from: base, byteCount: width * height * 4)
            }
        }
        return context.makeImage()
    }
}
