import CoreGraphics
import Foundation

// MARK: - User adjustments

/// 画像調整（詳細設定）。すべて -1...1 または 0...1 に正規化して保持する。
/// 保存画像とプレビューは同一の `ColorPipeline` を通すため、ここで触れた値は必ず写真にも反映される。
struct ImageAdjustments: Codable, Equatable {
    /// 露出（EV）。-2 ... +2
    var exposure: Double = 0
    /// コントラスト。-1 ... 1
    var contrast: Double = 0
    /// 彩度。-1 ... 1
    var saturation: Double = 0
    /// 自然な彩度（肌色を守りつつ低彩度部を持ち上げる）。-1 ... 1
    var vibrance: Double = 0
    /// ハイライト。-1（抑える）... 1（持ち上げる）
    var highlights: Double = 0
    /// シャドウ。-1（締める）... 1（持ち上げる）
    var shadows: Double = 0
    /// 色温度。正 = 暖色寄り、負 = 寒色寄り。-1 ... 1
    var temperature: Double = 0
    /// ティント。正 = マゼンタ寄り、負 = グリーン寄り。-1 ... 1
    var tint: Double = 0
    /// 色相回転。-30° ... 30°（-1 ... 1 で保持）
    var hue: Double = 0
    /// シャープネス。0 ... 1
    var sharpness: Double = 0
    /// 明瞭度（ローカルコントラスト）。0 ... 1
    var clarity: Double = 0
    /// 粒子感。0 ... 1
    var grain: Double = 0
    /// 周辺光量（ビネット）。0 ... 1
    var vignette: Double = 0
    /// フェード（黒浮き）。0 ... 1
    var fade: Double = 0

    static let neutral = ImageAdjustments()

    var isNeutral: Bool { self == .neutral }

    var nonNeutralCount: Int {
        let values = [exposure, contrast, saturation, vibrance, highlights, shadows,
                      temperature, tint, hue, sharpness, clarity, grain, vignette, fade]
        return values.filter { abs($0) > 0.0001 }.count
    }

    mutating func reset() { self = .neutral }
}

// MARK: - Look recipes

struct TintAmount: Codable, Equatable {
    /// 色相（0...360 度）
    var hue: Double
    /// 0 ... 1
    var saturation: Double

    static let none = TintAmount(hue: 0, saturation: 0)
}

/// カラールックの設計パラメータ。
/// 単なる「色かぶせ」ではなく、階調・色相・彩度・粒子・周辺光量まで含めて設計する。
/// 実際の変換は `ColorCubeBuilder.lookCube(recipe:intensity:)` が 3D LUT として構築する。
struct LookRecipe: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var summary: String

    // 階調
    /// 1.0 が基準。S 字カーブの強さ
    var contrast: Double
    /// ミッドトーンの持ち上げ/沈め（1.0 が基準）
    var gamma: Double
    /// 黒の浮かせ（0 が基準）
    var lift: Double

    // 色
    /// 全体彩度（1.0 が基準）
    var saturation: Double
    /// 自然な彩度（0 が基準）
    var vibrance: Double
    /// 色温度バイアス（0 が基準、正 = 暖色）
    var warmth: Double
    /// チャネルごとのゲイン
    var channelGainR: Double
    var channelGainG: Double
    var channelGainB: Double
    /// シャドウ / ハイライトの色かぶり（スプリットトーニング）
    var shadowTint: TintAmount
    var highlightTint: TintAmount

    // 質感
    var grain: Double
    var vignette: Double
    var clarity: Double
    var sharpness: Double

    static func == (lhs: LookRecipe, rhs: LookRecipe) -> Bool { lhs.id == rhs.id }
}

