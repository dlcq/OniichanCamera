import AVFoundation
import SwiftUI
import UIKit

/// メインの撮影画面。
/// プビューを最大限広く確保し、操作は下端と上端に集約する。
struct CameraView: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var controller = CameraController()
    @StateObject private var monitor = HorizonMonitor()

    // UI 状態
    @State private var showSettings = false
    @State private var showLookPicker = false
    @State private var showAdjustments = false
    @State private var showProPanel = false
    @State private var reviewOutput: PhotoCaptureProcessor.CaptureOutput?
    @State private var thumbnailImage: UIImage?
    @State private var toast: ToastMessage?
    @State private var countdownValue: Int?
    @State private var burstRemaining: Int?
    @State private var isCapturing = false
    @State private var flashVisible = false
    @State private var pinchStartZoom: CGFloat?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                previewLayer(size: geo.size)

                ViewfinderOverlay(
                    analysis: controller.analysis,
                    focusPoint: controller.focusPoint,
                    monitor: monitor
                )

                if settings.showsHistogram {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            HistogramView(data: controller.analysis.histogram)
                                .frame(width: 132, height: 84)
                                .padding(.trailing, 16)
                        }
                    }
                    .padding(.bottom, 240)
                }

                controlsOverlay(size: geo.size)

                if flashVisible {
                    Color.white.opacity(0.28)
                        .ignoresSafeArea()
                        .transition(.opacity)
                }

                if let countdownValue {
                    CountdownOverlay(value: countdownValue)
                }

                if let burstRemaining {
                    BurstIndicator(remaining: burstRemaining, total: settings.burstCount)
                }

                if let toast {
                    VStack {
                        ToastView(message: toast)
                            .padding(.top, 12)
                        Spacer()
                    }
                    .transition(.opacity)
                }
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            Haptics.setEnabled(settings.hapticsEnabled)
            UIApplication.shared.isIdleTimerDisabled = settings.keepsScreenAwake
            controller.updateStyle(settings.currentStyle())
            controller.updateAnalysisSettings(
                zebraEnabled: settings.showsZebra,
                peakEnabled: settings.showsFocusPeaking,
                zebraThreshold: settings.zebraThreshold,
                peakThreshold: settings.peakingThreshold
            )
            controller.start()
            monitor.start()
            PhotoLibraryService.shared.requestReadAccess { _ in
                refreshThumbnail()
            }
        }
        .onDisappear {
            controller.stop()
            monitor.stop()
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onChange(of: settings.lookID) { _, _ in syncStyle() }
        .onChange(of: settings.lookIntensity) { _, _ in syncStyle() }
        .onChange(of: settings.adjustments) { _, _ in syncStyle() }
        .onChange(of: settings.lutFileName) { _, _ in syncStyle() }
        .onChange(of: settings.showsZebra) { _, _ in syncAnalysis() }
        .onChange(of: settings.showsFocusPeaking) { _, _ in syncAnalysis() }
        .onChange(of: settings.zebraThreshold) { _, _ in syncAnalysis() }
        .onChange(of: settings.peakingThreshold) { _, _ in syncAnalysis() }
        .onChange(of: settings.hapticsEnabled) { _, newValue in Haptics.setEnabled(newValue) }
        .onChange(of: settings.keepsScreenAwake) { _, newValue in
            UIApplication.shared.isIdleTimerDisabled = newValue
        }
        .onChange(of: controller.errorMessage) { _, message in
            if let message {
                showToast(message, isError: true)
                controller.clearError()
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(capabilities: controller.capabilities).environmentObject(settings)
        }
        .sheet(isPresented: $showLookPicker) {
            LookPickerView().environmentObject(settings)
        }
        .sheet(isPresented: $showAdjustments) {
            AdjustmentsView().environmentObject(settings)
        }
        .fullScreenCover(item: $reviewOutput) { output in
            PhotoReviewView(output: output) {
                reviewOutput = nil
                refreshThumbnail()
            }
            .environmentObject(settings)
        }
    }

    // MARK: - Preview

    private func previewLayer(size: CGSize) -> some View {
        ZStack {
            CameraPreviewView(view: controller.previewView)
                .ignoresSafeArea()
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .gesture(
            SpatialTapGesture()
                .onEnded { value in
                    controller.focus(atViewPoint: value.location,
                                     viewBounds: CGRect(origin: .zero, size: size))
                    Haptics.light()
                }
        )
        .simultaneousGesture(
            MagnificationGesture()
                .onChanged { scale in
                    if pinchStartZoom == nil {
                        pinchStartZoom = controller.zoomFactor
                    }
                    let base = pinchStartZoom ?? controller.zoomFactor
                    controller.setZoom(base * scale)
                }
                .onEnded { _ in
                    pinchStartZoom = nil
                }
        )
    }

    // MARK: - Controls

    private func controlsOverlay(size: CGSize) -> some View {
        VStack(spacing: 0) {
            topBar
            Spacer()
            if showProPanel && settings.captureMode == .pro {
                ProPanelView(controller: controller)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            toolsStrip
            lensZoomRow
            modeRow
            shutterRow
                .padding(.bottom, 8)
        }
        .animation(.easeInOut(duration: 0.22), value: showProPanel)
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            IconButton(systemName: "gearshape") { showSettings = true }
            Spacer()
            Menu {
                ForEach(FlashModeSetting.allCases) { mode in
                    Button {
                        settings.flashMode = mode
                    } label: {
                        Label(mode.title, systemImage: mode.symbol)
                    }
                }
            } label: {
                Image(systemName: settings.flashMode.symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(controller.capabilities.hasFlash ? Color.white : Color.white.opacity(0.35))
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Color.white.opacity(0.14)))
            }
            .disabled(!controller.capabilities.hasFlash)

            Menu {
                ForEach(TimerPreset.allCases.filter { $0 != .custom }) { preset in
                    Button {
                        settings.timerSeconds = preset.rawValue
                        Haptics.selection()
                    } label: {
                        if settings.timerSeconds == preset.rawValue {
                            Label(preset.title, systemImage: "checkmark")
                        } else {
                            Text(preset.title)
                        }
                    }
                }
                Menu("カスタム") {
                    ForEach([1, 2, 5, 7, 10, 15, 20, 30, 45, 60], id: \.self) { seconds in
                        Button {
                            settings.customTimerSeconds = seconds
                            settings.timerSeconds = TimerPreset.custom.rawValue
                            Haptics.selection()
                        } label: {
                            if settings.timerSeconds == TimerPreset.custom.rawValue && settings.customTimerSeconds == seconds {
                                Label("\(seconds) 秒", systemImage: "checkmark")
                            } else {
                                Text("\(seconds) 秒")
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: settings.effectiveTimerSeconds > 0 ? "timer" : "timer.slash")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(settings.effectiveTimerSeconds > 0 ? Color.yellow : Color.white)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Color.white.opacity(0.14)))
            }

            if CameraController.isSilentCaptureAvailable {
                Button {
                    settings.silentCaptureEnabled.toggle()
                    showToast(settings.silentCaptureEnabled ? "サイレント撮影 オン" : "サイレント撮影 オフ",
                              isError: false)
                } label: {
                    Image(systemName: settings.silentCaptureEnabled ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(settings.silentCaptureEnabled ? Color.yellow : Color.white.opacity(0.85))
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(Color.white.opacity(0.14)))
                }
            }

            Menu {
                ForEach(availableFormats) { format in
                    Button {
                        settings.fileFormat = format
                    } label: {
                        Text("\(format.title) — \(format.details)")
                    }
                }
            } label: {
                Text(activeFormatTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(Color.white.opacity(0.14)))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var availableFormats: [PhotoFileFormat] {
        PhotoFileFormat.allCases.filter { format in
            switch format {
            case .raw: return controller.capabilities.supportsRAW
            case .proRaw: return controller.capabilities.supportsProRAW
            default: return true
            }
        }
    }

    private var activeFormatTitle: String {
        let format = settings.fileFormat
        if format.isRaw && !(format == .proRaw ? controller.capabilities.supportsProRAW : controller.capabilities.supportsRAW) {
            return "HEIF"
        }
        return format.shortTitle
    }

    private var toolsStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ToolChip(systemName: "camera.filters", title: settings.currentLook.name, isOn: settings.lookIntensity > 0.001) {
                    showLookPicker = true
                }
                ToolChip(systemName: "slider.horizontal.3", title: "調整", isOn: settings.adjustments.nonNeutralCount > 0) {
                    showAdjustments = true
                }
                ToolChip(systemName: "grid", title: "グリッド", isOn: settings.gridStyle != .off) {
                    cycleGrid()
                }
                ToolChip(systemName: "angle", title: "水平器", isOn: settings.showsLevel) {
                    settings.showsLevel.toggle()
                }
                ToolChip(systemName: "chart.bar", title: "ヒスト", isOn: settings.showsHistogram) {
                    settings.showsHistogram.toggle()
                }
                ToolChip(systemName: "sun.max.trianglebadge.exclamationmark", title: "ゼブラ", isOn: settings.showsZebra) {
                    settings.showsZebra.toggle()
                }
                ToolChip(systemName: "scope", title: "ピーク", isOn: settings.showsFocusPeaking) {
                    settings.showsFocusPeaking.toggle()
                }
                ToolChip(systemName: "rectangle.dashed", title: "ガイド", isOn: settings.aspectGuide != .off) {
                    cycleAspectGuide()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private var lensZoomRow: some View {
        HStack(spacing: 14) {
            ForEach(controller.capabilities.lenses) { lens in
                Button {
                    controller.selectLens(lens)
                    Haptics.selection()
                } label: {
                    Text(lens.title)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(abs(controller.zoomFactor - lens.factor) < 0.05 ? Color.black : Color.white.opacity(0.9))
                        .frame(width: 46, height: 32)
                        .background(
                            Capsule().fill(abs(controller.zoomFactor - lens.factor) < 0.05 ? Color.white : Color.white.opacity(0.13))
                        )
                }
                .buttonStyle(.plain)
            }

            ValueSlider(
                title: "",
                valueText: Format.zoom(controller.zoomFactor),
                range: Double(controller.capabilities.minZoom)...Double(controller.capabilities.maxZoom),
                value: Binding(
                    get: { Double(controller.zoomFactor) },
                    set: { controller.setZoom(CGFloat($0)) }
                )
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private var modeRow: some View {
        HStack(spacing: 18) {
            Spacer()
            ForEach(CaptureMode.allCases) { mode in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        settings.captureMode = mode
                    }
                    Haptics.selection()
                } label: {
                    Text(mode.title)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(settings.captureMode == mode ? Color.yellow : Color.white.opacity(0.55))
                }
                .buttonStyle(.plain)
            }
            Button {
                withAnimation(.easeInOut(duration: 0.22)) {
                    showProPanel.toggle()
                }
                Haptics.light()
            } label: {
                Image(systemName: "chevron.up.circle")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(showProPanel ? Color.yellow : Color.white.opacity(0.55))
                    .rotationEffect(.degrees(showProPanel ? 180 : 0))
            }
            .buttonStyle(.plain)
            .opacity(settings.captureMode == .pro ? 1 : 0.25)
            .disabled(settings.captureMode != .pro)
            Spacer()
        }
        .padding(.vertical, 6)
    }

    private var shutterRow: some View {
        HStack {
            Button {
                showLatestReview()
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.12))
                        .frame(width: 52, height: 52)
                    if let thumbnailImage {
                        Image(uiImage: thumbnailImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 52, height: 52)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    } else {
                        Image(systemName: "photo.on.rectangle")
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
            .buttonStyle(.plain)

            Spacer()

            ShutterButton(isEnabled: !isCapturing) {
                performCapture()
            }

            Spacer()

            IconButton(systemName: "arrow.triangle.2.circlepath.camera", size: 44) {
                controller.switchCamera()
            }
        }
        .padding(.horizontal, 28)
    }

    // MARK: - Capture flow

    private func performCapture() {
        guard !isCapturing else { return }
        isCapturing = true
        Haptics.light()

        let seconds = settings.effectiveTimerSeconds
        if seconds > 0 {
            runCountdown(seconds: seconds) {
                startShooting()
            }
        } else {
            startShooting()
        }
    }

    private func runCountdown(seconds: Int, completion: @escaping () -> Void) {
        countdownValue = seconds
        Haptics.light()
        func tick(_ remaining: Int) {
            guard remaining > 0 else {
                countdownValue = nil
                completion()
                return
            }
            countdownValue = remaining
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                Haptics.light()
                tick(remaining - 1)
            }
        }
        tick(seconds)
    }

    private func startShooting() {
        if settings.isBurstEnabled {
            let total = settings.burstCount
            burstRemaining = total
            shootBurst(index: 0, total: total)
        } else {
            captureSingle { _ in
                isCapturing = false
            }
        }
    }

    private func shootBurst(index: Int, total: Int) {
        guard index < total else {
            burstRemaining = nil
            isCapturing = false
            showToast("\(total) 枚の連写撮影が完了しました", isError: false)
            return
        }
        captureSingle { success in
            burstRemaining = total - index - 1
            if success {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                    shootBurst(index: index + 1, total: total)
                }
            } else {
                burstRemaining = nil
                isCapturing = false
            }
        }
    }

    private func captureSingle(completion: @escaping (Bool) -> Void) {
        Haptics.shutter()
        withAnimation(.easeOut(duration: 0.12)) { flashVisible = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            withAnimation(.easeIn(duration: 0.18)) { flashVisible = false }
        }

        let style = settings.currentStyle()
        controller.updateStyle(style)

        let finish: (Result<PhotoCaptureProcessor.CaptureOutput, Error>) -> Void = { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let output):
                    if let image = output.reviewImage {
                        thumbnailImage = image
                    }
                    if settings.showsCaptureReview && !settings.isBurstEnabled {
                        reviewOutput = output
                    }
                    refreshThumbnail()
                    completion(true)
                case .failure(let error):
                    showToast(error.localizedDescription, isError: true)
                    Haptics.warning()
                    completion(false)
                }
            }
        }

        if settings.silentCaptureEnabled && CameraController.isSilentCaptureAvailable {
            controller.captureSilentFrame(completion: finish)
        } else {
            controller.capturePhoto(fileFormat: settings.fileFormat,
                                    flashMode: settings.flashMode,
                                    completion: finish)
        }
    }

    // MARK: - Helpers

    private func syncStyle() {
        controller.updateStyle(settings.currentStyle())
    }

    private func syncAnalysis() {
        controller.updateAnalysisSettings(
            zebraEnabled: settings.showsZebra,
            peakEnabled: settings.showsFocusPeaking,
            zebraThreshold: settings.zebraThreshold,
            peakThreshold: settings.peakingThreshold
        )
    }

    private func showToast(_ text: String, isError: Bool) {
        let message = ToastMessage(text: text, isError: isError)
        withAnimation { toast = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
            if toast == message {
                withAnimation { toast = nil }
            }
        }
    }

    private func refreshThumbnail() {
        guard let asset = PhotoLibraryService.shared.latestAsset() else { return }
        PhotoLibraryService.shared.requestThumbnail(for: asset, targetSize: CGSize(width: 160, height: 160)) { image in
            if let image {
                thumbnailImage = image
            }
        }
    }

    private func showLatestReview() {
        guard let asset = PhotoLibraryService.shared.latestAsset() else {
            showToast("写真がまだありません", isError: false)
            return
        }
        PhotoLibraryService.shared.requestImage(for: asset, targetSize: CGSize(width: 1600, height: 1600)) { image in
            guard let image else { return }
            let record = CaptureLogStore.shared.record(forLocalIdentifier: asset.localIdentifier)
                ?? CaptureRecord(
                    id: asset.localIdentifier,
                    date: asset.creationDate ?? Date(),
                    fileFormat: "—",
                    lookName: "—",
                    lookIntensity: 0,
                    iso: 0,
                    shutterSeconds: 0,
                    exposureBias: 0,
                    lensTitle: "—",
                    zoomFactor: 0,
                    kelvin: 0,
                    tint: 0,
                    focusPosition: 0,
                    width: Int(asset.pixelWidth),
                    height: Int(asset.pixelHeight),
                    isSilent: false,
                    rawPixelFormat: nil,
                    deviceName: "—"
                )
            reviewOutput = PhotoCaptureProcessor.CaptureOutput(
                reviewImage: image,
                localIdentifier: asset.localIdentifier,
                record: record,
                usedRawPixelFormat: record.rawPixelFormat
            )
        }
    }

    private func cycleGrid() {
        switch settings.gridStyle {
        case .off: settings.gridStyle = .thirds
        case .thirds: settings.gridStyle = .golden
        case .golden: settings.gridStyle = .centerCross
        case .centerCross: settings.gridStyle = .off
        }
    }

    private func cycleAspectGuide() {
        switch settings.aspectGuide {
        case .off: settings.aspectGuide = .ratio4x3
        case .ratio4x3: settings.aspectGuide = .ratio16x9
        case .ratio16x9: settings.aspectGuide = .ratio1x1
        case .ratio1x1: settings.aspectGuide = .ratio239x1
        case .ratio239x1: settings.aspectGuide = .off
        }
    }
}

// MARK: - Shutter button

struct ShutterButton: View {
    let isEnabled: Bool
    let action: () -> Void

    @State private var isPressed = false

    var body: some View {
        Button {
            action()
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(Color.white.opacity(0.9), lineWidth: 3)
                    .frame(width: 76, height: 76)
                Circle()
                    .fill(Color.white)
                    .frame(width: 62, height: 62)
                    .scaleEffect(isPressed ? 0.88 : 1.0)
            }
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(isPressed ? 0.94 : 1.0)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
        .disabled(!isEnabled)
    }
}

// MARK: - Countdown & burst indicators

struct CountdownOverlay: View {
    let value: Int

    var body: some View {
        ZStack {
            Color.black.opacity(0.28).ignoresSafeArea()
            Text("\(value)")
                .font(.system(size: 110, weight: .thin, design: .rounded))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.35), radius: 12)
                .id(value)
                .transition(.scale.combined(with: .opacity))
        }
        .animation(.easeOut(duration: 0.25), value: value)
    }
}

struct BurstIndicator: View {
    let remaining: Int
    let total: Int

    var body: some View {
        VStack {
            Spacer()
            Text("連写 \(total - remaining)/\(total)")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(Capsule().fill(Color.black.opacity(0.55)))
                .padding(.bottom, 180)
        }
    }
}
