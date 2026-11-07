import AVFoundation
import CoreImage
import Foundation
import Photos
import UIKit

/// 1 回の撮影を担当するデリゲート。
/// RAW / プロセスドの両方を保持し、ルック適用後に PhotoKit へ保存する。
final class PhotoCaptureProcessor: NSObject, AVCapturePhotoCaptureDelegate {

    struct CaptureOutput: Identifiable {
        var reviewImage: UIImage?
        var localIdentifier: String?
        var record: CaptureRecord
        var usedRawPixelFormat: String?

        var id: String { record.id }
    }

    let format: PhotoFileFormat
    let style: RenderStyle
    let snapshot: CaptureSnapshot
    let captureDate = Date()

    private let completion: (Result<CaptureOutput, Error>) -> Void
    private let processingQueue: DispatchQueue

    private var rawFileData: Data?
    private var processedImage: CIImage?
    private var baseMetadata: [String: Any]?
    private var resolvedIsRaw = false
    private var rawPixelFormat: OSType = 0
    private var completed = false
    private let completionLock = NSLock()

    init(format: PhotoFileFormat,
         style: RenderStyle,
         snapshot: CaptureSnapshot,
         processingQueue: DispatchQueue,
         completion: @escaping (Result<CaptureOutput, Error>) -> Void) {
        self.format = format
        self.style = style
        self.snapshot = snapshot
        self.processingQueue = processingQueue
        self.completion = completion
        super.init()
    }

    // MARK: - AVCapturePhotoCaptureDelegate

    /// 複数回のデリゲート通知から完了通知が二重に飛ばないようにする
    private func finish(_ result: Result<CaptureOutput, Error>) {
        completionLock.lock()
        let alreadyCompleted = completed
        completed = true
        completionLock.unlock()
        guard !alreadyCompleted else { return }
        completion(result)
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        if let error {
            finish(.failure(error))
            return
        }

        baseMetadata = photo.metadata
        // RAW 撮影かどうかは自分たちで作成した設定（format）から判定する
        resolvedIsRaw = format.isRaw

        if resolvedIsRaw {
            rawFileData = photo.fileDataRepresentation()
            if let cgImage = photo.cgImageRepresentation() {
                processedImage = CIImage(cgImage: cgImage)
            }
        } else if let data = photo.fileDataRepresentation() {
            // 元データを保持（スタイルが無調整なら再エンコードせずにそのまま保存する）
            rawFileData = data
            processedImage = CIImage(data: data, options: [.applyOrientationProperty: true])
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: Error?) {
        if let error {
            finish(.failure(error))
            return
        }
        processingQueue.async { [weak self] in
            self?.finishCapture()
        }
    }

    // MARK: - Finalize

    private var isPassthroughStyle: Bool {
        style.lookIntensity <= 0.001 && style.adjustments.isNeutral && style.lut == nil
    }

    private func finishCapture() {
        do {
            let output = try buildAndSave()
            finish(.success(output))
        } catch {
            finish(.failure(error))
        }
    }

    private func buildAndSave() throws -> CaptureOutput {
        var processedData: Data?
        var reviewUIImage: UIImage?

        if isPassthroughStyle, !resolvedIsRaw, let original = rawFileData {
            // 無調整なら元の圧縮データをそのまま保存（再エンコードによる画質劣化ゼロ）
            processedData = original
            if let source = CIImage(data: original, options: [.applyOrientationProperty: true]),
               let cg = ImageExporter.render(source, context: ColorPipeline.shared.context),
               let review = ImageExporter.reviewImage(cg) {
                reviewUIImage = UIImage(cgImage: review)
            }
        } else if let source = processedImage {
            let prepared = ColorPipeline.prepareForProcessing(source)
            let rendered = ColorPipeline.shared.outputImage(from: prepared, style: style, resolutionScale: 1.0)
            if let cg = ImageExporter.render(rendered, context: ColorPipeline.shared.context) {
                processedData = ImageExporter.exportProcessed(cg, format: format, metadata: metadataForExport())
                if let review = ImageExporter.reviewImage(cg) {
                    reviewUIImage = UIImage(cgImage: review)
                }
            }
        }

        var record = CaptureRecord(
            id: UUID().uuidString,
            date: captureDate,
            fileFormat: format.title,
            lookName: style.lookIntensity > 0.001 ? style.look.name : "なし",
            lookIntensity: style.lookIntensity,
            iso: snapshot.iso,
            shutterSeconds: snapshot.shutterSeconds,
            exposureBias: snapshot.exposureBias,
            lensTitle: snapshot.lensTitle,
            zoomFactor: snapshot.zoomFactor,
            kelvin: snapshot.kelvin,
            tint: snapshot.tint,
            focusPosition: snapshot.focusPosition,
            width: 0,
            height: 0,
            isSilent: false,
            rawPixelFormat: nil,
            deviceName: snapshot.deviceName
        )

        if let extent = processedImage?.extent, extent.width > 0, extent.height > 0 {
            record.width = Int(extent.width.rounded())
            record.height = Int(extent.height.rounded())
        } else if let cg = reviewUIImage?.cgImage {
            record.width = cg.width
            record.height = cg.height
        }

        // 保存
        let rawResource: Data? = resolvedIsRaw ? rawFileData : nil
        if resolvedIsRaw {
            record.rawPixelFormat = rawPixelFormatName()
        }

        guard rawResource != nil || processedData != nil else {
            throw CaptureError.noImageData
        }

        let identifier = try PhotoLibraryService.shared.saveSynchronously(
            rawData: rawResource,
            processedData: processedData,
            format: format
        )
        record.id = identifier
        CaptureLogStore.shared.add(record)

        return CaptureOutput(
            reviewImage: reviewUIImage,
            localIdentifier: identifier,
            record: record,
            usedRawPixelFormat: record.rawPixelFormat
        )
    }

    private func metadataForExport() -> [String: Any] {
        ImageExporter.metadataDictionary(from: baseMetadata, style: style, snapshot: snapshot, date: captureDate)
    }

    private func rawPixelFormatName() -> String? {
        guard rawPixelFormat != 0 else { return nil }
        let chars = [UInt8(truncatingIfNeeded: (rawPixelFormat >> 24) & 0xFF),
                     UInt8(truncatingIfNeeded: (rawPixelFormat >> 16) & 0xFF),
                     UInt8(truncatingIfNeeded: (rawPixelFormat >> 8) & 0xFF),
                     UInt8(truncatingIfNeeded: rawPixelFormat & 0xFF)]
        return String(bytes: chars, encoding: .ascii)
    }

    /// 撮影設定作成時に記録しておく（RAW 形式の記録用）
    func noteRawPixelFormat(_ type: OSType) {
        rawPixelFormat = type
    }

    enum CaptureError: LocalizedError {
        case noImageData
        case saveFailed(String)

        var errorDescription: String? {
            switch self {
            case .noImageData: return "画像データを取得できませんでした。"
            case .saveFailed(let reason): return "写真の保存に失敗しました：\(reason)"
            }
        }
    }
}
