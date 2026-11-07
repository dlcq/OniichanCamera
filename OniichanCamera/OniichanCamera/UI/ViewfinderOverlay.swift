import CoreMotion
import SwiftUI
import UIKit

// MARK: - Horizon monitor (level)

/// Core Motion を使った水平器。デバイスの傾き（ロール）を度で返す。
final class HorizonMonitor: ObservableObject {

    @Published var tiltDegrees: Double = 0
    @Published var isLevel: Bool = false

    private let manager = CMMotionManager()
    private let queue = OperationQueue()

    func start() {
        guard manager.isDeviceMotionAvailable else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 20.0
        manager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: queue) { [weak self] motion, _ in
            guard let self, let motion else { return }
            let gravity = motion.gravity
            // 縦持ちで正面を向けていたとき 0 度になる傾き角
            let tilt = atan2(gravity.x, -gravity.y) * 180.0 / .pi
            let clamped = max(-45, min(45, tilt))
            DispatchQueue.main.async {
                self.tiltDegrees = clamped
                self.isLevel = abs(clamped) < 1.0
            }
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
    }
}

// MARK: - Viewfinder overlays

struct ViewfinderOverlay: View {
    @EnvironmentObject private var settings: AppSettings
    let analysis: FrameAnalyzer.Result
    let focusPoint: CGPoint?
    let monitor: HorizonMonitor

    var body: some View {
        ZStack {
            if settings.showsZebra, let zebra = analysis.zebraImage {
                Image(decorative: zebra, scale: 1)
                    .resizable()
                    .scaledToFill()
                    .opacity(0.55 * settings.overlayOpacity)
                    .allowsHitTesting(false)
            }
            if settings.showsFocusPeaking, let peak = analysis.peakImage {
                Image(decorative: peak, scale: 1)
                    .resizable()
                    .scaledToFill()
                    .opacity(0.6 * settings.overlayOpacity)
                    .allowsHitTesting(false)
            }

            switch settings.gridStyle {
            case .thirds: ThirdsGrid(color: overlayColor, opacity: settings.overlayOpacity)
            case .golden: GoldenGrid(color: overlayColor, opacity: settings.overlayOpacity)
            case .centerCross: CenterCross(color: overlayColor, opacity: settings.overlayOpacity)
            case .off: EmptyView()
            }

            if settings.aspectGuide.ratio != nil {
                AspectGuideFrame(ratio: settings.aspectGuide.ratio ?? 1,
                                 color: overlayColor, opacity: settings.overlayOpacity)
            }

            if settings.showsSafeAreaGuide {
                SafeAreaGuideFrame(color: overlayColor, opacity: settings.overlayOpacity)
            }

            if settings.showsLevel {
                LevelIndicator(monitor: monitor, color: overlayColor, opacity: settings.overlayOpacity)
            }

            if let focusPoint {
                FocusReticle(point: focusPoint, color: overlayColor, opacity: settings.overlayOpacity)
            }
        }
        .allowsHitTesting(false)
    }

    private var overlayColor: Color {
        AppColors.overlay(settings.overlayColorName)
    }
}

// MARK: - Grids

struct ThirdsGrid: View {
    let color: Color
    let opacity: Double

    var body: some View {
        GeometryReader { geo in
            Path { path in
                let w = geo.size.width
                let h = geo.size.height
                for i in 1..<3 {
                    let x = w * CGFloat(i) / 3
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: h))
                    let y = h * CGFloat(i) / 3
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: w, y: y))
                }
            }
            .stroke(color.opacity(0.35 * opacity), lineWidth: 0.5)
        }
    }
}

struct GoldenGrid: View {
    let color: Color
    let opacity: Double

    var body: some View {
        GeometryReader { geo in
            Path { path in
                let w = geo.size.width
                let h = geo.size.height
                let ratio: CGFloat = 0.382
                for fraction in [ratio, 1 - ratio] {
                    let x = w * fraction
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: h))
                    let y = h * fraction
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: w, y: y))
                }
            }
            .stroke(color.opacity(0.32 * opacity), lineWidth: 0.5)
        }
    }
}

struct CenterCross: View {
    let color: Color
    let opacity: Double

