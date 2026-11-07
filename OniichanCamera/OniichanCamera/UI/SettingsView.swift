import SwiftUI

/// 設定画面。撮影・画質・表示補助・操作・端末情報をまとめる。
struct SettingsView: View {
    var capabilities: CameraCapabilities

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("保存形式", selection: $settings.fileFormat) {
                        ForEach(availableFormats) { format in
                            Text(format.title).tag(format)
                        }
                    }
                    ForEach(availableFormats) { format in
                        if format == settings.fileFormat {
                            Text(format.details)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("撮影・保存")
                } footer: {
                    Text("RAW / ProRAW はセンサーの生データをそのまま DNG で保存します。ルックと画像調整は、同時に保存される現像済みコピーにのみ適用され、DNG の画質には影響しません。")
                }

                Section {
                    Toggle("連写撮影", isOn: $settings.isBurstEnabled)
                    if settings.isBurstEnabled {
                        Stepper("連写枚数：\(settings.burstCount) 枚",
                                value: $settings.burstCount, in: 2...10)
                    }
                    Toggle("撮影直後のプレビューを表示", isOn: $settings.showsCaptureReview)
                } header: {
                    Text("シャッター")
                }

                if CameraController.isSilentCaptureAvailable {
                    Section {
                        Toggle("サイレント撮影（無音）", isOn: $settings.silentCaptureEnabled)
                    } header: {
                        Text("無音撮影")
                    } footer: {
                        Text(CameraController.silentCaptureExplanation)
                    }
                } else {
                    Section {
                        Label {
                            Text("無音撮影は利用できません")
                                .font(.system(size: 13, weight: .medium))
                        } icon: {
                            Image(systemName: "speaker.slash")
                                .foregroundStyle(.secondary)
                        }
                    } footer: {
                        Text(CameraController.silentCaptureExplanation)
                    }
                }

                Section {
                    Picker("グリッド", selection: $settings.gridStyle) {
                        ForEach(GridStyle.allCases) { style in
                            Text(style.title).tag(style)
                        }
                    }
                    Toggle("水平器", isOn: $settings.showsLevel)
                    Toggle("ヒストグラム", isOn: $settings.showsHistogram)
                    Toggle("ゼブラ（白飛び確認）", isOn: $settings.showsZebra)
                    if settings.showsZebra {
                        VStack(alignment: .leading) {
                            Text("ゼブラのしきい値：\(Int((settings.zebraThreshold * 100).rounded()))%")
                                .font(.system(size: 12))
                            Slider(value: $settings.zebraThreshold, in: 0.75...0.99)
                                .tint(.yellow)
                        }
                    }
                    Toggle("フォーカスピーキング", isOn: $settings.showsFocusPeaking)
                    if settings.showsFocusPeaking {
                        VStack(alignment: .leading) {
                            Text("ピークの感度：\(Int((settings.peakingThreshold * 100).rounded()))%")
                                .font(.system(size: 12))
                            Slider(value: $settings.peakingThreshold, in: 0.05...0.4)
                                .tint(.yellow)
                        }
                    }
                    Toggle("構図確認用セーフティガイド", isOn: $settings.showsSafeAreaGuide)
                    Picker("アスペクト比ガイド", selection: $settings.aspectGuide) {
                        ForEach(AspectGuide.allCases) { guide in
                            Text(guide.title).tag(guide)
                        }
                    }
                    VStack(alignment: .leading) {
                        Text("オーバーレイの不透明度：\(Int((settings.overlayOpacity * 100).rounded()))%")
                            .font(.system(size: 12))
                        Slider(value: $settings.overlayOpacity, in: 0.2...1.0)
                            .tint(.yellow)
                    }
                    Picker("オーバーレイの色", selection: $settings.overlayColorName) {
                        Text("ホワイト").tag("white")
                        Text("アンバー").tag("amber")
                        Text("シアン").tag("cyan")
                    }
                } header: {
                    Text("撮影補助")
                } footer: {
                    Text("すべての表示は個別にオン・オフでき、不透明度と色も変更できます。")
                }

                Section {
                    Toggle("触覚フィードバック", isOn: $settings.hapticsEnabled)
                    Toggle("撮影中は画面スリープを防止", isOn: $settings.keepsScreenAwake)
                } header: {
                    Text("操作")
                }

                Section {
                    infoRow("RAW 対応", capabilities.supportsRAW ? "対応" : "非対応")
                    infoRow("Apple ProRAW 対応", capabilities.supportsProRAW ? "対応" : "非対応")
                    infoRow("フラッシュ", capabilities.hasFlash ? "搭載" : "なし")
                    infoRow("ISO 範囲", "\(Int(capabilities.minISO)) 〜 \(Int(capabilities.maxISO))")
                    infoRow("シャッター範囲",
                            "\(ShutterSpeed.displayString(seconds: capabilities.minShutter)) 〜 \(ShutterSpeed.displayString(seconds: capabilities.maxShutter))")
                    infoRow("ズーム範囲", String(format: "%.1f× 〜 %.1f×", capabilities.minZoom, capabilities.maxZoom))
                    infoRow("センサー解像度", capabilities.formatDescription.isEmpty ? "—" : capabilities.formatDescription)
                    infoRow("カメラ", capabilities.deviceName.isEmpty ? "—" : capabilities.deviceName)
                } header: {
                    Text("この端末で利用できる機能")
                } footer: {
                    Text("対応していない機能は自動的に非表示になります。表示されている機能はすべて実際に動作します。")
                }

                Section {
                    Text("OniichanCamera は撮影した画像を外部サーバーへ送信しません。写真はこの端末の写真ライブラリとアプリ内ログ（撮影情報のみ）にのみ保存されます。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Button("色調整をリセット") {
                        settings.resetColorSettings()
                        Haptics.light()
                    }
                    .foregroundStyle(.red)
                } header: {
                    Text("プライバシー・その他")
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完了") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var availableFormats: [PhotoFileFormat] {
        PhotoFileFormat.allCases.filter { format in
            switch format {
            case .raw: return capabilities.supportsRAW
            case .proRaw: return capabilities.supportsProRAW
            default: return true
            }
        }
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .monospacedDigit()
        }
        .font(.system(size: 13))
    }
}
