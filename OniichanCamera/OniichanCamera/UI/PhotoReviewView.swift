import Photos
import SwiftUI
import UIKit

/// 撮影直後のプレビュー / 写真の拡大表示。
/// 撮影情報の確認・共有・削除が可能。
struct PhotoReviewView: View {
    let output: PhotoCaptureProcessor.CaptureOutput
    let onClose: () -> Void

    @EnvironmentObject private var settings: AppSettings
    @State private var image: UIImage?
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var showInfo = false
    @State private var showShare = false
    @State private var shareItems: [Any] = []
    @State private var showLibrary = false
    @State private var confirmDelete = false
    @State private var toast: ToastMessage?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                Spacer()
                imageArea
                Spacer()
                bottomBar
            }

            if let toast {
                VStack {
                    Spacer()
                    ToastView(message: toast)
                        .padding(.bottom, 96)
                }
            }
        }
        .statusBarHidden(true)
        .onAppear {
            image = output.reviewImage
            if image == nil, let identifier = output.localIdentifier {
                loadFromLibrary(identifier)
            }
        }
        .sheet(isPresented: $showInfo) {
            PhotoInfoView(record: output.record, usedRawPixelFormat: output.usedRawPixelFormat)
        }
        .sheet(isPresented: $showLibrary) {
            LibraryGridView { selected in
                showLibrary = false
                loadFromLibrary(selected)
            }
        }
        .sheet(isPresented: $showShare) {
            ShareSheet(items: shareItems)
        }
        .confirmationDialog("この写真を削除しますか？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("削除", role: .destructive) {
                deletePhoto()
            }
            Button("キャンセル", role: .cancel) {}
        }
    }

    // MARK: - Areas

    private var topBar: some View {
        HStack {
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Color.white.opacity(0.14)))
            }
            .buttonStyle(.plain)
            Spacer()
            VStack(spacing: 2) {
                Text(output.record.date, style: .date)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                Text(output.record.fileFormat)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
            Button {
                showInfo = true
            } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Color.white.opacity(0.14)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
    }

    private var imageArea: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { value in
                                scale = min(max(lastScale * value, 1.0), 6.0)
                            }
                            .onEnded { _ in
                                lastScale = scale
                            }
                    )
                    .onTapGesture(count: 2) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            scale = scale > 1.0 ? 1.0 : 2.5
                            lastScale = scale
                        }
                    }
            } else {
                ProgressView()
                    .tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var bottomBar: some View {
        HStack(spacing: 26) {
            actionButton("ライブラリ", systemName: "square.grid.2x2") {
                showLibrary = true
            }
            actionButton("共有", systemName: "square.and.arrow.up") {
                prepareShare()
            }
            actionButton("削除", systemName: "trash", isDestructive: true) {
                confirmDelete = true
            }
        }
        .padding(.bottom, 26)
        .padding(.top, 10)
    }

    private func actionButton(_ title: String, systemName: String, isDestructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.light()
            action()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: systemName)
                    .font(.system(size: 18, weight: .medium))
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(isDestructive ? Color.red : Color.white.opacity(0.9))
            .frame(width: 72)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func loadFromLibrary(_ localIdentifier: String) {
        guard let asset = PhotoLibraryService.shared.asset(forLocalIdentifier: localIdentifier) else { return }
        PhotoLibraryService.shared.requestImage(for: asset, targetSize: CGSize(width: 1800, height: 1800)) { loaded in
            if let loaded {
                image = loaded
            }
        }
    }

    private func prepareShare() {
        PhotoLibraryService.shared.requestReadAccess { granted in
            guard granted else {
                showToast(PhotoLibraryService.LibraryError.notAuthorized.localizedDescription, isError: true)
                return
            }
            if let identifier = output.localIdentifier,
               let asset = PhotoLibraryService.shared.asset(forLocalIdentifier: identifier) {
                PhotoLibraryService.shared.exportShareFile(for: asset) { result in
                    switch result {
                    case .success(let url):
                        shareItems = [url]
                        showShare = true
                    case .failure(let error):
                        showToast(error.localizedDescription, isError: true)
                    }
                }
            } else if let image {
                shareItems = [image]
                showShare = true
            } else {
                showToast("共有する画像がありません", isError: true)
            }
        }
    }

    private func deletePhoto() {
        guard let identifier = output.localIdentifier else {
            showToast("削除できる写真ではありません", isError: true)
            return
        }
        PhotoLibraryService.shared.requestReadAccess { granted in
            guard granted else {
                showToast(PhotoLibraryService.LibraryError.notAuthorized.localizedDescription, isError: true)
                return
            }
            PhotoLibraryService.shared.delete(localIdentifier: identifier) { result in
                switch result {
                case .success:
                    Haptics.success()
                    onClose()
                case .failure(let error):
                    showToast(error.localizedDescription, isError: true)
                }
            }
        }
    }

    private func showToast(_ text: String, isError: Bool) {
        let message = ToastMessage(text: text, isError: isError)
        withAnimation { toast = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            if toast == message {
                withAnimation { toast = nil }
            }
        }
    }
}

