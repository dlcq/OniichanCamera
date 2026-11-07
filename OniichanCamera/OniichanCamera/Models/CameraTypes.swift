import AVFoundation
import CoreGraphics
import Foundation

// MARK: - Capture mode

/// 撮影モード。AUTO は優秀な自動制御のみ、PRO はマニュアル操作を展開する。
enum CaptureMode: String, CaseIterable, Identifiable {
    case auto
    case pro

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "AUTO"
        case .pro: return "PRO"
        }
    }
}

// MARK: - File formats

/// 保存フォーマット。RAW / ProRAW の可否は実機の AVCapturePhotoOutput で判定する。
enum PhotoFileFormat: String, CaseIterable, Identifiable {
    case heif
    case jpeg
    case raw
    case proRaw

    var id: String { rawValue }

    var title: String {
        switch self {
        case .heif: return "HEIF"
        case .jpeg: return "JPEG"
        case .raw: return "RAW (DNG)"
        case .proRaw: return "Apple ProRAW"
        }
    }

    var shortTitle: String {
        switch self {
        case .heif: return "HEIF"
        case .jpeg: return "JPEG"
        case .raw: return "RAW"
        case .proRaw: return "ProRAW"
        }
    }

    var details: String {
        switch self {
        case .heif:
            return "高画質・省スペース。ルックと画像調整を適用した仕上がりで保存します。"
        case .jpeg:
            return "互換性最優先。最大画質（品質 95%）で保存します。"
        case .raw:
            return "センサーの生データを DNG で保存します。現像は後工程に委ねられます。"
        case .proRaw:
            return "Apple ProRAW。広いダイナミックレンジを保持した DNG で保存します。"
        }
    }

    var isRaw: Bool {
        self == .raw || self == .proRaw
    }
}

// MARK: - Timer

/// タイマー撮影の設定。秒数 0 はオフ。
enum TimerPreset: Int, CaseIterable, Identifiable {
    case off = 0
    case threeSeconds = 3
    case fiveSeconds = 5
    case tenSeconds = 10
    case custom = -1

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .off: return "オフ"
        case .threeSeconds: return "3秒"
        case .fiveSeconds: return "5秒"
        case .tenSeconds: return "10秒"
        case .custom: return "カスタム"
        }
    }
}

// MARK: - Aspect guides

/// 構図確認用ガイド。保存画のアスペクトは変更しない（プレビュー上のガイドのみ）。
enum AspectGuide: String, CaseIterable, Identifiable {
    case off
    case ratio4x3
    case ratio16x9
    case ratio1x1
    case ratio239x1

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "オフ"
        case .ratio4x3: return "4:3"
        case .ratio16x9: return "16:9"
        case .ratio1x1: return "1:1"
        case .ratio239x1: return "2.39:1"
        }
    }

    /// ガイド枠の縦横比（幅 / 高さ）。`off` は nil。
    var ratio: CGFloat? {
        switch self {
        case .off: return nil
        case .ratio4x3: return 4.0 / 3.0
        case .ratio16x9: return 16.0 / 9.0
        case .ratio1x1: return 1.0
        case .ratio239x1: return 2.39
        }
    }
}

// MARK: - Grid

enum GridStyle: String, CaseIterable, Identifiable {
    case off
    case thirds
    case golden
    case centerCross

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "オフ"
        case .thirds: return "三分割"
        case .golden: return "黄金比"
        case .centerCross: return "センター"
        }
    }
}

// MARK: - Flash

enum FlashModeSetting: Int, CaseIterable, Identifiable {
    case off = 0
    case auto = 1
    case on = 2

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .off: return "オフ"
        case .auto: return "オート"
        case .on: return "オン"
        }
    }

    var symbol: String {
        switch self {
        case .off: return "bolt.slash"
        case .auto: return "bolt.badge.a"
        case .on: return "bolt.fill"
        }
    }

    var avFlashMode: AVCaptureDevice.FlashMode {
        switch self {
        case .off: return .off
        case .auto: return .auto
        case .on: return .on
        }
    }
}

// MARK: - Zoom lenses

struct ZoomLens: Identifiable, Hashable {
    let factor: CGFloat

    var id: CGFloat { factor }

    var title: String {
        if factor >= 10 { return String(format: "%.0f×", factor) }
        return String(format: "%.1f×", factor)
    }
}

// MARK: - Shutter speeds

