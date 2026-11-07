import AVFoundation
import SwiftUI
import UIKit

@main
struct OniichanCameraApp: App {
    @StateObject private var settings = AppSettings()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .preferredColorScheme(.dark)
                .persistentSystemOverlays(.hidden)
        }
    }
}

/// 起動時の権限確認を担当する。許可されるまで撮影画面へは進まない。
struct RootView: View {
    @State private var cameraAuthorized = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    @State private var showPermissionDenied = false

    var body: some View {
        Group {
            if cameraAuthorized {
                CameraView()
            } else {
                PermissionView(
                    title: "カメラへのアクセスが必要です",
                    message: "撮影のためにカメラを使用します。撮影した画像はこの端末にのみ保存されます。",
                    showDeniedHint: showPermissionDenied
                ) {
                    requestCameraAccess()
                }
            }
        }
        .onAppear {
            if !cameraAuthorized {
                requestCameraAccess()
            }
        }
    }

    private func requestCameraAccess() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            cameraAuthorized = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    cameraAuthorized = granted
                    showPermissionDenied = !granted
                }
            }
        default:
            showPermissionDenied = true
        }
    }
}

struct PermissionView: View {
    let title: String
    let message: String
    let showDeniedHint: Bool
    let action: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.white.opacity(0.9))
                Text(title)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white)
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.65))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 36)

                if showDeniedHint {
                    Text("カメラへのアクセスが拒否されています。「設定」アプリで OniichanCamera のカメラを許可してください。")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 36)

                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Text("設定を開く")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 22)
                            .padding(.vertical, 12)
                            .background(Capsule().fill(Color.white))
                    }
                    .buttonStyle(.plain)
                } else {
                    Button(action: action) {
                        Text("カメラを有効にする")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 22)
                            .padding(.vertical, 12)
                            .background(Capsule().fill(Color.white))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
