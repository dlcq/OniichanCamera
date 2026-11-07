import Combine
import Foundation

/// アプリ全体の設定。すべて UserDefaults に保存され、次回起動時に復元される。
final class AppSettings: ObservableObject {

    // MARK: - Capture

    @Published var captureMode: CaptureMode {
        didSet { defaults.set(captureMode.rawValue, forKey: Keys.captureMode) }
    }
    @Published var fileFormat: PhotoFileFormat {
        didSet { defaults.set(fileFormat.rawValue, forKey: Keys.fileFormat) }
    }
    @Published var flashMode: FlashModeSetting {
        didSet { defaults.set(flashMode.rawValue, forKey: Keys.flashMode) }
    }
    /// タイマー秒数。0 = オフ
    @Published var timerSeconds: Int {
        didSet { defaults.set(timerSeconds, forKey: Keys.timerSeconds) }
    }
    @Published var customTimerSeconds: Int {
        didSet { defaults.set(customTimerSeconds, forKey: Keys.customTimerSeconds) }
    }
    /// 連写撮影の有無
    @Published var isBurstEnabled: Bool {
        didSet { defaults.set(isBurstEnabled, forKey: Keys.burstEnabled) }
    }
    @Published var burstCount: Int {
        didSet { defaults.set(burstCount, forKey: Keys.burstCount) }
    }
    /// 撮影直後のプレビューを表示する
    @Published var showsCaptureReview: Bool {
        didSet { defaults.set(showsCaptureReview, forKey: Keys.showsCaptureReview) }
    }
    /// サイレント撮影（フレームキャプチャ方式）を使う
    @Published var silentCaptureEnabled: Bool {
        didSet { defaults.set(silentCaptureEnabled, forKey: Keys.silentCaptureEnabled) }
    }

    // MARK: - Color

    @Published var lookID: String {
        didSet { defaults.set(lookID, forKey: Keys.lookID) }
    }
    @Published var lookIntensity: Double {
        didSet { defaults.set(lookIntensity, forKey: Keys.lookIntensity) }
    }
    @Published var adjustments: ImageAdjustments {
        didSet {
            if let data = try? JSONEncoder().encode(adjustments) {
                defaults.set(data, forKey: Keys.adjustments)
            }
        }
    }
    /// カスタム LUT（.cube）のファイル名（Documents/LUTs 配下）
    @Published var lutFileName: String? {
        didSet { defaults.set(lutFileName, forKey: Keys.lutFileName) }
    }

    // MARK: - Assistance overlays

    @Published var gridStyle: GridStyle {
        didSet { defaults.set(gridStyle.rawValue, forKey: Keys.gridStyle) }
    }
    @Published var showsLevel: Bool {
        didSet { defaults.set(showsLevel, forKey: Keys.showsLevel) }
    }
    @Published var showsHistogram: Bool {
        didSet { defaults.set(showsHistogram, forKey: Keys.showsHistogram) }
    }
    @Published var showsZebra: Bool {
        didSet { defaults.set(showsZebra, forKey: Keys.showsZebra) }
    }
    @Published var zebraThreshold: Double {
        didSet { defaults.set(zebraThreshold, forKey: Keys.zebraThreshold) }
    }
    @Published var showsFocusPeaking: Bool {
        didSet { defaults.set(showsFocusPeaking, forKey: Keys.showsFocusPeaking) }
    }
    @Published var peakingThreshold: Double {
        didSet { defaults.set(peakingThreshold, forKey: Keys.peakingThreshold) }
    }
    @Published var showsSafeAreaGuide: Bool {
        didSet { defaults.set(showsSafeAreaGuide, forKey: Keys.showsSafeAreaGuide) }
    }
    @Published var aspectGuide: AspectGuide {
        didSet { defaults.set(aspectGuide.rawValue, forKey: Keys.aspectGuide) }
    }
    /// オーバーレイ類の不透明度（0.2 ... 1.0）
    @Published var overlayOpacity: Double {
        didSet { defaults.set(overlayOpacity, forKey: Keys.overlayOpacity) }
    }
    /// オーバーレイの色（white / amber / cyan）
    @Published var overlayColorName: String {
        didSet { defaults.set(overlayColorName, forKey: Keys.overlayColorName) }
    }

    // MARK: - Behavior

    @Published var hapticsEnabled: Bool {
        didSet { defaults.set(hapticsEnabled, forKey: Keys.hapticsEnabled) }
    }
    @Published var keepsScreenAwake: Bool {
        didSet { defaults.set(keepsScreenAwake, forKey: Keys.keepsScreenAwake) }
    }

    // MARK: - Init

    private let defaults = UserDefaults.standard