enum ShutterSpeed {
    /// マニュアル露出で選択可能なシャッタースピード（秒）。1/8000 〜 4 秒。
    static let allValues: [Double] = [
        1.0 / 8000.0, 1.0 / 6400.0, 1.0 / 5000.0, 1.0 / 4000.0, 1.0 / 3200.0,
        1.0 / 2500.0, 1.0 / 2000.0, 1.0 / 1600.0, 1.0 / 1250.0, 1.0 / 1000.0,
        1.0 / 800.0, 1.0 / 640.0, 1.0 / 500.0, 1.0 / 400.0, 1.0 / 320.0,
        1.0 / 250.0, 1.0 / 200.0, 1.0 / 160.0, 1.0 / 125.0, 1.0 / 100.0,
        1.0 / 80.0, 1.0 / 60.0, 1.0 / 50.0, 1.0 / 40.0, 1.0 / 30.0,
        1.0 / 25.0, 1.0 / 20.0, 1.0 / 15.0, 1.0 / 13.0, 1.0 / 10.0,
        1.0 / 8.0, 1.0 / 6.0, 1.0 / 5.0, 1.0 / 4.0, 1.0 / 3.0,
        1.0 / 2.0, 1.0 / 1.5, 1.0, 2.0, 4.0,
    ]

    static func displayString(seconds: Double) -> String {
        if seconds >= 1.0 {
            return String(format: "%.0f\"", seconds)
        }
        return String(format: "1/%.0f", (1.0 / seconds).rounded())
    }
}

// MARK: - White balance presets

struct WhiteBalancePreset: Identifiable, Hashable {
    let id: String
    let title: String
    let kelvin: Double
    let tint: Double
}

enum WhiteBalancePresets {
    static let all: [WhiteBalancePreset] = [
        WhiteBalancePreset(id: "auto", title: "オート", kelvin: 0, tint: 0),
        WhiteBalancePreset(id: "daylight", title: "昼光", kelvin: 5500, tint: 0),
        WhiteBalancePreset(id: "cloudy", title: "曇天", kelvin: 6500, tint: 8),
        WhiteBalancePreset(id: "shade", title: "日陰", kelvin: 7500, tint: 12),
        WhiteBalancePreset(id: "tungsten", title: "タングステン", kelvin: 3200, tint: -5),
        WhiteBalancePreset(id: "fluorescent", title: "蛍光灯", kelvin: 4200, tint: 20),
    ]
}

// MARK: - Capabilities (runtime detection)

struct CameraCapabilities: Equatable {
    var supportsRAW: Bool = false
    var supportsProRAW: Bool = false
    var hasFlash: Bool = false
    var hasUltraWide: Bool = false
    var hasTelephoto: Bool = false
    var minISO: Float = 50
    var maxISO: Float = 3200
    var minShutter: Double = 1.0 / 8000.0
    var maxShutter: Double = 1.0
    var minZoom: CGFloat = 1.0
    var maxZoom: CGFloat = 10.0
    var lenses: [ZoomLens] = [ZoomLens(factor: 1.0)]
    var deviceName: String = ""
    var formatDescription: String = ""

    var isoValues: [Float] {
        // ISO は対数的な刻みで提示する
        let candidates: [Float] = [50, 64, 80, 100, 125, 160, 200, 250, 320, 400, 500, 640, 800, 1000, 1250, 1600, 2000, 2500, 3200, 4000, 5000, 6400, 8000, 10000, 12800, 16000, 20000, 25600]
        return candidates.filter { $0 >= minISO && $0 <= maxISO }
    }

    var shutterValues: [Double] {
        ShutterSpeed.allValues.filter { $0 >= minShutter && $0 <= maxShutter }
    }
}

// MARK: - Capture record (for photo info display)

struct CaptureRecord: Codable, Identifiable, Equatable {
    var id: String
    var date: Date
    var fileFormat: String
    var lookName: String
    var lookIntensity: Double
    var iso: Float
    var shutterSeconds: Double
    var exposureBias: Float
    var lensTitle: String
    var zoomFactor: Double
    var kelvin: Double
    var tint: Double
    var focusPosition: Double
    var width: Int
    var height: Int
    var isSilent: Bool
    var rawPixelFormat: String?
    var deviceName: String

    var shutterDisplay: String {
        shutterSeconds > 0 ? ShutterSpeed.displayString(seconds: shutterSeconds) : "—"
    }
}

/// 撮影瞬間の記録用スナップショット。
struct CaptureSnapshot {
    var iso: Float
    var shutterSeconds: Double
    var exposureBias: Float
    var lensTitle: String
    var zoomFactor: Double
    var kelvin: Double
    var tint: Double
    var focusPosition: Double
    var deviceName: String
}