    var body: some View {
        GeometryReader { geo in
            Path { path in
                let midX = geo.size.width / 2
                let midY = geo.size.height / 2
                path.move(to: CGPoint(x: midX - 14, y: midY))
                path.addLine(to: CGPoint(x: midX + 14, y: midY))
                path.move(to: CGPoint(x: midX, y: midY - 14))
                path.addLine(to: CGPoint(x: midX, y: midY + 14))
            }
            .stroke(color.opacity(0.6 * opacity), lineWidth: 1)
        }
    }
}

// MARK: - Guides

struct AspectGuideFrame: View {
    let ratio: CGFloat
    let color: Color
    let opacity: Double

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let frameSize = fittingSize(container: CGSize(width: w, height: h), ratio: ratio)
            Rectangle()
                .strokeBorder(color.opacity(0.55 * opacity), style: StrokeStyle(lineWidth: 1, dash: [6, 5]))
                .frame(width: frameSize.width, height: frameSize.height)
                .position(x: w / 2, y: h / 2)
        }
    }

    private func fittingSize(container: CGSize, ratio: CGFloat) -> CGSize {
        // ratio = 幅 / 高さ
        let containerRatio = container.width / max(container.height, 1)
        if containerRatio > ratio {
            let height = container.height * 0.86
            return CGSize(width: height * ratio, height: height)
        } else {
            let width = container.width * 0.86
            return CGSize(width: width, height: width / ratio)
        }
    }
}

struct SafeAreaGuideFrame: View {
    let color: Color
    let opacity: Double

    var body: some View {
        GeometryReader { geo in
            Rectangle()
                .strokeBorder(color.opacity(0.4 * opacity), lineWidth: 0.5)
                .padding(.horizontal, 10)
                .padding(.vertical, 12)
                .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

// MARK: - Level

struct LevelIndicator: View {
    @ObservedObject var monitor: HorizonMonitor
    let color: Color
    let opacity: Double

    var body: some View {
        GeometryReader { geo in
            let midY = geo.size.height / 2
            ZStack {
                Rectangle()
                    .fill(monitor.isLevel ? Color.green : color)
                    .frame(width: 120, height: 2)
                    .rotationEffect(.degrees(-monitor.tiltDegrees))
                    .position(x: geo.size.width / 2, y: midY)
                if monitor.isLevel {
                    Circle()
                        .strokeBorder(Color.green, lineWidth: 1.5)
                        .frame(width: 18, height: 18)
                        .position(x: geo.size.width / 2, y: midY)
                }
            }
            .opacity(0.85 * opacity)
        }
    }
}

// MARK: - Focus reticle

struct FocusReticle: View {
    let point: CGPoint
    let color: Color
    let opacity: Double

    var body: some View {
        Rectangle()
            .strokeBorder(color.opacity(0.9 * opacity), lineWidth: 1.2)
            .frame(width: 78, height: 78)
            .position(point)
            .transition(.opacity)
    }
}

// MARK: - Histogram

struct HistogramView: View {
    let data: HistogramData
    var accent: Color = .white

    var body: some View {
        Canvas { context, size in
            let width = size.width
            let height = size.height
            let maxValue = max(data.maxBin, 1)

            func bars(_ bins: [Int], color: Color, opacity: Double) {
                var path = Path()
                let binWidth = width / CGFloat(HistogramData.binCount)
                for (index, count) in bins.enumerated() {
                    let barHeight = height * CGFloat(count) / CGFloat(maxValue)
                    let x = CGFloat(index) * binWidth
                    path.addRect(CGRect(x: x, y: height - barHeight, width: binWidth, height: barHeight))
                }
                context.fill(path, with: .color(color.opacity(opacity)))
            }

            bars(data.red, color: .red, opacity: 0.45)
            bars(data.green, color: .green, opacity: 0.45)
            bars(data.blue, color: .blue, opacity: 0.45)
            bars(data.luma, color: accent, opacity: 0.55)
        }
        .background(Color.black.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
        )
        .overlay(alignment: .topTrailing) {
            VStack(alignment: .trailing, spacing: 2) {
                if data.clippedHighlightRatio > 0.01 {
                    Label("白飛び", systemImage: "sun.max.fill")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.yellow)
                }
                if data.clippedShadowRatio > 0.02 {
                    Label("黒つぶれ", systemImage: "moon.fill")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.indigo)
                }
            }
            .padding(4)
        }
    }
}
