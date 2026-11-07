import CoreImage
import SwiftUI
import UIKit

/// カラールックの選択画面。
/// 各ルックは合成テストチャート（階調・肌・空・植物の色）を通して実際の
/// カラーパイプラインでプレビューされる。
struct LookPickerView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @State private var intensity: Double = 1.0

    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("ルック強度")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.8))
                            Spacer()
                            Text("\(Int((intensity * 100).rounded()))%")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .monospacedDigit()
                        }
                        ValueSlider(
                            title: "",
                            valueText: "",
                            range: 0...1,
                            value: $intensity
                        )
                    }
                    .padding(16)
                    .panelBackground()

                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(LookCatalog.all) { look in
                            LookCard(
                                look: look,
                                isSelected: settings.lookID == look.id,
                                intensity: intensity
                            ) {
                                settings.lookID = look.id
                                settings.lookIntensity = intensity
                                Haptics.selection()
                            }
                        }
                    }
                    .padding(.horizontal, 16)

                    Text("ルックは階調・色相・彩度・粒子・周辺光量をまとめて設計した 3D LUT として処理されます。撮影プレビューと保存写真の両方に同じ処理が適用されます。")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.horizontal, 18)
                        .padding(.bottom, 24)
                }
                .padding(.top, 16)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("カラールック")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完了") { dismiss() }
                        .foregroundStyle(Color.yellow)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            intensity = settings.lookIntensity
        }
        .onDisappear {
            settings.lookIntensity = intensity
        }
    }
}

// MARK: - Look card

private struct LookCard: View {
    let look: LookRecipe
    let isSelected: Bool
    let intensity: Double
    let action: () -> Void

    @State private var thumbnail: UIImage?

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                        .aspectRatio(4.0 / 3.0, contentMode: .fit)
                    if let thumbnail {
                        Image(uiImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                            .frame(minWidth: 0, maxWidth: .infinity)
                            .aspectRatio(4.0 / 3.0, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(isSelected ? Color.yellow : Color.white.opacity(0.12),
                                      lineWidth: isSelected ? 2 : 0.5)
                )

                Text(look.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text(look.summary)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(2, reservesSpace: true)
            }
        }
        .buttonStyle(.plain)
        .onAppear { render() }
        .onChange(of: intensity) { _, _ in render() }
    }

    private func render() {
        let style = RenderStyle(look: look, lookIntensity: intensity, adjustments: .neutral, lut: nil)
        LookThumbnailRenderer.shared.image(for: style) { image in
            thumbnail = image
        }
    }
}

// MARK: - Thumbnail rendering

/// 合成チャートにルックを適用したサムネイルを生成する（キャッシュ付き）。
final class LookThumbnailRenderer {
    static let shared = LookThumbnailRenderer()

    private let queue = DispatchQueue(label: "jp.oniichan.camera.lookthumb", qos: .userInitiated)
    private var cache: [String: UIImage] = [:]

    func image(for style: RenderStyle, completion: @escaping (UIImage?) -> Void) {
        let key = "\(style.look.id)-\(Int((style.lookIntensity * 100).rounded()))"
        queue.async {
            if let cached = self.cache[key] {
                DispatchQueue.main.async { completion(cached) }
                return
            }
            let chart = Self.testChartImage()
            let ciImage = CIImage(image: chart) ?? CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 320, height: 240))
            let processed = ColorPipeline.shared.outputImage(from: ciImage, style: style, resolutionScale: 1.0)
            var result: UIImage?
            if let cg = ImageExporter.render(processed, context: ColorPipeline.shared.context),
               let scaled = ImageExporter.reviewImage(cg, maxDimension: 320) {
                result = UIImage(cgImage: scaled)
            }
            if let result {
                self.cache[key] = result
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// 階調・肌・空・植物・暖色・寒色を含む合成テストチャート
    static func testChartImage(size: CGSize = CGSize(width: 320, height: 240)) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            let cg = context.cgContext

            // 階調（黒 → 白）
            let colors = [UIColor.black.cgColor, UIColor.white.cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                cg.drawLinearGradient(gradient,
                                      start: CGPoint(x: 0, y: 0),
                                      end: CGPoint(x: size.width, y: 0),
                                      options: [])
            }

            // 色パッチ
            let patches: [(UIColor, CGRect)] = [
                (UIColor(red: 0.87, green: 0.68, blue: 0.55, alpha: 1), CGRect(x: 0, y: 0, width: size.width / 5, height: size.height)),
                (UIColor(red: 0.35, green: 0.55, blue: 0.85, alpha: 1), CGRect(x: size.width / 5, y: 0, width: size.width / 5, height: size.height)),
                (UIColor(red: 0.30, green: 0.55, blue: 0.28, alpha: 1), CGRect(x: size.width * 2 / 5, y: 0, width: size.width / 5, height: size.height)),
                (UIColor(red: 0.80, green: 0.22, blue: 0.18, alpha: 1), CGRect(x: size.width * 3 / 5, y: 0, width: size.width / 5, height: size.height)),
                (UIColor(red: 0.92, green: 0.78, blue: 0.30, alpha: 1), CGRect(x: size.width * 4 / 5, y: 0, width: size.width / 5, height: size.height)),
            ]
            for (color, rect) in patches {
                cg.setFillColor(color.cgColor)
                cg.fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height * 0.55))
            }

            // 下部は階調のまま残す（トーンの確認用）
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                cg.drawLinearGradient(gradient,
                                      start: CGPoint(x: 0, y: size.height),
                                      end: CGPoint(x: size.width, y: size.height),
                                      options: .drawsBeforeStartLocation)
            }
        }
    }
}
