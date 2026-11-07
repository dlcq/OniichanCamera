import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// レンダリングスタイル。プレビューと保存画像の双方に同一の内容が渡される。
struct RenderStyle: Equatable {
    var look: LookRecipe
    var lookIntensity: Double
    var adjustments: ImageAdjustments
    var lut: CubeLUT?

    static func == (lhs: RenderStyle, rhs: RenderStyle) -> Bool {
        lhs.look.id == rhs.look.id
            && lhs.lookIntensity == rhs.lookIntensity
            && lhs.adjustments == rhs.adjustments
            && lhs.lut == rhs.lut
    }
}

/// 映像処理パイプライン。
///
/// プレビュー（AVCaptureVideoDataOutput のフレーム）と保存画像（AVCapturePhoto のデータ）の
/// 両方をここで処理するため、プレビューと写真の色味が一致する。
///
/// 処理順：
///  1. 色温度 / ティント（ホワイトバランス調整）
///  2. 露出（EV）
///  3. トーンカーブ（ハイライト・シャドウ・コントラスト・フェード）
///  4. ルック 3D LUT（強度ブレンド済み）
///  5. 彩度 / 自然な彩度 / 色相の調整 LUT
///  6. カスタム LUT（任意）
///  7. 明瞭度（アンシャープマスク）/ シャープネス
///  8. 粒子感（ソフトライト合成）
///  9. 周辺光量
final class ColorPipeline {

    static let shared = ColorPipeline()

    let context: CIContext

    private let cubeCache = NSCache<NSString, NSData>()
    private let cacheQueue = DispatchQueue(label: "jp.oniichan.camera.cubebuild", qos: .userInitiated)

    init(context: CIContext? = nil) {
        if let context {
            self.context = context
        } else {
            self.context = CIContext(options: [
                .cacheIntermediates: false,
                .highQualityDownsample: true,
            ])
        }
        cubeCache.countLimit = 24
    }

    // MARK: - Pipeline

