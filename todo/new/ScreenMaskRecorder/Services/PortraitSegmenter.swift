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

            // 获取分割蒙版的像素缓冲区
            let maskPixelBuffer = observation.pixelBuffer

            // 应用蒙版到原图
            return applyMask(to: pixelBuffer, mask: maskPixelBuffer)

        } catch {
            print("人像分割失败: \(error)")
            return nil
        }
    }

    /// 设置分割质量
    func setQuality(_ quality: SegmentationQuality) {
        self.qualityLevel = quality
    }

    // MARK: - Private Methods

    /// 应用蒙版到原图
    private func applyMask(to original: CVPixelBuffer, mask: CVPixelBuffer) -> CVPixelBuffer? {
        let ciImage = CIImage(cvPixelBuffer: original)

        // Vision 输出的 mask 是单通道的，需要转换
        let maskImage = CIImage(cvPixelBuffer: mask)

        // 创建蒙版效果 - 使用 CIFilter.maskToAlpha 或类似方法
        // 由于 Vision 输出的是人像区域为白色的蒙版，我们需要反转它
        guard let invertFilter = CIFilter(name: "CIColorInvert") else { return nil }
        invertFilter.setValue(maskImage, forKey: kCIInputImageKey)
        guard let invertedMask = invertFilter.outputImage else { return nil }

        // 将单通道蒙版转换为 alpha 通道
        // 首先将蒙版扩展到正确的颜色空间
        guard let maskToAlphaFilter = CIFilter(name: "CIMaskToAlpha") else { return nil }
        maskToAlphaFilter.setValue(invertedMask, forKey: kCIInputImageKey)
        guard let maskWithAlpha = maskToAlphaFilter.outputImage else { return nil }

        // 现在用这个蒙版合成到原图
        guard let blendFilter = CIFilter(name: "CIBlendWithMask") else { return nil }
        blendFilter.setValue(ciImage, forKey: kCIInputImageKey)
        blendFilter.setValue(CIImage(color: .clear), forKey: kCIInputBackgroundImageKey)
        blendFilter.setValue(maskWithAlpha, forKey: kCIInputMaskImageKey)

        guard let outputImage = blendFilter.outputImage else { return nil }

        // 渲染到新的像素缓冲区
        var pixelBuffer: CVPixelBuffer?
        let attrs = [
            kCVPixelBufferCGImageCompatibilityKey: kCFBooleanTrue!,
            kCVPixelBufferCGBitmapContextCompatibilityKey: kCFBooleanTrue!
        ] as CFDictionary

        let width = CVPixelBufferGetWidth(original)
        let height = CVPixelBufferGetHeight(original)

        CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs,
            &pixelBuffer
        )

        guard let outputBuffer = pixelBuffer else { return nil }

        ciContext.render(outputImage, to: outputBuffer)
        return outputBuffer
    }

    /// 快速预览模式 - 降低分辨率处理
    func processFrameFast(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        // 可选：先缩小图像处理，再缩放回来
        // 这里简化处理，直接使用原方法
        return processFrame(pixelBuffer)
    }
}
