import Foundation
import Photos
import UIKit
import UniformTypeIdentifiers

/// PhotoKit との連携。保存・取得・削除・共有の素材取得を担う。
final class PhotoLibraryService {

    static let shared = PhotoLibraryService()

    private init() {}

    enum LibraryError: LocalizedError {
        case notAuthorized
        case saveFailed
        case assetNotFound
        case deleteFailed

        var errorDescription: String? {
            switch self {
            case .notAuthorized: return "写真ライブラリへのアクセスが許可されていません。設定から許可してください。"
            case .saveFailed: return "写真ライブラリへの保存に失敗しました。"
            case .assetNotFound: return "写真が見つかりませんでした。"
            case .deleteFailed: return "写真の削除に失敗しました。"
            }
        }
    }

    // MARK: - Authorization

    /// 保存のみに必要な権限状態。
    var addAuthorizationStatus: PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .addOnly)
    }

    /// 閲覧・削除に必要な権限状態。
    var readAuthorizationStatus: PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    func requestAddAccess(completion: @escaping (Bool) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            DispatchQueue.main.async {
                completion(status == .authorized || status == .limited)
            }
        }
    }

    func requestReadAccess(completion: @escaping (Bool) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            DispatchQueue.main.async {
                completion(status == .authorized || status == .limited)
            }
        }
    }

    // MARK: - Save

    /// 同期的に保存を試み、asset のローカル識別子を返す（バックグラウンドキューで呼ぶこと）。
    func saveSynchronously(rawData: Data?, processedData: Data?, format: PhotoFileFormat) throws -> String {
        guard addAuthorizationStatus == .authorized || addAuthorizationStatus == .limited else {
            throw LibraryError.notAuthorized
        }

        var localIdentifier = ""
        var saveError: Error?

        let semaphore = DispatchSemaphore(value: 0)
        PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            if let rawData {
                // DNG は無改変で保存する（ルックや調整は現像済みコピー側にのみ適用）
                let rawOptions = PHAssetResourceCreationOptions()
                rawOptions.originalFilename = "OniichanCamera-RAW.dng"
                request.addResource(with: .alternatePhoto, data: rawData, options: rawOptions)
            }
            if let processedData {
                request.addResource(with: .photo, data: processedData, options: nil)
            }
            localIdentifier = request.placeholderForCreatedAsset?.localIdentifier ?? ""
        } completionHandler: { success, error in
            saveError = error
            if !success && error == nil {
                saveError = LibraryError.saveFailed
            }
            semaphore.signal()
        }
        semaphore.wait()

        if let saveError { throw saveError }
        guard !localIdentifier.isEmpty else { throw LibraryError.saveFailed }
        return localIdentifier
    }

    // MARK: - Fetch

    func asset(forLocalIdentifier identifier: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject
    }

    func latestAsset() -> PHAsset? {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 1
        return PHAsset.fetchAssets(with: options).firstObject
    }

    func fetchAssets(limit: Int = 200) -> PHFetchResult<PHAsset> {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = limit
        return PHAsset.fetchAssets(with: options)
    }

    func requestThumbnail(for asset: PHAsset, targetSize: CGSize, completion: @escaping (UIImage?) -> Void) {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        PHImageManager.default().requestImage(for: asset, targetSize: targetSize, contentMode: .aspectFill, options: options) { image, _ in
            DispatchQueue.main.async { completion(image) }
        }
    }

    func requestImage(for asset: PHAsset, targetSize: CGSize, completion: @escaping (UIImage?) -> Void) {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        PHImageManager.default().requestImage(for: asset, targetSize: targetSize, contentMode: .aspectFit, options: options) { image, _ in
            DispatchQueue.main.async { completion(image) }
        }
    }

    /// 共有用にフル解像度の画像ファイルを一時ディレクトリへ書き出す。
    func exportShareFile(for asset: PHAsset, completion: @escaping (Result<URL, Error>) -> Void) {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.version = .current
        PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, uti, _, _ in
            guard let data, let uti else {
                DispatchQueue.main.async { completion(.failure(LibraryError.assetNotFound)) }
                return
            }
            let typeIdentifier = uti as String
            let ext: String
            if typeIdentifier == UTType.jpeg.identifier || typeIdentifier == "public.jpeg" {
                ext = "jpg"
            } else if typeIdentifier == "com.adobe.dng" || typeIdentifier.hasPrefix("com.adobe.raw-image")
                        || typeIdentifier == UTType.rawImage.identifier {
                ext = "dng"
            } else {
                ext = "heic"
            }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("OniichanCamera-\(Int(Date().timeIntervalSince1970)).\(ext)")
            do {
                try data.write(to: url, options: .atomic)
                DispatchQueue.main.async { completion(.success(url)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    // MARK: - Delete

    func delete(localIdentifier: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard readAuthorizationStatus == .authorized || readAuthorizationStatus == .limited else {
            DispatchQueue.main.async { completion(.failure(LibraryError.notAuthorized)) }
            return
        }
        guard let asset = asset(forLocalIdentifier: localIdentifier) else {
            DispatchQueue.main.async { completion(.failure(LibraryError.assetNotFound)) }
            return
        }
        PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets([asset] as NSArray)
        } completionHandler: { success, error in
            DispatchQueue.main.async {
                if success {
                    completion(.success(()))
                } else {
                    completion(.failure(error ?? LibraryError.deleteFailed))
                }
            }
        }
    }
}