    /// 極端に大きな画像（例：48MP のハイレゾ撮影）は、GPU メモリを圧迫しないよう
    /// 32MP 相当まで縮小してから処理する。通常解像度（〜24MP）はそのまま処理される。
    static func prepareForProcessing(_ image: CIImage, maxPixels: Double = 32_000_000) -> CIImage {
        let extent = image.extent
        let pixels = Double(extent.width * extent.height)
        guard pixels > maxPixels else { return image }
        let scale = (maxPixels / pixels).squareRoot()
        guard let filter = CIFilter(name: "CILanczosScaleTransform") else {
            return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(scale, forKey: kCIInputScaleKey)
        filter.setValue(1.0, forKey: kCIInputAspectRatioKey)
        return filter.outputImage ?? image
    }

    /// `input` にスタイルを適用した画像を返す。
    /// `resolutionScale` はエフェクト半径の調整用（プレビューは縮小して処理するため 1.0 未満になる）。
    func outputImage(from input: CIImage, style: RenderStyle, resolutionScale: Double = 1.0) -> CIImage {
        var image = input
        let adjustments = style.adjustments
        let scale = max(0.05, resolutionScale)

        // 1. ホワイトバランス（色温度 / ティント）
        if abs(adjustments.temperature) > 0.001 || abs(adjustments.tint) > 0.001 {
            let neutralTemperature = 6500.0 + adjustments.temperature * 2500.0
            let neutralTint = adjustments.tint * 120.0
            if let filter = CIFilter(name: "CITemperatureAndTint") {
                filter.setValue(image, forKey: kCIInputImageKey)
                filter.setValue(CIVector(x: neutralTemperature, y: neutralTint), forKey: "inputNeutral")
                filter.setValue(CIVector(x: 6500, y: 0), forKey: "targetNeutral")
                if let output = filter.outputImage { image = output }
            }
        }

        // 2. 露出
        if abs(adjustments.exposure) > 0.001 {
            if let filter = CIFilter(name: "CIExposureAdjust") {
                filter.setValue(image, forKey: kCIInputImageKey)
                filter.setValue(adjustments.exposure, forKey: kCIInputEVKey)
                if let output = filter.outputImage { image = output }
            }
        }

        // 3. トーンカーブ
        if adjustments.contrast != 0 || adjustments.highlights != 0 || adjustments.shadows != 0 || adjustments.fade != 0 {
            if let filter = CIFilter(name: "CIToneCurve") {
                filter.setValue(image, forKey: kCIInputImageKey)
                let points = toneCurvePoints(for: adjustments)
                for (index, point) in points.enumerated() {
                    filter.setValue(CIVector(x: point.x, y: point.y), forKey: "inputPoint\(index)")
                }
                if let output = filter.outputImage { image = output }
            }
        }

        // 4. ルック LUT
        if style.lookIntensity > 0.001 {
            let key = lookCacheKey(style)
            let cubeData = cachedCube(forKey: key) {
                ColorCubeBuilder.lookCube(recipe: style.look, intensity: style.lookIntensity, dimension: 32)
            }
            image = applyCube(image: image, dimension: 32, data: cubeData)
        }

        // 5. 彩度 / 自然な彩度 / 色相
        if abs(adjustments.saturation) > 0.001 || abs(adjustments.vibrance) > 0.001 || abs(adjustments.hue) > 0.001 {
            let key = adjustCacheKey(adjustments)
            let cubeData = cachedCube(forKey: key) {
                ColorCubeBuilder.adjustCube(
                    saturation: adjustments.saturation,
                    vibrance: adjustments.vibrance,
                    hueDegrees: adjustments.hue * 30.0
                )
            }
            image = applyCube(image: image, dimension: 16, data: cubeData)
        }

        // 6. カスタム LUT
        if let lut = style.lut {
            image = applyCube(image: image, dimension: lut.dimension, data: lut.data, useColorSpace: true)
        }

        // 7. 明瞭度 / シャープネス
        if adjustments.clarity > 0.001 {
            if let filter = CIFilter(name: "CIUnsharpMask") {
                filter.setValue(image, forKey: kCIInputImageKey)
                filter.setValue(22.0 * scale, forKey: kCIInputRadiusKey)
                filter.setValue(adjustments.clarity * 0.55, forKey: kCIInputIntensityKey)
                if let output = filter.outputImage { image = output }
            }
        }
        if adjustments.sharpness > 0.001 || style.look.sharpness > 0.001 {
            let amount = max(adjustments.sharpness, style.lookIntensity > 0.001 ? style.look.sharpness * style.lookIntensity : 0)
            if let filter = CIFilter(name: "CISharpenLuminance") {
                filter.setValue(image, forKey: kCIInputImageKey)
                filter.setValue(amount * 0.8, forKey: kCIInputSharpnessKey)
                if let output = filter.outputImage { image = output }
            }
        }

        // 8. 粒子感
        let grainAmount = max(adjustments.grain, style.lookIntensity > 0.001 ? style.look.grain * style.lookIntensity : 0)
        if grainAmount > 0.001 {
            image = applyGrain(to: image, amount: grainAmount, scale: scale)
        }

        // 9. 周辺光量
        let vignetteAmount = max(adjustments.vignette, style.lookIntensity > 0.001 ? style.look.vignette * style.lookIntensity : 0)
        if vignetteAmount > 0.001 {
            if let filter = CIFilter(name: "CIVignetteEffect") {
                filter.setValue(image, forKey: kCIInputImageKey)
                filter.setValue(vignetteAmount * 1.2, forKey: "inputIntensity")
                filter.setValue(0.75, forKey: kCIInputRadiusKey)
                if let output = filter.outputImage { image = output }
            }
        }

        return image.cropped(to: input.extent)
    }

    // MARK: - Tone curve

    /// ハイライト / シャドウ / コントラスト / フェードから 5 点のトーンカーブを構築する。
    static func toneCurvePoints(for a: ImageAdjustments) -> [CGPoint] {
        let fade = a.fade * 0.12
        let blackPoint = fade
        let whitePoint = 1.0 - max(0, -a.highlights) * 0.06

        let shadowShift = a.shadows * 0.16
        let highlightShift = a.highlights * 0.14

        var p0 = blackPoint
        var p1 = 0.25 + shadowShift * 0.85 - a.contrast * 0.045 + fade * 0.5
        var p2 = 0.5 + shadowShift * 0.25 + highlightShift * 0.25 + fade * 0.35
        var p3 = 0.75 + highlightShift * 0.85 + a.contrast * 0.045 + fade * 0.2
        var p4 = whitePoint

        // 単調性を保証する
        p0 = clampUnit(p0)
        p1 = clampUnit(max(p1, p0 + 0.02))
        p2 = clampUnit(max(p2, p1 + 0.02))
        p3 = clampUnit(max(p3, p2 + 0.02))
        p4 = clampUnit(max(p4, p3 + 0.02))

        return [
            CGPoint(x: 0, y: p0),
            CGPoint(x: 0.25, y: p1),
            CGPoint(x: 0.5, y: p2),
            CGPoint(x: 0.75, y: p3),
            CGPoint(x: 1, y: p4),
        ]
    }

    private func clampUnit(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    // MARK: - Grain

    private func applyGrain(to image: CIImage, amount: Double, scale: Double) -> CIImage {
        let extent = image.extent
        guard let random = CIFilter(name: "CIRandomGenerator").flatMap({ $0.outputImage }) else { return image }

        // ノイズを適度な粒径にし、単色化する
        let noiseScale = max(0.35, min(1.6, scale))
        let scaled = random.transformed(by: CGAffineTransform(scaleX: noiseScale, y: noiseScale))
            .cropped(to: extent)
        guard let mono = CIFilter(name: "CIColorMatrix") else { return image }
        mono.setValue(scaled, forKey: kCIInputImageKey)
        mono.setValue(CIVector(x: 0.34, y: 0.5, z: 0.16, w: 0), forKey: "inputRVector")
        mono.setValue(CIVector(x: 0.34, y: 0.5, z: 0.16, w: 0), forKey: "inputGVector")
        mono.setValue(CIVector(x: 0.34, y: 0.5, z: 0.16, w: 0), forKey: "inputBVector")
        mono.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
        mono.setValue(CIVector(x: 0.5, y: 0.5, z: 0.5, w: 0), forKey: "inputBiasVector")
        guard let noise = mono.outputImage else { return image }

        guard let blend = CIFilter(name: "CISoftLightBlendMode") else { return image }
        blend.setValue(image, forKey: kCIInputImageKey)
        blend.setValue(noise, forKey: kCIInputBackgroundImageKey)
        guard let blended = blend.outputImage else { return image }

        guard let dissolve = CIFilter(name: "CIDissolveTransition") else { return image }
        dissolve.setValue(image, forKey: kCIInputImageKey)
        dissolve.setValue(blended, forKey: kCIInputTargetImageKey)
        dissolve.setValue(min(amount * 1.4, 1.0), forKey: kCIInputTimeKey)
        return dissolve.outputImage ?? image
    }

    // MARK: - Cubes

    private func applyCube(image: CIImage, dimension: Int, data: Data, useColorSpace: Bool = true) -> CIImage {
        guard let filter = CIFilter(name: "CIColorCubeWithColorSpace") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(dimension, forKey: "inputCubeDimension")
        filter.setValue(data, forKey: "inputCubeData")
        if useColorSpace {
            filter.setValue(CGColorSpace(name: CGColorSpace.sRGB), forKey: "inputColorSpace")
        }
        return filter.outputImage ?? image
    }

    private func cachedCube(forKey key: String, builder: () -> Data) -> Data {
        let nsKey = key as NSString
        if let cached = cubeCache.object(forKey: nsKey) {
            return cached as Data
        }
        let data = builder()
        cubeCache.setObject(data as NSData, forKey: nsKey)
        return data
    }

    private func lookCacheKey(_ style: RenderStyle) -> String {
        String(format: "look|%@|%.2f|%d", style.look.id, style.lookIntensity, style.lut == nil ? 0 : 1)
    }

    private func adjustCacheKey(_ a: ImageAdjustments) -> String {
        String(format: "adj|%.2f|%.2f|%.2f", a.saturation, a.vibrance, a.hue)
    }
}
