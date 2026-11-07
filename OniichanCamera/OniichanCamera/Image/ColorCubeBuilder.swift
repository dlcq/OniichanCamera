import CoreGraphics
import Foundation

/// ルック / 画像調整を 3D カラーキューブ（LUT）として構築する。
/// キューブは `CIColorCubeWithColorSpace` に渡す float32 RGBA データを返す。
enum ColorCubeBuilder {

    // MARK: - Public

    /// ルックのレシピと強度からキューブを構築する。
    /// 強度は「入力色」と「ルック変換色」の間の線形補間として実現する。
    static func lookCube(recipe: LookRecipe, intensity: Double, dimension: Int = 32) -> Data {
        let amount = clamp(intensity, 0, 1)
        return cubeData(dimension: dimension) { rgb in
            let transformed = apply(recipe: recipe, to: rgb)
            return mix(rgb, transformed, Float(amount))
        }
    }

    /// スライダー調整（彩度・自然な彩度・色相）用の軽量キューブ。
    static func adjustCube(saturation: Double, vibrance: Double, hueDegrees: Double, dimension: Int = 16) -> Data {
        cubeData(dimension: dimension) { rgb in
            var out = rgb
            if abs(hueDegrees) > 0.01 {
                out = rotateHue(out, degrees: hueDegrees)
            }
            if abs(vibrance) > 0.001 {
                out = applyVibrance(out, amount: vibrance)
            }
            if abs(saturation) > 0.001 {
                out = applySaturation(out, amount: saturation)
            }
            return out
        }
    }

    /// カスタム LUT（.cube）適用用キューブは `LUTLoader` が生成する。

    // MARK: - Cube data assembly

