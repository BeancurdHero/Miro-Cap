//
//  PortraitSegmenter.swift
//  ScreenMaskRecorder
//
//  人像分割服务 - 使用 Vision Framework
//

import Foundation
import Vision
import CoreVideo
import CoreImage

/// 人像分割质量级别
enum SegmentationQuality {
    case fast       // 快速但精度较低
    case balanced   // 平衡
    case accurate   // 高精度但较慢

    var visionQuality: VNGeneratePersonSegmentationRequest.QualityLevel {
        switch self {
        case .fast: return .fast
        case .balanced: return .balanced
        case .accurate: return .accurate
        }
    }
}

class PortraitSegmenter {
    // MARK: - Properties

    private var qualityLevel: SegmentationQuality = .balanced
    private var ciContext: CIContext

    // MARK: - Initialization

    init() {
        // 使用 Metal 加速
        let options: [CIContextOption: Any] = [
            .useSoftwareRenderer: false,
            .priorityRequestLow: false
        ]
        ciContext = CIContext(options: options)
    }

    // MARK: - Public Methods

    /// 处理单帧图像，移除背景
    /// - Parameter pixelBuffer: 输入的像素缓冲区
    /// - Returns: 处理后的像素缓冲区（背景透明）
    func processFrame(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        guard let outputImage = segmentedImage(from: pixelBuffer) else {
            return nil
        }

        return renderToPixelBuffer(outputImage, width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
    }

    /// 返回带透明背景的人像图像
    func segmentedImage(from pixelBuffer: CVPixelBuffer) -> CIImage? {
        let originalImage = CIImage(cvPixelBuffer: pixelBuffer).transformed(
            by: CGAffineTransform(translationX: -CIImage(cvPixelBuffer: pixelBuffer).extent.origin.x,
                                  y: -CIImage(cvPixelBuffer: pixelBuffer).extent.origin.y)
        )

        guard let personMask = personMaskImage(from: pixelBuffer, targetExtent: originalImage.extent) else {
            return nil
        }

        let transparentBackground = CIImage(color: .clear).cropped(to: originalImage.extent)
        guard let blendFilter = CIFilter(name: "CIBlendWithMask") else { return nil }
        blendFilter.setValue(originalImage, forKey: kCIInputImageKey)
        blendFilter.setValue(transparentBackground, forKey: kCIInputBackgroundImageKey)
        blendFilter.setValue(personMask, forKey: kCIInputMaskImageKey)

        return blendFilter.outputImage?.cropped(to: originalImage.extent)
    }

    /// 设置分割质量
    func setQuality(_ quality: SegmentationQuality) {
        self.qualityLevel = quality
    }

    // MARK: - Private Methods

    private func personMaskImage(from pixelBuffer: CVPixelBuffer, targetExtent: CGRect) -> CIImage? {
        // 创建 Vision 请求
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = qualityLevel.visionQuality
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])

        do {
            try handler.perform([request])

            guard let observation = request.results?.first as? VNPixelBufferObservation else {
                return nil
            }

            let rawMaskImage = CIImage(cvPixelBuffer: observation.pixelBuffer).transformed(
                by: CGAffineTransform(
                    translationX: -CIImage(cvPixelBuffer: observation.pixelBuffer).extent.origin.x,
                    y: -CIImage(cvPixelBuffer: observation.pixelBuffer).extent.origin.y
                )
            )
            let scaleX = targetExtent.width / rawMaskImage.extent.width
            let scaleY = targetExtent.height / rawMaskImage.extent.height
            var scaledMask = rawMaskImage
                .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
                .cropped(to: targetExtent)

            if let maskToAlphaFilter = CIFilter(name: "CIMaskToAlpha") {
                maskToAlphaFilter.setValue(scaledMask, forKey: kCIInputImageKey)
                scaledMask = maskToAlphaFilter.outputImage?.cropped(to: targetExtent) ?? scaledMask
            }

            if let blurFilter = CIFilter(name: "CIGaussianBlur") {
                blurFilter.setValue(scaledMask, forKey: kCIInputImageKey)
                blurFilter.setValue(1.2, forKey: kCIInputRadiusKey)
                scaledMask = blurFilter.outputImage?.cropped(to: targetExtent) ?? scaledMask
            }

            return scaledMask
        } catch {
            print("人像分割失败: \(error)")
            return nil
        }
    }

    private func renderToPixelBuffer(_ image: CIImage, width: Int, height: Int) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attrs = [
            kCVPixelBufferCGImageCompatibilityKey: kCFBooleanTrue!,
            kCVPixelBufferCGBitmapContextCompatibilityKey: kCFBooleanTrue!
        ] as CFDictionary

        CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs,
            &pixelBuffer
        )

        guard let outputBuffer = pixelBuffer else { return nil }

        ciContext.render(image.cropped(to: CGRect(x: 0, y: 0, width: width, height: height)), to: outputBuffer)
        return outputBuffer
    }

    /// 快速预览模式 - 降低分辨率处理
    func processFrameFast(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        // 可选：先缩小图像处理，再缩放回来
        // 这里简化处理，直接使用原方法
        return processFrame(pixelBuffer)
    }
}
