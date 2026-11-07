import AVFoundation
import CoreImage
import CoreMedia
import Foundation
import UIKit

/// カメラセッションと撮影制御の中心。
///
/// - セッションの構成・起動・停止（バックグラウンドキュー）
/// - 露出 / フォーカス / ホワイトバランス / ズームの制御
/// - プレビューフレームのカラーパイプライン処理と解析
/// - 写真撮影（プロセスド / RAW / ProRAW）とサイレント撮影
final class CameraController: NSObject, ObservableObject {

    // MARK: - Published state（メインスレッドで更新）

    @Published private(set) var isSessionRunning = false
    @Published private(set) var isConfigured = false
    @Published private(set) var capabilities = CameraCapabilities()
    @Published private(set) var cameraPosition: AVCaptureDevice.Position = .back
    @Published private(set) var zoomFactor: CGFloat = 1.0

    @Published private(set) var liveISO: Float = 0
    @Published private(set) var liveShutterSeconds: Double = 0
    @Published private(set) var liveLensPosition: Float = 0
    @Published private(set) var liveExposureBias: Float = 0
    @Published private(set) var isAdjustingExposure = false
    @Published private(set) var isAdjustingFocus = false
    @Published private(set) var isAdjustingWhiteBalance = false

    @Published private(set) var analysis = FrameAnalyzer.Result(histogram: .empty, zebraImage: nil, peakImage: nil)
    @Published private(set) var errorMessage: String?
    @Published private(set) var focusPoint: CGPoint?

    // マニュアル設定（UI から直接変更する）
    @Published var isManualISOEnabled = false { didSet { applyExposureConfiguration() } }
    @Published var manualISO: Float = 100 { didSet { applyExposureConfiguration() } }
    @Published var isManualShutterEnabled = false { didSet { applyExposureConfiguration() } }
    @Published var manualShutterSeconds: Double = 1.0 / 125.0 { didSet { applyExposureConfiguration() } }
    @Published var exposureBias: Float = 0 { didSet { applyExposureConfiguration() } }

    @Published var isManualFocusEnabled = false { didSet { applyFocusConfiguration() } }
    @Published var manualFocusPosition: Float = 0.5 { didSet { applyFocusConfiguration() } }

    @Published var isManualWhiteBalanceEnabled = false { didSet { applyWhiteBalanceConfiguration() } }
    @Published var whiteBalanceKelvin: Double = 5500 { didSet { applyWhiteBalanceConfiguration() } }
    @Published var whiteBalanceTint: Double = 0 { didSet { applyWhiteBalanceConfiguration() } }

    @Published var isAELocked = false { didSet { applyLockState() } }
    @Published var isAFLocked = false { didSet { applyLockState() } }

    // MARK: - Core objects

