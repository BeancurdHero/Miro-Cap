//
//  FilterPreset.swift
//  ScreenMaskRecorder
//
//  滤镜预设和配置
//

import Foundation
import CoreImage
import CoreGraphics

/// 基础滤镜调整
struct BasicFilterAdjustments {
    var brightness: Float = 0.0      // -1.0 到 1.0
    var contrast: Float = 1.0        // 0.0 到 4.0
    var saturation: Float = 1.0      // 0.0 到 2.0
    var temperature: Float = 6500    // 色温 3000-8000K
    var exposure: Float = 0.0        // -5.0 到 5.0

    static let `default` = BasicFilterAdjustments()

    func apply(to image: CIImage) -> CIImage {
        var result = image

        if brightness != 0 || contrast != 1.0 || saturation != 1.0,
           let colorControls = CIFilter(name: "CIColorControls") {
            colorControls.setValue(result, forKey: kCIInputImageKey)
            colorControls.setValue(brightness, forKey: kCIInputBrightnessKey)
            colorControls.setValue(contrast, forKey: kCIInputContrastKey)
            colorControls.setValue(saturation, forKey: kCIInputSaturationKey)
            result = colorControls.outputImage ?? result
        }

        if exposure != 0,
           let exposureAdjust = CIFilter(name: "CIExposureAdjust") {
            exposureAdjust.setValue(result, forKey: kCIInputImageKey)
            exposureAdjust.setValue(exposure, forKey: kCIInputEVKey)
            result = exposureAdjust.outputImage ?? result
        }

        if temperature != 6500,
           let temperatureFilter = CIFilter(name: "CITemperatureAndTint") {
            temperatureFilter.setValue(result, forKey: kCIInputImageKey)
            temperatureFilter.setValue(CIVector(x: CGFloat(temperature), y: 0), forKey: "inputNeutral")
            temperatureFilter.setValue(CIVector(x: 6500, y: 0), forKey: "inputTargetNeutral")
            result = temperatureFilter.outputImage ?? result
        }

        return result
    }
}

private func applyCameraZoom(to image: CIImage, scale: CGFloat) -> CIImage {
    guard scale != 1 else { return image }

    let extent = image.extent
    let transform = CGAffineTransform(translationX: extent.midX, y: extent.midY)
        .scaledBy(x: scale, y: scale)
        .translatedBy(x: -extent.midX, y: -extent.midY)

    return image
        .transformed(by: transform)
        .cropped(to: extent)
}

/// 滤镜预设
enum FilterPreset: String, CaseIterable {
    case none = "原色"
    case noir = "黑白"
    case vintage = "复古"
    case warm = "暖色"
    case cool = "冷色"
    case dreamy = "梦幻"
    case fisheye = "鱼眼"

    var filterName: String? {
        switch self {
        case .none: return nil
        case .noir: return "CIPhotoEffectNoir"
        case .vintage: return "CIPhotoEffectInstant"
        case .warm, .cool, .dreamy, .fisheye: return nil  // 自定义组合滤镜
        }
    }

    var icon: String {
        switch self {
        case .none: return "camera.filters"
        case .noir: return "circle.lefthalf.filled"
        case .vintage: return "camera.aperture"
        case .warm: return "sun.max.fill"
        case .cool: return "snow"
        case .dreamy: return "sparkles"
        case .fisheye: return "camera.macro"
        }
    }

    /// 应用滤镜到 CIImage
    func apply(to image: CIImage, context: CIContext, fisheyeIntensity: Float = 1.0) -> CIImage? {
        guard let filterName = filterName else {
            // 自定义组合滤镜
            return applyCustomFilter(to: image, context: context, fisheyeIntensity: fisheyeIntensity)
        }

        guard let filter = CIFilter(name: filterName) else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        return filter.outputImage
    }

    private func applyCustomFilter(to image: CIImage, context: CIContext, fisheyeIntensity: Float) -> CIImage? {
        switch self {
        case .none:
            return image
        case .warm:
            // 暖色调：增加黄色和红色
            return applyTemperature(to: image, temperature: 1.2, context: context)
        case .cool:
            // 冷色调：增加蓝色
            return applyTemperature(to: image, temperature: 0.8, context: context)
        case .dreamy:
            return applySlimMirror(to: image)
        case .fisheye:
            return applyFisheye(to: image, intensity: fisheyeIntensity)
        default:
            return image
        }
    }