    init() {
        let d = UserDefaults.standard
        captureMode = CaptureMode(rawValue: d.string(forKey: Keys.captureMode) ?? "") ?? .auto
        fileFormat = PhotoFileFormat(rawValue: d.string(forKey: Keys.fileFormat) ?? "") ?? .heif
        flashMode = FlashModeSetting(rawValue: d.integer(forKey: Keys.flashMode)) ?? .off
        timerSeconds = d.object(forKey: Keys.timerSeconds) as? Int ?? 0
        customTimerSeconds = max(1, min(60, d.object(forKey: Keys.customTimerSeconds) as? Int ?? 7))
        isBurstEnabled = d.bool(forKey: Keys.burstEnabled)
        burstCount = max(2, min(10, d.object(forKey: Keys.burstCount) as? Int ?? 5))
        showsCaptureReview = d.object(forKey: Keys.showsCaptureReview) as? Bool ?? true
        silentCaptureEnabled = d.object(forKey: Keys.silentCaptureEnabled) as? Bool ?? false

        lookID = d.string(forKey: Keys.lookID) ?? LookCatalog.all[0].id
        lookIntensity = d.object(forKey: Keys.lookIntensity) as? Double ?? 1.0
        if let data = d.data(forKey: Keys.adjustments),
           let decoded = try? JSONDecoder().decode(ImageAdjustments.self, from: data) {
            adjustments = decoded
        } else {
            adjustments = .neutral
        }
        lutFileName = d.string(forKey: Keys.lutFileName)

        gridStyle = GridStyle(rawValue: d.string(forKey: Keys.gridStyle) ?? "") ?? .thirds
        showsLevel = d.bool(forKey: Keys.showsLevel)
        showsHistogram = d.object(forKey: Keys.showsHistogram) as? Bool ?? true
        showsZebra = d.bool(forKey: Keys.showsZebra)
        zebraThreshold = d.object(forKey: Keys.zebraThreshold) as? Double ?? 0.94
        showsFocusPeaking = d.bool(forKey: Keys.showsFocusPeaking)
        peakingThreshold = d.object(forKey: Keys.peakingThreshold) as? Double ?? 0.16
        showsSafeAreaGuide = d.bool(forKey: Keys.showsSafeAreaGuide)
        aspectGuide = AspectGuide(rawValue: d.string(forKey: Keys.aspectGuide) ?? "") ?? .off
        overlayOpacity = d.object(forKey: Keys.overlayOpacity) as? Double ?? 0.8
        overlayColorName = d.string(forKey: Keys.overlayColorName) ?? "white"

        hapticsEnabled = d.object(forKey: Keys.hapticsEnabled) as? Bool ?? true
        keepsScreenAwake = d.object(forKey: Keys.keepsScreenAwake) as? Bool ?? true
    }

    // MARK: - Derived

    var currentLook: LookRecipe {
        LookCatalog.recipe(for: lookID)
    }

    /// プレビューと保存の双方に渡すレンダリングスタイル。
    func currentStyle() -> RenderStyle {
        RenderStyle(
            look: currentLook,
            lookIntensity: lookIntensity,
            adjustments: adjustments,
            lut: loadedLUT()
        )
    }

    private var cachedLUT: CubeLUT?
    private var cachedLUTName: String?

    func loadedLUT() -> CubeLUT? {
        guard let name = lutFileName else {
            cachedLUT = nil
            cachedLUTName = nil
            return nil
        }
        if cachedLUTName == name, let cached = cachedLUT {
            return cached
        }
        let url = Self.lutsDirectory.appendingPathComponent(name)
        if let lut = try? LUTLoader.load(from: url) {
            cachedLUT = lut
            cachedLUTName = name
            return lut
        }
        cachedLUT = nil
        cachedLUTName = nil
        return nil
    }

    static var lutsDirectory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = documents.appendingPathComponent("LUTs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// タイマーの実効秒数
    var effectiveTimerSeconds: Int {
        timerSeconds == TimerPreset.custom.rawValue ? customTimerSeconds : timerSeconds
    }

    func resetColorSettings() {
        lookID = LookCatalog.all[0].id
        lookIntensity = 1.0
        adjustments = .neutral
        lutFileName = nil
    }

    private enum Keys {
        static let captureMode = "settings.captureMode"
        static let fileFormat = "settings.fileFormat"
        static let flashMode = "settings.flashMode"
        static let timerSeconds = "settings.timerSeconds"
        static let customTimerSeconds = "settings.customTimerSeconds"
        static let burstEnabled = "settings.burstEnabled"
        static let burstCount = "settings.burstCount"
        static let showsCaptureReview = "settings.showsCaptureReview"
        static let silentCaptureEnabled = "settings.silentCaptureEnabled"
        static let lookID = "settings.lookID"
        static let lookIntensity = "settings.lookIntensity"
        static let adjustments = "settings.adjustments"
        static let lutFileName = "settings.lutFileName"
        static let gridStyle = "settings.gridStyle"
        static let showsLevel = "settings.showsLevel"
        static let showsHistogram = "settings.showsHistogram"
        static let showsZebra = "settings.showsZebra"
        static let zebraThreshold = "settings.zebraThreshold"
        static let showsFocusPeaking = "settings.showsFocusPeaking"
        static let peakingThreshold = "settings.peakingThreshold"
        static let showsSafeAreaGuide = "settings.showsSafeAreaGuide"
        static let aspectGuide = "settings.aspectGuide"
        static let overlayOpacity = "settings.overlayOpacity"
        static let overlayColorName = "settings.overlayColorName"
        static let hapticsEnabled = "settings.hapticsEnabled"
        static let keepsScreenAwake = "settings.keepsScreenAwake"
    }
}