    let previewView = PreviewMetalView(frame: .zero)
    private let pipeline = ColorPipeline.shared
    private let analyzer = FrameAnalyzer()

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "jp.oniichan.camera.session")
    private let renderQueue = DispatchQueue(label: "jp.oniichan.camera.render", qos: .userInteractive)
    private let processingQueue = DispatchQueue(label: "jp.oniichan.camera.processing", qos: .userInitiated)

    private var videoDeviceInput: AVCaptureDeviceInput?
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()

    /// 座標変換用の非表示プレビューレイヤー
    private let conversionLayer = AVCaptureVideoPreviewLayer()

    private var activeProcessors: [Int64: PhotoCaptureProcessor] = [:]
    private var style = RenderStyle(look: LookCatalog.all[0], lookIntensity: 1.0, adjustments: .neutral, lut: nil)
    private let styleLock = NSLock()

    private var lastFrameTime: CFTimeInterval = 0
    private var lastAnalysisTime: CFTimeInterval = 0
    private var liveValuesTimer: DispatchSourceTimer?

    private struct SilentRequest {
        let style: RenderStyle
        let snapshot: CaptureSnapshot
        let completion: (Result<PhotoCaptureProcessor.CaptureOutput, Error>) -> Void
    }
    private var pendingSilentRequest: SilentRequest?

    // MARK: - Silent capture availability

    /// システムがシャッター音の消去を認めている環境でのみサイレント撮影を提供する。
    /// シャッター音が法令で必須とされる地域（日本）では利用できない。
    static var isSilentCaptureAvailable: Bool {
        if let region = Locale.current.region?.identifier, region == "JP" {
            return false
        }
        return true
    }

    static var silentCaptureExplanation: String {
        if isSilentCaptureAvailable {
            return "カメラ映像ストリームから静止画フレームを保存する方式で、シャッター音なしで撮影できます（公開 API のみ使用）。通常撮影と比べて保存解像度が映像ストリームに依存します。"
        }
        return "この端末の地域設定では、シャッター音が法令により必須とされているため無音撮影は利用できません。システムの制約を尊重し、回避手段は実装していません。"
    }

    // MARK: - Lifecycle

    override init() {
        super.init()
        conversionLayer.session = session
        conversionLayer.videoGravity = .resizeAspectFill

        NotificationCenter.default.addObserver(self, selector: #selector(sessionWasInterrupted(_:)),
                                               name: AVCaptureSession.wasInterruptedNotification, object: session)
        NotificationCenter.default.addObserver(self, selector: #selector(sessionInterruptionEnded(_:)),
                                               name: AVCaptureSession.interruptionEndedNotification, object: session)
        NotificationCenter.default.addObserver(self, selector: #selector(sessionRuntimeError(_:)),
                                               name: AVCaptureSession.runtimeErrorNotification, object: session)
        NotificationCenter.default.addObserver(self, selector: #selector(appDidEnterBackground),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appWillEnterForeground),
                                               name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        liveValuesTimer?.cancel()
    }

    // MARK: - Session setup

    /// セッションを構成して開始する。UI から 1 回だけ呼ぶ。
    func start() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.isConfigured {
                self.configureSession()
            }
            self.startRunningLocked()
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
            DispatchQueue.main.async { self.isSessionRunning = false }
        }
    }

    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .photo

        guard let device = Self.bestDevice(for: cameraPosition) else {
            session.commitConfiguration()
            publishError("カメラデバイスを利用できません。")
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) {
                session.addInput(input)
                videoDeviceInput = input
            }
        } catch {
            session.commitConfiguration()
            publishError("カメラの初期化に失敗しました：\(error.localizedDescription)")
            return
        }

        photoOutput.maxPhotoQualityPrioritization = .quality
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
        }

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: renderQueue)
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }

        session.commitConfiguration()

        configureConnections()
        refreshCapabilities()
        startLiveValuesTimer()
        DispatchQueue.main.async { self.isConfigured = true }
    }

    private func configureConnections() {
        if let connection = videoOutput.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
            connection.isVideoMirrored = cameraPosition == .front && connection.isVideoMirroringSupported
        }
        if let connection = photoOutput.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
            connection.isVideoMirrored = cameraPosition == .front && connection.isVideoMirroringSupported
        }
        if let connection = conversionLayer.connection, connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
    }

    private func startRunningLocked() {
        guard !session.isRunning else {
            DispatchQueue.main.async { self.isSessionRunning = true }
            return
        }
        session.startRunning()
        applyExposureConfiguration()
        applyFocusConfiguration()
        applyWhiteBalanceConfiguration()
        applyLockState()
        DispatchQueue.main.async { self.isSessionRunning = true }
    }

    private static func bestDevice(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType]
        if position == .back {
            types = [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera,
                     .builtInWideAngleCamera, .builtInTelephotoCamera]
        } else {
            types = [.builtInWideAngleCamera, .builtInTrueDepthCamera]
        }
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: position)
        return discovery.devices.first ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
    }

    // MARK: - Capabilities

    private func refreshCapabilities() {
        guard let device = videoDeviceInput?.device else { return }
        let format = device.activeFormat

        var caps = CameraCapabilities()
        caps.minISO = format.minISO
        caps.maxISO = format.maxISO
        caps.minShutter = CMTimeGetSeconds(format.minExposureDuration)
        caps.maxShutter = CMTimeGetSeconds(format.maxExposureDuration)
        caps.minZoom = device.minAvailableVideoZoomFactor
        caps.maxZoom = device.maxAvailableVideoZoomFactor
        caps.hasFlash = device.hasFlash
        caps.hasUltraWide = device.minAvailableVideoZoomFactor < 0.9
        caps.deviceName = device.localizedName
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        caps.formatDescription = "\(dimensions.width) × \(dimensions.height)"
        caps.supportsRAW = !photoOutput.availableRawPhotoPixelFormatTypes.isEmpty
        caps.supportsProRAW = photoOutput.isAppleProRAWSupported

        var lenses: [ZoomLens] = []
        let candidates: [CGFloat] = [0.5, 1.0, 2.0, 5.0]
        for factor in candidates where factor >= caps.minZoom && factor <= caps.maxZoom {
            lenses.append(ZoomLens(factor: factor))
        }
        caps.lenses = lenses.isEmpty ? [ZoomLens(factor: min(max(1.0, caps.minZoom), caps.maxZoom))] : lenses

        DispatchQueue.main.async {
            self.capabilities = caps
            if !self.capabilities.lenses.contains(where: { abs($0.factor - self.zoomFactor) < 0.01 }) {
                self.zoomFactor = min(max(self.zoomFactor, caps.minZoom), caps.maxZoom)
            }
        }
    }

    // MARK: - Zoom & lens

    func setZoom(_ factor: CGFloat) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoDeviceInput?.device else { return }
            let clamped = min(max(factor, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
            device.videoZoomFactor = clamped
            DispatchQueue.main.async { self.zoomFactor = clamped }
        }
    }

    func selectLens(_ lens: ZoomLens) {
        setZoom(lens.factor)
    }

    // MARK: - Camera switching

    func switchCamera() {
        let newPosition: AVCaptureDevice.Position = cameraPosition == .back ? .front : .back
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            if let input = self.videoDeviceInput {
                self.session.removeInput(input)
                self.videoDeviceInput = nil
            }
            guard let device = Self.bestDevice(for: newPosition) else {
                self.session.commitConfiguration()
                self.publishError("カメラを切り替えられませんでした。")
                return
            }
            do {
                let input = try AVCaptureDeviceInput(device: device)
                if self.session.canAddInput(input) {
                    self.session.addInput(input)
                    self.videoDeviceInput = input
                }
            } catch {
                self.session.commitConfiguration()
                self.publishError("カメラの切り替えに失敗しました：\(error.localizedDescription)")
                return
            }
            self.session.commitConfiguration()
            self.configureConnections()
            self.refreshCapabilities()
            DispatchQueue.main.async {
                self.cameraPosition = newPosition
                self.zoomFactor = 1.0
            }
            self.applyExposureConfiguration()
            self.applyFocusConfiguration()
            self.applyWhiteBalanceConfiguration()
        }
    }

    // MARK: - Exposure control

    private func applyExposureConfiguration() {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoDeviceInput?.device else { return }
            try? device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            if self.isAELocked {
                device.exposureMode = .locked
                return
            }

            if self.isManualISOEnabled || self.isManualShutterEnabled {
                let iso = self.isManualISOEnabled
                    ? min(max(self.manualISO, device.activeFormat.minISO), device.activeFormat.maxISO)
                    : device.iso
                let shutter = self.isManualShutterEnabled ? self.manualShutterSeconds : CMTimeGetSeconds(device.exposureDuration)
                let duration = CMTime(seconds: shutter, preferredTimescale: 1_000_000_000)
                device.setExposureModeCustom(duration: duration, iso: iso, completionHandler: nil)
            } else {
                if device.exposureMode != .continuousAutoExposure {
                    device.exposureMode = .continuousAutoExposure
                }
                device.setExposureTargetBias(self.exposureBias, completionHandler: nil)
            }
        }
    }

    // MARK: - Focus control

    private func applyFocusConfiguration() {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoDeviceInput?.device else { return }
            try? device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            if self.isAFLocked {
                device.focusMode = .locked
                return
            }

            if self.isManualFocusEnabled {
                let position = min(max(self.manualFocusPosition, 0), 1)
                device.setFocusModeLocked(lensPosition: position, completionHandler: nil)
            } else if device.focusMode != .continuousAutoFocus {
                device.focusMode = .continuousAutoFocus
            }
        }
    }

    /// プレビュー上のタップ位置（ビュー座標）をデバイス座標に変えてフォーカス / 露出を決める。
    func focus(atViewPoint point: CGPoint, viewBounds: CGRect) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoDeviceInput?.device else { return }
            let devicePoint = self.devicePoint(fromViewPoint: point, viewBounds: viewBounds)

            try? device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            if device.isFocusPointOfInterestSupported && !self.isAFLocked && !self.isManualFocusEnabled {
                device.focusPointOfInterest = devicePoint
                device.focusMode = .autoFocus
            }
            if device.isExposurePointOfInterestSupported && !self.isAELocked && !self.isManualISOEnabled && !self.isManualShutterEnabled {
                device.exposurePointOfInterest = devicePoint
                device.exposureMode = .continuousAutoExposure
            }
            DispatchQueue.main.async {
                self.focusPoint = point
                // レティクルは 2 秒後に自動で消える
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    if self.focusPoint == point {
                        self.focusPoint = nil
                    }
                }
            }
        }
    }

    func clearFocusIndicator() {
        DispatchQueue.main.async { self.focusPoint = nil }
    }

    private func devicePoint(fromViewPoint point: CGPoint, viewBounds: CGRect) -> CGPoint {
        conversionLayer.frame = viewBounds
        return conversionLayer.captureDevicePointConverted(fromLayerPoint: point)
    }

    // MARK: - White balance

    private func applyWhiteBalanceConfiguration() {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoDeviceInput?.device else { return }
            try? device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            if self.isManualWhiteBalanceEnabled && device.isWhiteBalanceModeSupported(.locked) {
                let temperatureAndTint = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
                    temperature: Float(min(max(self.whiteBalanceKelvin, 2000), 10000)),
                    tint: Float(min(max(self.whiteBalanceTint, -150), 150))
                )
                // 色温度 / ティント → 色度 → WB ゲイン に変換してロックする
                let chromaticity = device.chromaticityValues(for: temperatureAndTint)
                var gains = device.whiteBalanceGains(for: chromaticity)
                let maxGain = max(device.maxWhiteBalanceGain, 1.0)
                gains.redPower = min(max(gains.redPower, 1.0), maxGain)
                gains.greenPower = min(max(gains.greenPower, 1.0), maxGain)
                gains.bluePower = min(max(gains.bluePower, 1.0), maxGain)
                device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
            } else if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
        }
    }

    // MARK: - AE / AF lock

    private func applyLockState() {
        applyExposureConfiguration()
        applyFocusConfiguration()
    }

    func toggleAELock() { isAELocked.toggle() }
    func toggleAFLock() { isAFLocked.toggle() }

    // MARK: - Style (color pipeline input)

    func updateStyle(_ newStyle: RenderStyle) {
        styleLock.lock()
        style = newStyle
        styleLock.unlock()
    }

    private func currentStyleLocked() -> RenderStyle {
        styleLock.lock()
        defer { styleLock.unlock() }
        return style
    }

    func updateAnalysisSettings(zebraEnabled: Bool, peakEnabled: Bool, zebraThreshold: Double, peakThreshold: Double) {
        analyzer.zebraEnabled = zebraEnabled
        analyzer.peakEnabled = peakEnabled
        analyzer.zebraThreshold = zebraThreshold
        analyzer.peakThreshold = peakThreshold
    }

    // MARK: - Capture

    /// 通常の写真撮影。RAW / ProRAW を含むすべてのフォーマットに対応する。
    func capturePhoto(fileFormat: PhotoFileFormat,
                      flashMode: FlashModeSetting,
                      completion: @escaping (Result<PhotoCaptureProcessor.CaptureOutput, Error>) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.session.isRunning else {
                DispatchQueue.main.async {
                    completion(.failure(PhotoCaptureProcessor.CaptureError.noImageData))
                }
                return
            }

            let snapshot = self.currentSnapshotLocked()
            let style = self.currentStyleLocked()
            let resolvedFormat = self.resolvedCaptureFormat(fileFormat)

            guard let settings = self.makePhotoSettings(for: resolvedFormat, flashMode: flashMode) else {
                DispatchQueue.main.async {
                    completion(.failure(PhotoCaptureProcessor.CaptureError.noImageData))
                }
                return
            }

            let processor = PhotoCaptureProcessor(
                format: resolvedFormat,
                style: style,
                snapshot: snapshot,
                processingQueue: self.processingQueue
            ) { [weak self] result in
                self?.sessionQueue.async {
                    self?.activeProcessors.removeValue(forKey: settings.uniqueID)
                }
                completion(result)
            }
            if resolvedFormat == .proRaw, let rawType = self.rawPixelFormat(for: resolvedFormat) {
                processor.noteRawPixelFormat(rawType)
            } else if resolvedFormat == .raw, let rawType = self.rawPixelFormat(for: resolvedFormat) {
                processor.noteRawPixelFormat(rawType)
            }

            self.activeProcessors[settings.uniqueID] = processor
            self.photoOutput.capturePhoto(with: settings, delegate: processor)
        }
    }

    /// サイレント撮影（映像ストリームからのフレーム保存）。利用不可の地域では呼んではならない。
    func captureSilentFrame(completion: @escaping (Result<PhotoCaptureProcessor.CaptureOutput, Error>) -> Void) {
        guard Self.isSilentCaptureAvailable else {
            DispatchQueue.main.async {
                completion(.failure(PhotoCaptureProcessor.CaptureError.noImageData))
            }
            return
        }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let request = SilentRequest(
                style: self.currentStyleLocked(),
                snapshot: self.currentSnapshotLocked(),
                completion: completion
            )
            self.renderQueue.async {
                self.pendingSilentRequest = request
            }
        }
    }

    private func resolvedCaptureFormat(_ requested: PhotoFileFormat) -> PhotoFileFormat {
        if requested.isRaw && photoOutput.availableRawPhotoPixelFormatTypes.isEmpty {
            return .heif
        }
        return requested
    }

    private func makePhotoSettings(for format: PhotoFileFormat, flashMode: FlashModeSetting) -> AVCapturePhotoSettings? {
        let settings: AVCapturePhotoSettings

        if format.isRaw, let rawType = rawPixelFormat(for: format) {
            if format == .proRaw {
                photoOutput.isAppleProRAWEnabled = true
            }
            settings = AVCapturePhotoSettings(
                rawPixelFormatType: rawType,
                processedFormat: [AVVideoCodecKey: AVVideoCodecType.jpeg]
            )
        } else {
            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
            settings.isHighResolutionPhotoEnabled = true
        }

        settings.photoQualityPrioritization = .quality
        if videoDeviceInput?.device.hasFlash == true {
            settings.flashMode = flashMode.avFlashMode
        }
        return settings
    }

    /// 'prog' — kCVPixelFormatTypeType_ProRAW。CoreVideo の定数名が SDK に依存しないよう独自定義している。
    private static let proRAWPixelFormat: OSType = 0x7072_6F67 // 'prog'

    private func rawPixelFormat(for format: PhotoFileFormat) -> OSType? {
        let types = photoOutput.availableRawPhotoPixelFormatTypes
        guard !types.isEmpty else { return nil }
        if format == .proRaw {
            return types.first(where: { $0 == Self.proRAWPixelFormat }) ?? types.first
        }
        return types.first(where: { $0 != Self.proRAWPixelFormat }) ?? types.first
    }

    private func currentSnapshotLocked() -> CaptureSnapshot {
        let device = videoDeviceInput?.device
        let lensTitle = String(format: "%.1f×", device?.videoZoomFactor ?? 1.0)
        return CaptureSnapshot(
            iso: device?.iso ?? 0,
            shutterSeconds: CMTimeGetSeconds(device?.exposureDuration ?? CMTime.invalid),
            exposureBias: device?.exposureTargetBias ?? 0,
            lensTitle: lensTitle,
            zoomFactor: Double(device?.videoZoomFactor ?? 1.0),
            kelvin: isManualWhiteBalanceEnabled ? whiteBalanceKelvin : 0,
            tint: isManualWhiteBalanceEnabled ? whiteBalanceTint : 0,
            focusPosition: Double(device?.lensPosition ?? 0),
            deviceName: device?.localizedName ?? "Camera"
        )
    }

    // MARK: - Live values

    private func startLiveValuesTimer() {
        liveValuesTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: sessionQueue)
        timer.schedule(deadline: .now(), repeating: 0.25)
        timer.setEventHandler { [weak self] in
            guard let self, let device = self.videoDeviceInput?.device else { return }
            let iso = device.iso
            let shutter = CMTimeGetSeconds(device.exposureDuration)
            let lens = device.lensPosition
            let bias = device.exposureTargetBias
            let adjustingExposure = device.isAdjustingExposure
            let adjustingFocus = device.isAdjustingFocus
            let adjustingWB = device.isAdjustingWhiteBalance
            DispatchQueue.main.async {
                self.liveISO = iso
                self.liveShutterSeconds = shutter
                self.liveLensPosition = lens
                self.liveExposureBias = bias
                self.isAdjustingExposure = adjustingExposure
                self.isAdjustingFocus = adjustingFocus
                self.isAdjustingWhiteBalance = adjustingWB
            }
        }
        timer.resume()
        liveValuesTimer = timer
    }

    // MARK: - Errors & interruptions

    private func publishError(_ message: String) {
        DispatchQueue.main.async { self.errorMessage = message }
    }

    func clearError() {
        DispatchQueue.main.async { self.errorMessage = nil }
    }

    @objc private func sessionWasInterrupted(_ notification: Notification) {
        publishError("撮影が一時中断されました。他のアプリがカメラを使用している可能性があります。")
        DispatchQueue.main.async { self.isSessionRunning = false }
    }

    @objc private func sessionInterruptionEnded(_ notification: Notification) {
        sessionQueue.async { [weak self] in
            self?.startRunningLocked()
        }
    }

    @objc private func sessionRuntimeError(_ notification: Notification) {
        if let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError {
            publishError("カメラエラー：\(error.localizedDescription)")
        } else {
            publishError("カメラでエラーが発生しました。")
        }
        sessionQueue.async { [weak self] in
            self?.startRunningLocked()
        }
    }

    @objc private func appDidEnterBackground() {
        stop()
    }

    @objc private func appWillEnterForeground() {
        start()
    }
}

