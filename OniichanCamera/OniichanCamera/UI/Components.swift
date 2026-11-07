import SwiftUI
import UIKit

// MARK: - Colors

enum AppColors {
    /// オーバーレイ（ガイド・数値）の色
    static func overlay(_ name: String) -> Color {
        switch name {
        case "amber": return Color(red: 1.0, green: 0.72, blue: 0.25)
        case "cyan": return Color(red: 0.35, green: 0.85, blue: 0.95)
        default: return .white
        }
    }
}

// MARK: - Panel styling

struct PanelBackground: ViewModifier {
    var cornerRadius: CGFloat = 14

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
            )
    }
}

extension View {
    func panelBackground(cornerRadius: CGFloat = 14) -> some View {
        modifier(PanelBackground(cornerRadius: cornerRadius))
    }
}

// MARK: - Icon button

struct IconButton: View {
    let systemName: String
    var isActive: Bool = false
    var size: CGFloat = 38
    var action: () -> Void

    var body: some View {
        Button(action: {
            Haptics.light()
            action()
        }) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.42, weight: .medium))
                .foregroundStyle(isActive ? Color.black : Color.white.opacity(0.92))
                .frame(width: size, height: size)
                .background(
                    Circle().fill(isActive ? Color.white : Color.white.opacity(0.14))
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Continuous slider

/// 数値を確認しながら操作できる水平スライダー（カメラ機材のダイヤルに近い感覚）。
struct ValueSlider: View {
    let title: String
    let valueText: String
    let range: ClosedRange<Double>
    @Binding var value: Double
    var step: Double = 0
    var onEditingChanged: (Bool) -> Void = { _ in }
    var onReset: (() -> Void)? = nil

    @State private var isDragging = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.65))
                Spacer()
                Text(valueText)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.95))
                    .monospacedDigit()
            }
            GeometryReader { geo in
                let width = geo.size.width
                let fraction = CGFloat((value - range.lowerBound) / max(range.upperBound - range.lowerBound, 0.00001))
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.16))
                        .frame(height: 4)
                    Capsule()
                        .fill(Color.white.opacity(0.85))
                        .frame(width: max(4, width * fraction), height: 4)
                    Circle()
                        .fill(Color.white)
                        .frame(width: isDragging ? 20 : 16, height: isDragging ? 20 : 16)
                        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                        .offset(x: max(0, min(width - 16, width * fraction - 8)))
                }
                .frame(height: 28)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { gesture in
                            if !isDragging {
                                isDragging = true
                                onEditingChanged(true)
                            }
                            let fraction = min(max(gesture.location.x / max(width, 1), 0), 1)
                            var newValue = range.lowerBound + Double(fraction) * (range.upperBound - range.lowerBound)
                            if step > 0 {
                                newValue = (newValue / step).rounded() * step
                            }
                            value = min(max(newValue, range.lowerBound), range.upperBound)
                        }
                        .onEnded { _ in
                            isDragging = false
                            onEditingChanged(false)
                        }
                )
                .onTapGesture(count: 2) {
                    onReset?()
                }
            }
            .frame(height: 28)
        }
    }
}

// MARK: - Discrete slider

/// ISO / シャッタースピードのように離散値を選ぶスライダー。
struct DiscreteValueSlider: View {
    let title: String
    let displayText: String
    let itemCount: Int
    @Binding var index: Int
    var onEditingChanged: (Bool) -> Void = { _ in }

    @State private var isDragging = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.65))
                Spacer()
                Text(displayText)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.95))
                    .monospacedDigit()
            }
            GeometryReader { geo in
                let width = geo.size.width
                let fraction = itemCount > 1 ? CGFloat(index) / CGFloat(itemCount - 1) : 0
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.16))
                        .frame(height: 4)
                    Capsule()
                        .fill(Color.white.opacity(0.85))
                        .frame(width: max(4, width * fraction), height: 4)
                    Circle()
                        .fill(Color.white)
                        .frame(width: isDragging ? 20 : 16, height: isDragging ? 20 : 16)
                        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                        .offset(x: max(0, min(width - 16, width * fraction - 8)))
                }
                .frame(height: 28)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { gesture in
                            if !isDragging {
                                isDragging = true
                                onEditingChanged(true)
                            }
                            let fraction = min(max(gesture.location.x / max(width, 1), 0), 1)
                            let newIndex = Int((fraction * CGFloat(max(itemCount - 1, 1))).rounded())
                            if newIndex != index {
                                Haptics.selection()
                                index = newIndex
                            }
                        }
                        .onEnded { _ in
                            isDragging = false
                            onEditingChanged(false)
                        }
                )
            }
            .frame(height: 28)
        }
    }
}

// MARK: - Tool toggle chip

struct ToolChip: View {
    let systemName: String
    let title: String
    let isOn: Bool
    var action: () -> Void

    var body: some View {
        Button(action: {
            Haptics.selection()
            action()
        }) {
            HStack(spacing: 5) {
                Image(systemName: systemName)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .foregroundStyle(isOn ? Color.black : Color.white.opacity(0.85))
            .background(
                Capsule().fill(isOn ? Color.white : Color.white.opacity(0.13))
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Section container for panels

struct PanelSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
                .textCase(.uppercase)
            content
        }
    }
}

// MARK: - Toast

struct ToastMessage: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let isError: Bool
}

struct ToastView: View {
    let message: ToastMessage

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: message.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(message.isError ? Color.orange : Color.green)
            Text(message.text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .panelBackground(cornerRadius: 22)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

// MARK: - Share sheet

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Formatting helpers

enum Format {
    static func iso(_ value: Float) -> String {
        value >= 10 ? "ISO \(Int(value.rounded()))" : String(format: "ISO %.0f", value)
    }

    static func shutter(_ seconds: Double) -> String {
        seconds > 0 ? ShutterSpeed.displayString(seconds: seconds) : "—"
    }

    static func ev(_ value: Float) -> String {
        String(format: "%+.1f EV", value)
    }

    static func kelvin(_ value: Double) -> String {
        "\(Int(value.rounded())) K"
    }

    static func zoom(_ value: CGFloat) -> String {
        String(format: "%.1f×", value)
    }
}
