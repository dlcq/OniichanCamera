import Metal
import MetalKit
import CoreImage
import UIKit

/// Core Image の出力を Metal で表示するプレビュービュー。
/// `AVCaptureVideoDataOutput` のフレームを `ColorPipeline` に通した結果を描画する。
final class PreviewMetalView: MTKView, MTKViewDelegate {

    private let commandQueue: MTLCommandQueue
    private let ciContext: CIContext
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    /// 描画対象。バックグラウンドスレッドから設定され、メインスレッドで描画される。
    var currentImage: CIImage?
    /// 参照保持中のピクセルバッファ（描画完了まで解放しない）
    private var heldBuffer: CVPixelBuffer?

    /// 描画対象フレームの元バッファを保持する。
    func retain(_ buffer: CVPixelBuffer) {
        heldBuffer = buffer
    }
    /// カメラのフレームが既に回転済みなので、そのまま描画する（アスペクトフィル）
    var mirrorsOutput = false

    init(frame: CGRect) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            fatalError("Metal is not available on this device")
        }
        commandQueue = queue
        ciContext = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        super.init(frame: frame, device: device)

        framebufferOnly = false
        colorPixelFormat = .bgra8Unorm
        isPaused = true
        enableSetNeedsDisplay = true
        preferredFramesPerSecond = 30
        autoResizeDrawable = true
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        delegate = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// 新しいフレームの描画を予約する（メインスレッドで呼ぶ）。
    func presentFrame(_ image: CIImage) {
        currentImage = image
        setNeedsDisplay()
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // 自動リサイズに任せる
    }

    func draw(in view: MTKView) {
        guard let image = currentImage,
              let drawable = currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        let drawableSize = CGSize(width: drawable.texture.width, height: drawable.texture.height)
        guard drawableSize.width > 0, drawableSize.height > 0 else { return }

        let imageExtent = image.extent
        guard imageExtent.width > 0, imageExtent.height > 0 else { return }

        // アスペクトフィルで表示するための変換
        let scaleX = drawableSize.width / imageExtent.width
        let scaleY = drawableSize.height / imageExtent.height
        let scale = max(scaleX, scaleY)
        let scaledWidth = imageExtent.width * scale
        let scaledHeight = imageExtent.height * scale
        let originX = (drawableSize.width - scaledWidth) / 2.0
        let originY = (drawableSize.height - scaledHeight) / 2.0

        var renderImage = image.transformed(by: CGAffineTransform(translationX: -imageExtent.minX, y: -imageExtent.minY))
        renderImage = renderImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        renderImage = renderImage.transformed(by: CGAffineTransform(translationX: originX, y: originY))

        let targetRect = CGRect(origin: .zero, size: drawableSize)
        ciContext.render(renderImage,
                         to: drawable.texture,
                         commandBuffer: commandBuffer,
                         bounds: targetRect,
                         colorSpace: colorSpace)

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

/// SwiftUI から利用するためのラッパー。
struct CameraPreviewView: UIViewRepresentable {
    let view: PreviewMetalView

    func makeUIView(context: Context) -> PreviewMetalView {
        view
    }

    func updateUIView(_ uiView: PreviewMetalView, context: Context) {
        // フレーム描画は CameraController から直接行われる
    }
}