// MARK: - Photo info

struct PhotoInfoView: View {
    let record: CaptureRecord
    let usedRawPixelFormat: String?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("撮影情報") {
                    infoRow("撮影日時", record.date.formatted(date: .abbreviated, time: .standard))
                    infoRow("ISO", record.iso > 0 ? Format.iso(record.iso) : "—")
                    infoRow("シャッタースピード", record.shutterDisplay)
                    infoRow("露出補正", record.exposureBias != 0 ? Format.ev(record.exposureBias) : "±0.0 EV")
                    infoRow("レンズ", record.lensTitle)
                    infoRow("ズーム", String(format: "%.1f×", record.zoomFactor))
                }
                Section("色・画質") {
                    infoRow("ルック", "\(record.lookName)（\(Int((record.lookIntensity * 100).rounded()))%）")
                    infoRow("ホワイトバランス", record.kelvin > 0 ? Format.kelvin(record.kelvin) : "オート")
                    infoRow("ファイル形式", record.fileFormat)
                    if let rawPixelFormat = usedRawPixelFormat ?? record.rawPixelFormat {
                        infoRow("RAW ピクセル形式", rawPixelFormat)
                    }
                }
                Section("画像") {
                    infoRow("解像度", record.width > 0 ? "\(record.width) × \(record.height) px" : "—")
                    infoRow("撮影デバイス", record.deviceName)
                    if record.isSilent {
                        infoRow("シャッター音", "サイレント（フレームキャプチャ）")
                    }
                }
            }
            .navigationTitle("撮影情報")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .foregroundStyle(.primary)
                .monospacedDigit()
        }
        .font(.system(size: 13))
    }
}

// MARK: - Library grid

struct LibraryGridView: View {
    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var assets: PHFetchResult<PHAsset>?
    @State private var thumbnails: [String: UIImage] = [:]

    private let columns = [GridItem(.flexible(), spacing: 3), GridItem(.flexible(), spacing: 3), GridItem(.flexible(), spacing: 3)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 3) {
                    if let assets {
                        ForEach(0..<assets.count, id: \.self) { index in
                            let asset = assets.object(at: index)
                            Button {
                                onSelect(asset.localIdentifier)
                            } label: {
                                ZStack {
                                    Color.white.opacity(0.08)
                                    if let thumb = thumbnails[asset.localIdentifier] {
                                        Image(uiImage: thumb)
                                            .resizable()
                                            .scaledToFill()
                                    }
                                }
                                .aspectRatio(1, contentMode: .fill)
                                .clipped()
                            }
                            .buttonStyle(.plain)
                            .onAppear {
                                loadThumbnail(for: asset)
                            }
                        }
                    }
                }
                .padding(3)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("写真ライブラリ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            PhotoLibraryService.shared.requestReadAccess { _ in
                assets = PhotoLibraryService.shared.fetchAssets(limit: 200)
            }
        }
    }

    private func loadThumbnail(for asset: PHAsset) {
        guard thumbnails[asset.localIdentifier] == nil else { return }
        PhotoLibraryService.shared.requestThumbnail(for: asset, targetSize: CGSize(width: 220, height: 220)) { image in
            if let image {
                thumbnails[asset.localIdentifier] = image
            }
        }
    }
}