    private func applyTemperature(to image: CIImage, temperature: Double, context: CIContext) -> CIImage? {
        guard let filter = CIFilter(name: "CITemperatureAndTint") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(CIVector(x: 6500 * temperature, y: 0), forKey: "inputNeutral")
        filter.setValue(CIVector(x: 6500, y: 0), forKey: "inputTargetNeutral")
        return filter.outputImage
    }

    private func applyFisheye(to image: CIImage, intensity: Float) -> CIImage? {
        let normalizedImage = image.transformed(
            by: CGAffineTransform(translationX: -image.extent.origin.x, y: -image.extent.origin.y)
        )
        let extent = normalizedImage.extent
        let center = CIVector(x: extent.midX, y: extent.midY)
        let clampedIntensity = max(0.4, min(intensity, 2.0))

        var result = normalizedImage

        if let bump = CIFilter(name: "CIBumpDistortion") {
            bump.setValue(result, forKey: kCIInputImageKey)
            bump.setValue(center, forKey: kCIInputCenterKey)
            bump.setValue(max(extent.width, extent.height) * 0.92, forKey: kCIInputRadiusKey)
            bump.setValue(0.35 + clampedIntensity * 0.18, forKey: kCIInputScaleKey)
            result = bump.outputImage?.cropped(to: extent) ?? result
        }

        result = applyCameraZoom(to: result, scale: 1.03 + CGFloat(clampedIntensity) * 0.04)

        if let vignette = CIFilter(name: "CIVignette") {
            vignette.setValue(result, forKey: kCIInputImageKey)
            vignette.setValue(0.45 + clampedIntensity * 0.18, forKey: kCIInputIntensityKey)
            vignette.setValue(min(extent.width, extent.height) * 1.1, forKey: kCIInputRadiusKey)
            result = vignette.outputImage?.cropped(to: extent) ?? result
        }

        return result
    }

    private func applySlimMirror(to image: CIImage) -> CIImage? {
        let normalizedImage = image.transformed(
            by: CGAffineTransform(translationX: -image.extent.origin.x, y: -image.extent.origin.y)
        )
        let extent = normalizedImage.extent
        let center = CIVector(x: extent.midX, y: extent.midY * 1.02)

        var result = normalizedImage

        if let pinch = CIFilter(name: "CIPinchDistortion") {
            pinch.setValue(result, forKey: kCIInputImageKey)
            pinch.setValue(center, forKey: kCIInputCenterKey)
            pinch.setValue(min(extent.width, extent.height) * 0.42, forKey: kCIInputRadiusKey)
            pinch.setValue(0.62, forKey: kCIInputScaleKey)
            result = pinch.outputImage?.cropped(to: extent) ?? result
        }

        let squeezeTransform = CGAffineTransform(translationX: extent.midX, y: extent.midY)
            .scaledBy(x: 0.88, y: 1.04)
            .translatedBy(x: -extent.midX, y: -extent.midY)
        result = result.transformed(by: squeezeTransform).cropped(to: extent)

        if let colorControls = CIFilter(name: "CIColorControls") {
            colorControls.setValue(result, forKey: kCIInputImageKey)
            colorControls.setValue(1.08, forKey: kCIInputSaturationKey)
            colorControls.setValue(1.03, forKey: kCIInputContrastKey)
            result = colorControls.outputImage?.cropped(to: extent) ?? result
        }

        return result
    }
}

/// 滤镜配置 - 包含预设和基础调整
struct FilterSettings {
    var preset: FilterPreset = .none
    var basic: BasicFilterAdjustments = .default
    var zoom: Float = 1.0
    var fisheyeIntensity: Float = 1.15

    func apply(to image: CIImage, context: CIContext) -> CIImage {
        var result = image.transformed(
            by: CGAffineTransform(translationX: -image.extent.origin.x, y: -image.extent.origin.y)
        )
        result = preset.apply(to: result, context: context, fisheyeIntensity: fisheyeIntensity) ?? result
        result = basic.apply(to: result)
        result = applyCameraZoom(to: result, scale: CGFloat(zoom))
        return result.cropped(to: result.extent)
    }

    static let `default` = FilterSettings()
}
