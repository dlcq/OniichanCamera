import AVFoundation
import SwiftUI

/// PRO モードのマニュアル操作パネル。
/// ISO / シャッタースピード / EV / フォーカス / WB を数値で確認しながら調整できる。
struct ProPanelView: View {
    @ObservedObject var controller: CameraController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            exposureSection
            Divider().overlay(Color.white.opacity(0.12))
            focusSection
            Divider().overlay(Color.white.opacity(0.12))
            whiteBalanceSection
        }
        .padding(16)
        .panelBackground(cornerRadius: 18)
    }

    // MARK: - Exposure

    private var exposureSection: some View {
        PanelSection(title: "露出") {
            ToggleRow(
                title: "ISO マニュアル",
                isOn: $controller.isManualISOEnabled
            )
            if controller.isManualISOEnabled {
                DiscreteValueSlider(
                    title: "ISO",
                    displayText: Format.iso(controller.manualISO),
                    itemCount: max(controller.capabilities.isoValues.count, 1),
                    index: Binding(
                        get: { isoIndex },
                        set: { newValue in
                            let values = controller.capabilities.isoValues
                            if values.indices.contains(newValue) {
                                controller.manualISO = values[newValue]
                            }
                        }
                    )
                )
            }

            ToggleRow(
                title: "シャッタースピード マニュアル",
                isOn: $controller.isManualShutterEnabled
            )
            if controller.isManualShutterEnabled {
                DiscreteValueSlider(
                    title: "シャッター",
                    displayText: Format.shutter(controller.manualShutterSeconds),
                    itemCount: max(controller.capabilities.shutterValues.count, 1),
                    index: Binding(
                        get: { shutterIndex },
                        set: { newValue in
                            let values = controller.capabilities.shutterValues
                            if values.indices.contains(newValue) {
                                controller.manualShutterSeconds = values[newValue]
                            }
                        }
                    )
                )
            }

            if !controller.isManualISOEnabled && !controller.isManualShutterEnabled {
                ValueSlider(
                    title: "露出補正",
                    valueText: Format.ev(controller.exposureBias),
                    range: -2...2,
                    value: Binding(
                        get: { Double(controller.exposureBias) },
                        set: { controller.exposureBias = Float($0) }
                    ),
                    step: 0.1
                )
            }

            HStack(spacing: 10) {
                StatusBadge(
                    title: "実測",
                    value: "\(Format.iso(controller.liveISO))  ·  \(Format.shutter(controller.liveShutterSeconds))",
                    isAdjusting: controller.isAdjustingExposure
                )
                Spacer()
            }
        }
    }

    private var isoIndex: Int {
        let values = controller.capabilities.isoValues
        if let exact = values.firstIndex(where: { $0 == controller.manualISO }) {
            return exact
        }
        return values.enumerated().min(by: { abs($0.element - controller.manualISO) < abs($1.element - controller.manualISO) })?.offset ?? 0
    }

    private var shutterIndex: Int {
        let values = controller.capabilities.shutterValues
        if let exact = values.firstIndex(where: { abs($0 - controller.manualShutterSeconds) < 0.000001 }) {
            return exact
        }
        return values.enumerated().min(by: {
            abs($0.element - controller.manualShutterSeconds) < abs($1.element - controller.manualShutterSeconds)
        })?.offset ?? 0
    }

    // MARK: - Focus

    private var focusSection: some View {
        PanelSection(title: "フォーカス") {
            ToggleRow(title: "MF（マニュアルフォーカス）", isOn: $controller.isManualFocusEnabled)
            if controller.isManualFocusEnabled {
                ValueSlider(
                    title: "ピント位置",
                    valueText: String(format: "%.2f", controller.manualFocusPosition),
                    range: 0...1,
                    value: Binding(
                        get: { Double(controller.manualFocusPosition) },
                        set: { controller.manualFocusPosition = Float($0) }
                    )
                )
            } else {
                StatusBadge(
                    title: "AF",
                    value: String(format: "レンズ位置 %.2f", controller.liveLensPosition),
                    isAdjusting: controller.isAdjustingFocus
                )
            }

            HStack(spacing: 10) {
                LockButton(title: "AE ロック", isOn: controller.isAELocked) {
                    controller.toggleAELock()
                }
                LockButton(title: "AF ロック", isOn: controller.isAFLocked) {
                    controller.toggleAFLock()
                }
                Spacer()
            }
        }
    }

    // MARK: - White balance

    private var whiteBalanceSection: some View {
        PanelSection(title: "ホワイトバランス") {
            ToggleRow(title: "WB マニュアル", isOn: $controller.isManualWhiteBalanceEnabled)
            if controller.isManualWhiteBalanceEnabled {
                ValueSlider(
                    title: "色温度",
                    valueText: Format.kelvin(controller.whiteBalanceKelvin),
                    range: 2500...10000,
                    value: $controller.whiteBalanceKelvin,
                    step: 50
                )
                ValueSlider(
                    title: "ティント",
                    valueText: String(format: "%+.0f", controller.whiteBalanceTint),
                    range: -150...150,
                    value: $controller.whiteBalanceTint,
                    step: 1
                )
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(WhiteBalancePresets.all.filter { $0.id != "auto" }) { preset in
                            Button {
                                controller.whiteBalanceKelvin = preset.kelvin
                                controller.whiteBalanceTint = preset.tint
                                Haptics.selection()
                            } label: {
                                Text(preset.title)
                                    .font(.system(size: 11, weight: .semibold))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Capsule().fill(Color.white.opacity(0.13)))
                                    .foregroundStyle(.white.opacity(0.9))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            } else {
                StatusBadge(
                    title: "AWB",
                    value: "自動",
                    isAdjusting: controller.isAdjustingWhiteBalance
                )
            }
        }
    }
}

// MARK: - Small components

struct ToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
        }
        .tint(Color.yellow)
    }
}

struct StatusBadge: View {
    let title: String
    let value: String
    var isAdjusting: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isAdjusting ? Color.yellow : Color.green)
                .frame(width: 6, height: 6)
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.5))
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
                .monospacedDigit()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.white.opacity(0.08)))
    }
}

struct LockButton: View {
    let title: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isOn ? "lock.fill" : "lock.open")
                    .font(.system(size: 10, weight: .bold))
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .foregroundStyle(isOn ? Color.black : Color.white.opacity(0.85))
            .background(Capsule().fill(isOn ? Color.yellow : Color.white.opacity(0.13)))
        }
        .buttonStyle(.plain)
    }
}