enum LookCatalog {
    static let all: [LookRecipe] = [
        LookRecipe(
            id: "natural",
            name: "Natural",
            summary: "忠実で自然な階調。肌の再現性を最優先した基準ルック。",
            contrast: 0.06, gamma: 1.0, lift: 0.005,
            saturation: 1.0, vibrance: 0.12, warmth: 0.0,
            channelGainR: 1.0, channelGainG: 1.0, channelGainB: 1.0,
            shadowTint: TintAmount(hue: 220, saturation: 0.02),
            highlightTint: TintAmount(hue: 50, saturation: 0.015),
            grain: 0.0, vignette: 0.05, clarity: 0.16, sharpness: 0.34
        ),
        LookRecipe(
            id: "cinematic",
            name: "Cinematic",
            summary: "影に寒色、ハイライトにわずかな暖色。フィルムを意識した抑制的な彩度。",
            contrast: 0.22, gamma: 0.99, lift: 0.045,
            saturation: 0.92, vibrance: 0.26, warmth: -0.08,
            channelGainR: 1.02, channelGainG: 1.0, channelGainB: 0.985,
            shadowTint: TintAmount(hue: 212, saturation: 0.10),
            highlightTint: TintAmount(hue: 42, saturation: 0.065),
            grain: 0.13, vignette: 0.22, clarity: 0.30, sharpness: 0.30
        ),
        LookRecipe(
            id: "muted",
            name: "Muted",
            summary: "彩度を繊細に抑えた、静かで上質なトーン。",
            contrast: 0.08, gamma: 1.01, lift: 0.035,
            saturation: 0.74, vibrance: 0.20, warmth: 0.02,
            channelGainR: 1.0, channelGainG: 1.0, channelGainB: 1.005,
            shadowTint: TintAmount(hue: 205, saturation: 0.05),
            highlightTint: TintAmount(hue: 60, saturation: 0.035),
            grain: 0.07, vignette: 0.12, clarity: 0.14, sharpness: 0.26
        ),
        LookRecipe(
            id: "contrast",
            name: "Contrast",
            summary: "明暗差を主役に。黒は締まり、白は破綻させない。",
            contrast: 0.42, gamma: 0.985, lift: 0.0,
            saturation: 1.05, vibrance: 0.18, warmth: 0.0,
            channelGainR: 1.01, channelGainG: 1.0, channelGainB: 0.995,
            shadowTint: TintAmount(hue: 232, saturation: 0.06),
            highlightTint: TintAmount(hue: 52, saturation: 0.05),
            grain: 0.05, vignette: 0.18, clarity: 0.42, sharpness: 0.42
        ),
        LookRecipe(
            id: "noir",
            name: "Noir",
            summary: "モノクロームに近い退廃的な暗部。粒子と周辺減光で緊張感を出す。",
            contrast: 0.50, gamma: 0.94, lift: 0.02,
            saturation: 0.14, vibrance: 0.0, warmth: -0.14,
            channelGainR: 1.0, channelGainG: 1.0, channelGainB: 1.02,
            shadowTint: TintAmount(hue: 224, saturation: 0.12),
            highlightTint: TintAmount(hue: 205, saturation: 0.03),
            grain: 0.30, vignette: 0.34, clarity: 0.48, sharpness: 0.40
        ),
        LookRecipe(
            id: "warm",
            name: "Warm",
            summary: "夕方の光を思わせる、肌がきれいに見える暖色設計。",
            contrast: 0.14, gamma: 1.0, lift: 0.03,
            saturation: 1.02, vibrance: 0.28, warmth: 0.30,
            channelGainR: 1.035, channelGainG: 1.0, channelGainB: 0.945,
            shadowTint: TintAmount(hue: 32, saturation: 0.07),
            highlightTint: TintAmount(hue: 46, saturation: 0.10),
            grain: 0.08, vignette: 0.12, clarity: 0.20, sharpness: 0.30
        ),
        LookRecipe(
            id: "cool",
            name: "Cool",
            summary: "北欧の朝のような、青みの効いた落ち着いた色調。",
            contrast: 0.16, gamma: 1.0, lift: 0.035,
            saturation: 0.98, vibrance: 0.24, warmth: -0.30,
            channelGainR: 0.965, channelGainG: 1.0, channelGainB: 1.05,
            shadowTint: TintAmount(hue: 218, saturation: 0.12),
            highlightTint: TintAmount(hue: 190, saturation: 0.06),
            grain: 0.08, vignette: 0.14, clarity: 0.20, sharpness: 0.30
        ),
    ]

    static func recipe(for id: String) -> LookRecipe {
        all.first { $0.id == id } ?? all[0]
    }
}