    static func cubeData(dimension: Int, transform: (SIMD3<Float>) -> SIMD3<Float>) -> Data {
        let d = max(2, min(dimension, 64))
        let cellCount = d * d * d
        var floats = [Float](repeating: 0, count: cellCount * 4)
        let denom = Float(d - 1)
        for b in 0..<d {
            let bf = Float(b) / denom
            for g in 0..<d {
                let gf = Float(g) / denom
                for r in 0..<d {
                    let rf = Float(r) / denom
                    let out = transform(SIMD3<Float>(rf, gf, bf))
                    let index = (r + g * d + b * d * d) * 4
                    floats[index] = clamp(out.x, 0, 1)
                    floats[index + 1] = clamp(out.y, 0, 1)
                    floats[index + 2] = clamp(out.z, 0, 1)
                    floats[index + 3] = 1
                }
            }
        }
        return floats.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    // MARK: - Look math

    private static func apply(recipe: LookRecipe, to input: SIMD3<Float>) -> SIMD3<Float> {
        var c = input

        // チャネルゲイン
        c.x *= Float(recipe.channelGainR)
        c.y *= Float(recipe.channelGainG)
        c.z *= Float(recipe.channelGainB)

        // 色温度バイアス（暖色 = R 増 / B 減）
        let warmth = Float(recipe.warmth) * 0.12
        c.x *= (1.0 + warmth)
        c.z *= (1.0 - warmth)

        // 階調：ガンマ → S 字カーブ → 黒の浮かせ
        if abs(recipe.gamma - 1.0) > 0.001 {
            let g = Float(recipe.gamma)
            c.x = powf(c.x, 1.0 / g)
            c.y = powf(c.y, 1.0 / g)
            c.z = powf(c.z, 1.0 / g)
        }
        let contrast = Float(recipe.contrast)
        if abs(contrast) > 0.001 {
            c.x = sCurve(c.x, amount: contrast)
            c.y = sCurve(c.y, amount: contrast)
            c.z = sCurve(c.z, amount: contrast)
        }
        let lift = Float(recipe.lift)
        if lift > 0.0005 {
            c.x = lift + c.x * (1.0 - lift)
            c.y = lift + c.y * (1.0 - lift)
            c.z = lift + c.z * (1.0 - lift)
        }

        // 彩度 / 自然な彩度
        if abs(recipe.vibrance) > 0.001 {
            c = applyVibrance(c, amount: recipe.vibrance)
        }
        if abs(recipe.saturation - 1.0) > 0.001 {
            c = applySaturation(c, amount: recipe.saturation - 1.0)
        }

        // スプリットトーニング（影と光に異なる色をのせる）
        let luma = lumaValue(c)
        c = applyTint(c, tint: recipe.shadowTint, weight: powf(1.0 - luma, 2.0))
        c = applyTint(c, tint: recipe.highlightTint, weight: powf(luma, 2.0))

        return c
    }

    // MARK: - Building blocks

    static func lumaValue(_ c: SIMD3<Float>) -> Float {
        0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z
    }

    /// 彩度（amount: -1 ... 1、-1 でモノクロ）
    static func applySaturation(_ c: SIMD3<Float>, amount: Double) -> SIMD3<Float> {
        let y = lumaValue(c)
        let k = 1.0 + Float(amount)
        return SIMD3<Float>(y + (c.x - y) * k, y + (c.y - y) * k, y + (c.z - y) * k)
    }

    /// 自然な彩度。彩度の低い色を優先的に持ち上げ、肌に近い色相は変化を抑える。
    static func applyVibrance(_ c: SIMD3<Float>, amount: Double) -> SIMD3<Float> {
        let maxC = max(c.x, max(c.y, c.z))
        let minC = min(c.x, min(c.y, c.z))
        let sat = maxC > 0 ? (maxC - minC) / max(maxC, 0.0001) : 0
        let hue = hueValue(c)
        // 肌色（橙〜赤）は変化を 50% 抑える
        let skinProtection = Float(skinLikelihood(hueDegrees: hue))
        let gain = 1.0 + Float(amount) * (1.0 - sat) * (1.0 - 0.5 * skinProtection)
        return applySaturation(c, amount: Double(gain - 1.0))
    }

    /// 色相回転（YIQ 近似）。度単位。
    static func rotateHue(_ c: SIMD3<Float>, degrees: Double) -> SIMD3<Float> {
        let angle = Float(degrees) * .pi / 180.0
        let cosA = cosf(angle)
        let sinA = sinf(angle)
        // ITU-R BT.601 の色相回転行列
        let m00 = 0.213 + cosA * 0.787 - sinA * 0.213
        let m01 = 0.715 - cosA * 0.715 - sinA * 0.715
        let m02 = 0.072 - cosA * 0.072 + sinA * 0.928
        let m10 = 0.213 - cosA * 0.213 + sinA * 0.143
        let m11 = 0.715 + cosA * 0.285 + sinA * 0.140
        let m12 = 0.072 - cosA * 0.072 - sinA * 0.283
        let m20 = 0.213 - cosA * 0.213 - sinA * 0.787
        let m21 = 0.715 - cosA * 0.715 + sinA * 0.715
        let m22 = 0.072 + cosA * 0.928 + sinA * 0.072
        return SIMD3<Float>(
            m00 * c.x + m01 * c.y + m02 * c.z,
            m10 * c.x + m11 * c.y + m12 * c.z,
            m20 * c.x + m21 * c.y + m22 * c.z
        )
    }

    private static func applyTint(_ c: SIMD3<Float>, tint: TintAmount, weight: Float) -> SIMD3<Float> {
        guard tint.saturation > 0.001, weight > 0.001 else { return c }
        let rgb = hueToRGB(hueDegrees: tint.hue)
        let w = weight * Float(tint.saturation)
        // ティント色へ引き寄せる（乗算的な引き寄せで彩度感を保つ）
        let target = SIMD3<Float>(
            c.x * (1.0 + (rgb.x - 0.5) * 2.0 * w),
            c.y * (1.0 + (rgb.y - 0.5) * 2.0 * w),
            c.z * (1.0 + (rgb.z - 0.5) * 2.0 * w)
        )
        return SIMD3<Float>(
            c.x + (target.x - c.x),
            c.y + (target.y - c.y),
            c.z + (target.z - c.z)
        )
    }

    static func sCurve(_ x: Float, amount: Float) -> Float {
        let smooth = x * x * (3.0 - 2.0 * x)
        return x + (smooth - x) * amount
    }

    static func hueValue(_ c: SIMD3<Float>) -> Double {
        let maxC = max(c.x, max(c.y, c.z))
        let minC = min(c.x, min(c.y, c.z))
        let delta = maxC - minC
        guard delta > 0.00001 else { return 0 }
        var h: Float
        if maxC == c.x {
            h = fmodf((c.y - c.z) / delta, 6.0)
        } else if maxC == c.y {
            h = (c.z - c.x) / delta + 2.0
        } else {
            h = (c.x - c.y) / delta + 4.0
        }
        let degrees = h * 60.0
        return Double(degrees < 0 ? degrees + 360 : degrees)
    }

    private static func skinLikelihood(hueDegrees: Double) -> Double {
        // 肌色はだいたい 15°〜50° に分布する
        let distance = min(abs(hueDegrees - 30.0), abs(hueDegrees - 390.0), abs(hueDegrees + 330.0))
        return max(0.0, 1.0 - distance / 25.0)
    }

    static func hueToRGB(hueDegrees: Double) -> SIMD3<Float> {
        let h = ((hueDegrees.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360) / 60.0
        let sector = Int(h)
        let f = h - Double(sector)
        let q: Float = 1.0 - Float(f)
        let t: Float = Float(f)
        switch sector {
        case 0: return SIMD3<Float>(1, t, 0)
        case 1: return SIMD3<Float>(q, 1, 0)
        case 2: return SIMD3<Float>(0, 1, t)
        case 3: return SIMD3<Float>(0, q, 1)
        case 4: return SIMD3<Float>(t, 0, 1)
        default: return SIMD3<Float>(1, 0, q)
        }
    }

    static func clamp<T: Comparable>(_ value: T, _ minValue: T, _ maxValue: T) -> T {
        min(max(value, minValue), maxValue)
    }

    static func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> {
        a + (b - a) * t
    }
}