// MARK: - Video frame handling

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // サイレント撮影要求があれば、このフレームを保存用に処理する
        if pendingSilentRequest != nil {
            handleSilentCapture(pixelBuffer: pixelBuffer)
            return
        }

        let now = CACurrentMediaTime()
        guard now - lastFrameTime >= 1.0 / 30.0 else { return }
        lastFrameTime = now

        let input = CIImage(cvPixelBuffer: pixelBuffer)
        let style = currentStyleLocked()

        // プレビューは縮小して処理し、フレームレートと発熱を抑える
        let maxDimension = max(input.extent.width, input.extent.height)
        let targetDimension: CGFloat = 1440
        let scale = maxDimension > targetDimension ? targetDimension / maxDimension : 1.0
        let scaled = scale < 1.0 ? input.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) : input

        let processed = pipeline.outputImage(from: scaled, style: style, resolutionScale: scale)

        // 解析（10Hz）
        var analysisResult: FrameAnalyzer.Result?
        if now - lastAnalysisTime >= 0.1 {
            lastAnalysisTime = now
            let smallWidth: CGFloat = 160
            let smallHeight: CGFloat = 120
            let fit = processed.transformed(by: CGAffineTransform(
                scaleX: smallWidth / max(processed.extent.width, 1),
                y: smallHeight / max(processed.extent.height, 1)
            ))
            if let cg = pipeline.context.createCGImage(fit, from: CGRect(x: 0, y: 0, width: smallWidth, height: smallHeight)) {
                analysisResult = analyzer.analyze(cg)
            }
        }

        let preview = previewView
        DispatchQueue.main.async { [weak self] in
            preview.retain(pixelBuffer)
            preview.presentFrame(processed)
            if let analysisResult {
                self?.analysis = analysisResult
            }
        }
    }

    private func handleSilentCapture(pixelBuffer: CVPixelBuffer) {
        guard let request = pendingSilentRequest else { return }
        pendingSilentRequest = nil

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        processingQueue.async { [weak self] in
            guard let self else { return }
            let input = CIImage(cvPixelBuffer: pixelBuffer)
            let processed = self.pipeline.outputImage(from: input, style: request.style, resolutionScale: 1.0)

            do {
                guard let cg = ImageExporter.render(processed, context: self.pipeline.context) else {
                    throw PhotoCaptureProcessor.CaptureError.noImageData
                }
                let metadata = ImageExporter.metadataDictionary(from: nil, style: request.style,
                                                                snapshot: request.snapshot, date: Date())
                guard let data = ImageExporter.exportProcessed(cg, format: .heif, metadata: metadata) else {
                    throw PhotoCaptureProcessor.CaptureError.noImageData
                }

                var record = CaptureRecord(
                    id: UUID().uuidString,
                    date: Date(),
                    fileFormat: "HEIF（サイレント）",
                    lookName: request.style.lookIntensity > 0.001 ? request.style.look.name : "なし",
                    lookIntensity: request.style.lookIntensity,
                    iso: request.snapshot.iso,
                    shutterSeconds: request.snapshot.shutterSeconds,
                    exposureBias: request.snapshot.exposureBias,
                    lensTitle: request.snapshot.lensTitle,
                    zoomFactor: request.snapshot.zoomFactor,
                    kelvin: request.snapshot.kelvin,
                    tint: request.snapshot.tint,
                    focusPosition: request.snapshot.focusPosition,
                    width: width,
                    height: height,
                    isSilent: true,
                    rawPixelFormat: nil,
                    deviceName: request.snapshot.deviceName
                )

                let identifier = try PhotoLibraryService.shared.saveSynchronously(
                    rawData: nil, processedData: data, format: .heif
                )
                record.id = identifier
                CaptureLogStore.shared.add(record)

                let review = ImageExporter.reviewImage(cg).map { UIImage(cgImage: $0) }
                let output = PhotoCaptureProcessor.CaptureOutput(
                    reviewImage: review,
                    localIdentifier: identifier,
                    record: record,
                    usedRawPixelFormat: nil
                )
                DispatchQueue.main.async { request.completion(.success(output)) }
            } catch {
                DispatchQueue.main.async { request.completion(.failure(error)) }
            }
        }
    }
}
