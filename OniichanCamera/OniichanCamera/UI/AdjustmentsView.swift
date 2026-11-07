import SwiftUI
import UniformTypeIdentifiers

/// 画像調整（詳細）。すべての項目が撮影プレビューと保存写真の両方に反映される。
struct AdjustmentsView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @State private var showImporter = false
    @State private var lutError: String?
    @State private var showLUTError = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    lookSection
                    toneSection
                    colorSection
                    textureSection
                    lutSection

                    Button {
                        settings.resetColorSettings()
                        Haptics.light()
                    } label: {
                        Text("すべての色調整をリセット")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .panelBackground()
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 28)
                }
                .padding(.top, 16)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("画像調整")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完了") { dismiss() }
                        .foregroundStyle(Color.yellow)
                }
            }
        }
        .preferredColorScheme(.dark)
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [UTType(filenameExtension: "cube") ?? .data],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        .alert("LUT の読み込み", isPresented: $showLUTError, actions: {
            Button("OK", role: .cancel) {}
        }, message: {
            Text(lutError ?? "")
        })
    }

    // MARK: - Sections

    private var lookSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("ルック：\(settings.currentLook.name)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                Spacer()
                Text("\(Int((settings.lookIntensity * 100).rounded()))%")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .monospacedDigit()
            }
            ValueSlider(
                title: "ルック強度",
                valueText: "",
                range: 0...1,
                value: $settings.lookIntensity
            )
        }
        .padding(16)
        .panelBackground()
        .padding(.horizontal, 16)
    }

    private var toneSection: some View {
        sectionCard("階調") {
            slider("露出", value: \.exposure, range: -2...2, step: 0.05) {
                String(format: "%+.2f EV", $0)
            }
            slider("コントラスト", value: \.contrast, range: -1...1, step: 0.01) { signedPercent($0) }
            slider("ハイライト", value: \.highlights, range: -1...1, step: 0.01) { signedPercent($0) }
            slider("シャドウ", value: \.shadows, range: -1...1, step: 0.01) { signedPercent($0) }
            slider("フェード", value: \.fade, range: 0...1, step: 0.01) { percent($0) }
        }
    }

    private var colorSection: some View {
        sectionCard("色") {
            slider("彩度", value: \.saturation, range: -1...1, step: 0.01) { signedPercent($0) }
            slider("自然な彩度", value: \.vibrance, range: -1...1, step: 0.01) { signedPercent($0) }
            slider("色温度", value: \.temperature, range: -1...1, step: 0.01) { signedPercent($0) }
            slider("ティント", value: \.tint, range: -1...1, step: 0.01) { signedPercent($0) }
            slider("色相", value: \.hue, range: -1...1, step: 0.01) {
                String(format: "%+.0f°", $0 * 30)
            }
        }
    }

    private var textureSection: some View {
        sectionCard("質感") {
            slider("シャープネス", value: \.sharpness, range: 0...1, step: 0.01) { percent($0) }
            slider("明瞭度", value: \.clarity, range: 0...1, step: 0.01) { percent($0) }
            slider("粒子感", value: \.grain, range: 0...1, step: 0.01) { percent($0) }
            slider("周辺光量", value: \.vignette, range: 0...1, step: 0.01) { percent($0) }
        }
    }

    private var lutSection: some View {
        sectionCard("カスタム LUT") {
            if let lutName = settings.lutFileName {
                HStack {
                    Image(systemName: "cube")
                        .foregroundStyle(.yellow)
                    Text(lutName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                    Spacer()
                    Button("削除") {
                        settings.lutFileName = nil
                        Haptics.light()
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.red)
                }
            } else {
                Text("Impulse LUT（.cube）を読み込むと、保存画像とプレビューの最終段に適用されます。RAW 保存時は DNG には影響しません。")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
            }
            Button {
                showImporter = true
            } label: {
                Text("LUT ファイルを選択")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(Capsule().fill(Color.white))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Builders

    private func sectionCard<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.5))
                .textCase(.uppercase)
            content()
        }
        .padding(16)
        .panelBackground()
        .padding(.horizontal, 16)
    }

    private func slider(
        _ title: String,
        value: WritableKeyPath<ImageAdjustments, Double>,
        range: ClosedRange<Double>,
        step: Double,
        format: @escaping (Double) -> String
    ) -> some View {
        ValueSlider(
            title: title,
            valueText: format(settings.adjustments[keyPath: value]),
            range: range,
            value: Binding(
                get: { settings.adjustments[keyPath: value] },
                set: { settings.adjustments[keyPath: value] = $0 }
            ),
            step: step,
            onReset: {
                settings.adjustments[keyPath: value] = 0
                Haptics.light()
            }
        )
    }

    private func signedPercent(_ value: Double) -> String {
        String(format: "%+.0f%%", value * 100)
    }

    private func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value * 100)
    }

    // MARK: - LUT import

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            lutError = error.localizedDescription
            showLUTError = true
        case .success(let urls):
            guard let url = urls.first else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing { url.stopAccessingSecurityScopedResource() }
            }
            do {
                let lut = try LUTLoader.load(from: url)
                let destination = AppSettings.lutsDirectory.appendingPathComponent("\(lut.name).cube")
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: url, to: destination)
                settings.lutFileName = "\(lut.name).cube"
                Haptics.success()
            } catch {
                lutError = error.localizedDescription
                showLUTError = true
            }
        }
    }
}
