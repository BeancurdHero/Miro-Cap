//
//  VideoProcessor.swift
//  ScreenMaskRecorder
//
//  视频合成处理和导出服务
//

import Foundation
import AVFoundation
import CoreImage
import CoreVideo
import Combine
import AppKit

/// 视频配置
struct VideoConfiguration {
    static let frameRate: Double = 30.0
    static let outputPixelFormat = kCVPixelFormatType_32BGRA
}

class VideoProcessor {
    // MARK: - Properties

    private var assetWriter: AVAssetWriter?
    private var assetWriterInput: AVAssetWriterInput?
    private var audioWriterInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?

    private var ciContext: CIContext
    private var sessionStartTime: CMTime?
    private var hasStartedSession = false
    private var frameCount: Int64 = 0
    private var audioSampleCount: Int = 0
    private let videoProcessingQueue = DispatchQueue(label: "com.screenmaskrecorder.video-processor")
    private let audioProcessingQueue = DispatchQueue(label: "com.screenmaskrecorder.audio-processor")
    private let writerStateLock = NSLock()

    // 保存摄像头帧格式信息
    private var cameraPixelFormat: OSType = 0
    private var cameraWidth: Int = 0
    private var cameraHeight: Int = 0

    // 配置
    private var backgroundMedia: BackgroundMediaType = .none
    private var canvasAspectRatio: CanvasAspectRatio = .landscape16x9
    private var backgroundScale: CGFloat = 1.0
    private var maskSettings: MaskSettings = .default
    private var filterSettings: FilterSettings = .default
    private var isPortraitSegmentationEnabled: Bool = false
    private var renderSize: CGSize = CanvasAspectRatio.landscape16x9.outputSize

    // 背景视频播放器
    private var backgroundPlayer: AVPlayer?
    private var backgroundPlayerItem: AVPlayerItem?
    private var backgroundPlayerLayer: AVPlayerLayer?

    // 背景视频读取器（用于录制时获取帧）
    private var backgroundAssetReader: AVAssetReader?
    private var backgroundReaderOutput: AVAssetReaderTrackOutput?
    private var backgroundStartTime: CMTime?
    private var backgroundVideoURL: URL?

    // 背景图片
    private var backgroundImage: CIImage?

    // 人像分割器
    private let portraitSegmenter = PortraitSegmenter()

    // MARK: - Published

    @Published var isProcessing = false

    private var outputWidth: Int { Int(renderSize.width) }
    private var outputHeight: Int { Int(renderSize.height) }

    // MARK: - Initialization

    init() {
        let options: [CIContextOption: Any] = [
            .useSoftwareRenderer: false,
            .priorityRequestLow: false
        ]
        ciContext = CIContext(options: options)
    }

    // MARK: - Setup

    func configure(
        backgroundMedia: BackgroundMediaType,
        canvasAspectRatio: CanvasAspectRatio,
        backgroundScale: CGFloat,
        maskSettings: MaskSettings,
        filterSettings: FilterSettings,
        isPortraitSegmentationEnabled: Bool
    ) {
        self.backgroundMedia = backgroundMedia
        self.canvasAspectRatio = canvasAspectRatio
        self.backgroundScale = backgroundScale
        self.maskSettings = maskSettings
        self.filterSettings = filterSettings
        self.isPortraitSegmentationEnabled = isPortraitSegmentationEnabled
        self.renderSize = canvasAspectRatio.outputSize
    }

    // MARK: - Recording Control

    private var customSavePath: URL?
    private var recordingTimer: Timer?

    func startRecording(
        backgroundMedia: BackgroundMediaType,
        canvasAspectRatio: CanvasAspectRatio,
        backgroundScale: CGFloat,
        maskSettings: MaskSettings,
        filterSettings: FilterSettings,
        isPortraitSegmentationEnabled: Bool,
        savePath: URL? = nil
    ) async throws {
        print("=== 开始新的录制 ===")

        // 先清理之前的录制
        if let writer = assetWriter, writer.status == .writing {
            print("清理之前的录制...")
            await writer.finishWriting()
        }

        assetWriter = nil
        assetWriterInput = nil
        audioWriterInput = nil
        adaptor = nil
        frameCount = 0
        audioSampleCount = 0
        sessionStartTime = nil
        hasStartedSession = false

        self.backgroundMedia = backgroundMedia
        self.canvasAspectRatio = canvasAspectRatio
        self.backgroundScale = backgroundScale
        self.maskSettings = maskSettings
        self.filterSettings = filterSettings
        self.isPortraitSegmentationEnabled = isPortraitSegmentationEnabled
        self.customSavePath = savePath
        self.renderSize = canvasAspectRatio.outputSize

        // 设置背景
        try await setupBackground()

        // 创建输出文件
        let outputURL = generateOutputURL(savePath: savePath)
        print("开始录制，保存到: \(outputURL.path)")

        // 删除已存在的文件
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        // 初始化 Asset Writer
        assetWriter = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        print("AssetWriter 创建成功")

        // 配置视频输入
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: outputWidth,
            AVVideoHeightKey: outputHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 10_000_000, // 10 Mbps
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]

        assetWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        assetWriterInput?.expectsMediaDataInRealTime = true

        // 配置音频输入 - 不指定具体格式，让系统自动处理
        // 音频输入 - 使用系统自动格式
        // 音频输入 - 使用具体设置而不是 nil
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 2,
            AVSampleRateKey: 44100.0,
            AVEncoderBitRateKey: 128000
        ]

        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput.expectsMediaDataInRealTime = true

        // 配置像素缓冲区适配器
        // 不指定源属性，让它自动处理摄像头帧的格式
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: assetWriterInput!,
            sourcePixelBufferAttributes: nil
        )

        if let writerInput = assetWriterInput, assetWriter?.canAdd(writerInput) ?? false {
            assetWriter?.add(writerInput)
            print("视频输入已添加")
        } else {
            print("无法添加视频输入")
        }

        if assetWriter?.canAdd(audioInput) ?? false {
            assetWriter?.add(audioInput)
            print("✓ 音频输入已添加")
        } else {
            print("✗ 无法添加音频输入")
        }

        // 保存音频输入引用
        audioWriterInput = audioInput

        // 开始录制，真正的 session 会在第一帧媒体数据到达时启动。
        assetWriter?.startWriting()
        print("录制已开始")

        // 如果是视频背景，开始播放和读取
        if case .video = backgroundMedia {
            backgroundPlayer?.play()
            backgroundAssetReader?.startReading()
        }
    }

    func processVideoSample(_ sampleBuffer: CMSampleBuffer) {
        videoProcessingQueue.async { [weak self] in
            self?._processVideoSample(sampleBuffer)
        }
    }

    private func _processVideoSample(_ sampleBuffer: CMSampleBuffer) {
        guard let writer = assetWriter,
              let writerInput = assetWriterInput,
              writer.status == .writing else {
            if frameCount % 30 == 0 || frameCount < 5 {
                print("processFrame: writer status = \(assetWriter?.status.rawValue ?? -1), frameCount = \(frameCount)")
            }
            return
        }

        guard writerInput.isReadyForMoreMediaData else {
            return
        }

        let sourceTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let presentationTime = normalizedTime(for: sourceTime)
        guard presentationTime >= .zero else { return }

        ensureSessionStarted()

        guard let cameraFrame = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        // 合成最终帧
        if let composedFrame = composeFrame(cameraFrame) {
            // 写入帧
            if let adapt = adaptor {
                let success = adapt.append(composedFrame, withPresentationTime: presentationTime)
                if !success {
                    print("processFrame: append 失败, frameCount = \(frameCount), error = \(writer.error?.localizedDescription ?? "unknown")")
                }
                frameCount += 1

                if frameCount % 30 == 0 || frameCount < 5 {
                    print("processFrame: 已写入 \(frameCount) 帧, time = \(presentationTime.seconds)")
                }
            } else {
                print("processFrame: adaptor 为 nil")
            }
        }
    }

    func processAudioSample(_ sampleBuffer: CMSampleBuffer) {
        audioProcessingQueue.async { [weak self] in
            self?._processAudioSample(sampleBuffer)
        }
    }

    private func _processAudioSample(_ sampleBuffer: CMSampleBuffer) {
        guard let audioInput = audioWriterInput,
              audioInput.isReadyForMoreMediaData else {
            if audioSampleCount == 0 {
                print("⚠️ 音频输入未就绪: audioWriterInput=\(audioWriterInput != nil), ready=\(audioWriterInput?.isReadyForMoreMediaData ?? false)")
            }
            return
        }

        let sourceTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let presentationTime = normalizedTime(for: sourceTime)
        guard presentationTime >= .zero else { return }

        ensureSessionStarted()

        guard let retimedSample = copySampleBuffer(sampleBuffer, withPresentationTime: presentationTime) else {
            if audioSampleCount == 0 {
                print("✗ 音频重定时失败")
            }
            return
        }

        let success = audioInput.append(retimedSample)
        if success {
            audioSampleCount += 1
            if audioSampleCount == 1 {
                print("✓ 第一帧音频已写入")
            } else if audioSampleCount % 100 == 0 {
                print("✓ 已写入 \(audioSampleCount) 帧音频")
            }
        } else {
            print("✗ 音频写入失败")
        }
    }

    func stopRecording(savePath: URL? = nil) async throws -> URL? {
        print("=== 停止录制 ===")
        print("总视频帧数: \(frameCount)")
        print("总音频样本数: \(audioSampleCount)")

        videoProcessingQueue.sync {}
        audioProcessingQueue.sync {}

        // 停止背景播放和读取
        backgroundPlayer?.pause()
        backgroundPlayer = nil
        backgroundAssetReader?.cancelReading()
        backgroundAssetReader = nil

        guard let writer = assetWriter else {
            print("错误: assetWriter 为 nil")
            throw VideoProcessorError.writerSetupFailed
        }

        // 完成写入
        assetWriterInput?.markAsFinished()
        audioWriterInput?.markAsFinished()

        // 等待写入完成
        await writer.finishWriting()

        // 检查写入状态
        if writer.status == .failed {
            let error = writer.error ?? NSError(domain: "VideoProcessor", code: -1, userInfo: nil)
            print("录制失败: \(error)")
            throw error
        }

        let outputURL = writer.outputURL

        // 验证文件存在
        if FileManager.default.fileExists(atPath: outputURL.path) {
            let attributes = try? FileManager.default.attributesOfItem(atPath: outputURL.path)
            let fileSize = attributes?[.size] as? Int64 ?? 0
            print("录制完成，文件: \(outputURL.path)")
            print("文件大小: \(fileSize) bytes (\(fileSize / 1024) KB)")
        } else {
            print("警告: 文件不存在")
        }

        // 清理
        assetWriter = nil
        assetWriterInput = nil
        audioWriterInput = nil
        adaptor = nil
        sessionStartTime = nil
        hasStartedSession = false
        frameCount = 0
        audioSampleCount = 0

        return outputURL
    }

    func pauseRecording() async {
        backgroundPlayer?.pause()
    }

    func resumeRecording() async {
        backgroundPlayer?.play()
    }

    // MARK: - Private Methods

    private func setupBackground() async throws {
        // 清理旧的资源
        backgroundAssetReader?.cancelReading()
        backgroundAssetReader = nil

        switch backgroundMedia {
        case .none:
            backgroundImage = nil
            backgroundPlayer = nil
            backgroundVideoURL = nil

        case .image(let url):
            let imageData = try Data(contentsOf: url)
            guard let image = CIImage(data: imageData) else {
                throw VideoProcessorError.invalidImage
            }
            backgroundImage = image
            backgroundVideoURL = nil

        case .video(let url):
            backgroundVideoURL = url
            // 设置 AVPlayer 用于预览
            let playerItem = AVPlayerItem(url: url)
            backgroundPlayerItem = playerItem

            let player = AVPlayer(playerItem: playerItem)
            player.actionAtItemEnd = .none  // 不自动暂停

            // 循环播放
            NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: playerItem,
                queue: .main
            ) { [weak player] _ in
                player?.seek(to: .zero)
                player?.play()
            }

            backgroundPlayer = player

            try await recreateBackgroundReader()
        }
    }

    private func recreateBackgroundReader() async throws {
        guard let url = backgroundVideoURL else { return }

        backgroundAssetReader?.cancelReading()
        backgroundAssetReader = nil
        backgroundReaderOutput = nil

        let asset = AVAsset(url: url)
        try await asset.loadValues(forKeys: ["tracks", "duration"])

        let assetReader = try AVAssetReader(asset: asset)
        assetReader.timeRange = CMTimeRange(start: .zero, duration: asset.duration)

        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else {
            throw VideoProcessorError.invalidImage
        }

        let readerOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
        )
        readerOutput.alwaysCopiesSampleData = false

        if assetReader.canAdd(readerOutput) {
            assetReader.add(readerOutput)
        }

        backgroundAssetReader = assetReader
        backgroundReaderOutput = readerOutput
        backgroundStartTime = CMTime(seconds: CACurrentMediaTime(), preferredTimescale: 1000000000)
    }

    private func composeFrame(_ cameraFrame: CVPixelBuffer) -> CVPixelBuffer? {
        // 保存摄像头格式信息（第一帧）
        if frameCount == 0 {
            cameraPixelFormat = CVPixelBufferGetPixelFormatType(cameraFrame)
            cameraWidth = CVPixelBufferGetWidth(cameraFrame)
            cameraHeight = CVPixelBufferGetHeight(cameraFrame)
            print("摄像头格式: \(cameraWidth)x\(cameraHeight), pixelFormat: \(cameraPixelFormat)")
        }

        let outputSize = CGSize(
            width: outputWidth,
            height: outputHeight
        )

        let background = getBackgroundFrame()
        let cameraImage = processCameraFrame(cameraFrame)
        let composedImage = composeOutputImage(background: background, cameraFrame: cameraImage, outputSize: outputSize)

        guard let outputBuffer = makeOutputPixelBuffer() else {
            return nil
        }

        let outputRect = CGRect(origin: .zero, size: outputSize)
        ciContext.render(composedImage, to: outputBuffer, bounds: outputRect, colorSpace: CGColorSpaceCreateDeviceRGB())
        renderWatermark(to: outputBuffer)
        return outputBuffer
    }

    private func ensureSessionStarted() {
        writerStateLock.lock()
        defer { writerStateLock.unlock() }
        guard !hasStartedSession else { return }
        assetWriter?.startSession(atSourceTime: .zero)
        hasStartedSession = true
    }

    private func normalizedTime(for sourceTime: CMTime) -> CMTime {
        writerStateLock.lock()
        defer { writerStateLock.unlock() }

        if sessionStartTime == nil {
            sessionStartTime = sourceTime
        }

        guard let start = sessionStartTime else {
            return .invalid
        }

        return CMTimeSubtract(sourceTime, start)
    }

    private func copySampleBuffer(_ sampleBuffer: CMSampleBuffer, withPresentationTime presentationTime: CMTime) -> CMSampleBuffer? {
        var timingInfo = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(sampleBuffer),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: CMSampleBufferGetDecodeTimeStamp(sampleBuffer)
        )

        var updatedSampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleBufferOut: &updatedSampleBuffer
        )

        guard status == noErr else {
            return nil
        }

        return updatedSampleBuffer
    }

    private func makeOutputPixelBuffer() -> CVPixelBuffer? {
        if let pool = adaptor?.pixelBufferPool {
            var pixelBuffer: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
            if status == kCVReturnSuccess {
                return pixelBuffer
            }
        }

        var pixelBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(VideoConfiguration.outputPixelFormat),
            kCVPixelBufferWidthKey as String: outputWidth,
            kCVPixelBufferHeightKey as String: outputHeight,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            outputWidth,
            outputHeight,
            VideoConfiguration.outputPixelFormat,
            attrs as CFDictionary,
            &pixelBuffer
        )

        guard status == kCVReturnSuccess else {
            return nil
        }

        return pixelBuffer
    }

    private func composeOutputImage(background: CIImage, cameraFrame: CIImage?, outputSize: CGSize) -> CIImage {
        guard let cameraFrame else {
            return background
        }

        let outputRect = CGRect(origin: .zero, size: outputSize)
        let maskRect = cameraMaskRect(outputSize: outputSize)
        let cameraLayer = cameraLayerImage(from: cameraFrame, in: maskRect, outputRect: outputRect)
        let maskImage = maskImage(in: maskRect, outputRect: outputRect)
        let transparentCanvas = CIImage(color: .clear).cropped(to: outputRect)

        let maskedCamera: CIImage
        if let blendFilter = CIFilter(name: "CIBlendWithMask") {
            blendFilter.setValue(cameraLayer, forKey: kCIInputImageKey)
            blendFilter.setValue(transparentCanvas, forKey: kCIInputBackgroundImageKey)
            blendFilter.setValue(maskImage, forKey: kCIInputMaskImageKey)
            maskedCamera = blendFilter.outputImage?.cropped(to: outputRect) ?? cameraLayer
        } else {
            maskedCamera = cameraLayer
        }

        if case .none = backgroundMedia {
            return maskedCamera.composited(over: CIImage(color: .black).cropped(to: outputRect))
        }

        return maskedCamera.composited(over: background)
    }

    private func cameraMaskRect(outputSize: CGSize) -> CGRect {
        let outputWidth = outputSize.width
        let outputHeight = outputSize.height
        let maskSize = min(outputWidth, outputHeight) * maskSettings.size
        let maskWidth = maskSize * maskSettings.aspectRatio
        let maskHeight = maskSize
        let centerX = outputWidth / 2 + maskSettings.offsetX * outputWidth
        let centerYFromTop = outputHeight / 2 + maskSettings.offsetY * outputHeight

        return CGRect(
            x: centerX - maskWidth / 2,
            y: outputHeight - centerYFromTop - maskHeight / 2,
            width: maskWidth,
            height: maskHeight
        )
    }

    private func cameraLayerImage(from image: CIImage, in maskRect: CGRect, outputRect: CGRect) -> CIImage {
        let normalizedImage = image.transformed(by: CGAffineTransform(translationX: -image.extent.origin.x, y: -image.extent.origin.y))
        let scaleX = maskRect.width / normalizedImage.extent.width
        let scaleY = maskRect.height / normalizedImage.extent.height
        let scale = max(scaleX, scaleY)

        let scaledImage = normalizedImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let xOffset = maskRect.midX - scaledImage.extent.midX
        let yOffset = maskRect.midY - scaledImage.extent.midY

        return scaledImage
            .transformed(by: CGAffineTransform(translationX: xOffset, y: yOffset))
            .cropped(to: outputRect)
    }

    private func maskImage(in maskRect: CGRect, outputRect: CGRect) -> CIImage {
        switch maskSettings.shape {
        case .circle:
            return radialMaskImage(in: maskRect).cropped(to: outputRect)
        case .roundedSquare:
            return roundedRectangleMaskImage(in: maskRect).cropped(to: outputRect)
        }
    }

    private func radialMaskImage(in rect: CGRect) -> CIImage {
        let radius = min(rect.width, rect.height) / 2
        let blurInset = min(maskSettings.blurRadius, radius - 1)
        let innerRadius = max(radius - blurInset, 1)

        guard let filter = CIFilter(name: "CIRadialGradient") else {
            return CIImage(color: .white).cropped(to: rect)
        }

        filter.setValue(CIVector(x: rect.midX, y: rect.midY), forKey: "inputCenter")
        filter.setValue(innerRadius, forKey: "inputRadius0")
        filter.setValue(radius, forKey: "inputRadius1")
        filter.setValue(CIColor(red: 1, green: 1, blue: 1, alpha: 1), forKey: "inputColor0")
        filter.setValue(CIColor(red: 0, green: 0, blue: 0, alpha: 0), forKey: "inputColor1")

        let outputRect = CGRect(
            x: rect.origin.x - maskSettings.blurRadius,
            y: rect.origin.y - maskSettings.blurRadius,
            width: rect.width + maskSettings.blurRadius * 2,
            height: rect.height + maskSettings.blurRadius * 2
        )
        return (filter.outputImage ?? CIImage(color: .white)).cropped(to: outputRect)
    }

    private func roundedRectangleMaskImage(in rect: CGRect) -> CIImage {
        var image: CIImage

        if let generator = CIFilter(name: "CIRoundedRectangleGenerator") {
            generator.setValue(CIVector(cgRect: rect), forKey: "inputExtent")
            generator.setValue(maskSettings.cornerRadius, forKey: "inputRadius")
            generator.setValue(CIColor(red: 1, green: 1, blue: 1, alpha: 1), forKey: "inputColor")
            image = generator.outputImage ?? CIImage(color: .white).cropped(to: rect)
        } else {
            image = CIImage(color: .white).cropped(to: rect)
        }

        if maskSettings.blurRadius > 0,
           let blurFilter = CIFilter(name: "CIGaussianBlur") {
            blurFilter.setValue(image, forKey: kCIInputImageKey)
            blurFilter.setValue(maskSettings.blurRadius / 2, forKey: kCIInputRadiusKey)
            image = (blurFilter.outputImage ?? image).cropped(to: rect.insetBy(dx: -maskSettings.blurRadius, dy: -maskSettings.blurRadius))
        }

        return image
    }

    // 创建圆形蒙版
    private func createCircleMask(width: CGFloat, height: CGFloat, radius: CGFloat) -> CIImage {
        let size = CGFloat(max(width, height))
        let center = CGPoint(x: size / 2, y: size / 2)

        // 创建基础白色图像
        var maskImage = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: size, height: size))

        // 创建圆形蒙版路径
        let circlePath = CIImage(
            color: .white
        ).cropped(
            to: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        )

        // 如果需要边缘虚化
        if maskSettings.blurRadius > 0 {
            if let blurFilter = CIFilter(name: "CIGaussianBlur") {
                blurFilter.setValue(circlePath, forKey: kCIInputImageKey)
                blurFilter.setValue(maskSettings.blurRadius / 2, forKey: kCIInputRadiusKey)
                maskImage = blurFilter.outputImage ?? circlePath
            }
        } else {
            maskImage = circlePath
        }

        return maskImage
    }

    // 应用滤镜到摄像头画面
    private func applyFiltersToCameraFrame(_ image: CIImage) -> CIImage {
        var result = image

        // 应用滤镜预设
        if let filterName = filterSettings.preset.filterName,
           let filter = CIFilter(name: filterName) {
            filter.setValue(result, forKey: kCIInputImageKey)
            result = filter.outputImage ?? result
        }

        // 应用基础滤镜调整
        result = applyBasicFilters(to: result)

        return result
    }

    private func getBackgroundFrame() -> CIImage {
        switch backgroundMedia {
        case .none:
            return blackBackgroundImage()

        case .image:
            if let img = backgroundImage {
                return scaleImageToOutputSize(img)
            }
            return blackBackgroundImage()

        case .video:
            // 从 AVAssetReader 获取下一帧
            if let readerOutput = backgroundReaderOutput,
               let reader = backgroundAssetReader,
               reader.status == .reading {
                if let sampleBuffer = readerOutput.copyNextSampleBuffer(),
                   let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                    let image = CIImage(cvPixelBuffer: pixelBuffer)
                    return scaleImageToOutputSize(image)
                }
                // 如果读完了，重新开始
                if reader.status == .completed {
                    Task { @MainActor in
                        try? await recreateBackgroundReader()
                        backgroundAssetReader?.startReading()
                    }
                }
            } else if let reader = backgroundAssetReader, reader.status == .unknown {
                reader.startReading()
            }
            // 回退到黑色
            return blackBackgroundImage()
        }
    }

    private func blackBackgroundImage() -> CIImage {
        CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: renderSize))
    }

    private func scaleImageToOutputSize(_ image: CIImage) -> CIImage {
        let normalizedImage = image.transformed(
            by: CGAffineTransform(translationX: -image.extent.origin.x, y: -image.extent.origin.y)
        )
        let baseScale = max(renderSize.width / normalizedImage.extent.width, renderSize.height / normalizedImage.extent.height)
        let appliedScale = baseScale * backgroundScale
        let scaled = normalizedImage.transformed(by: CGAffineTransform(scaleX: appliedScale, y: appliedScale))
        let centered = scaled.transformed(
            by: CGAffineTransform(
                translationX: (renderSize.width - scaled.extent.width) / 2,
                y: (renderSize.height - scaled.extent.height) / 2
            )
        )

        return centered
            .cropped(to: CGRect(origin: .zero, size: renderSize))
            .composited(over: blackBackgroundImage())
    }

    private func processCameraFrame(_ pixelBuffer: CVPixelBuffer) -> CIImage? {
        let sourceImage: CIImage
        if isPortraitSegmentationEnabled,
           let segmentedImage = portraitSegmenter.segmentedImage(from: pixelBuffer) {
            sourceImage = segmentedImage
        } else {
            sourceImage = CIImage(cvPixelBuffer: pixelBuffer)
        }

        return filterSettings.apply(to: sourceImage, context: ciContext)
    }

    private func applyBasicFilters(to image: CIImage) -> CIImage {
        let basic = filterSettings.basic
        var result = image

        if basic.brightness != 0 || basic.contrast != 1.0 || basic.saturation != 1.0,
           let colorControls = CIFilter(name: "CIColorControls") {
            colorControls.setValue(result, forKey: kCIInputImageKey)
            colorControls.setValue(basic.brightness, forKey: kCIInputBrightnessKey)
            colorControls.setValue(basic.contrast, forKey: kCIInputContrastKey)
            colorControls.setValue(basic.saturation, forKey: kCIInputSaturationKey)
            result = colorControls.outputImage ?? result
        }

        if basic.exposure != 0,
           let exposureAdjust = CIFilter(name: "CIExposureAdjust") {
            exposureAdjust.setValue(result, forKey: kCIInputImageKey)
            exposureAdjust.setValue(basic.exposure, forKey: kCIInputEVKey)
            result = exposureAdjust.outputImage ?? result
        }

        if basic.temperature != 6500,
           let temperatureFilter = CIFilter(name: "CITemperatureAndTint") {
            temperatureFilter.setValue(result, forKey: kCIInputImageKey)
            temperatureFilter.setValue(CIVector(x: CGFloat(basic.temperature), y: 0), forKey: "inputNeutral")
            temperatureFilter.setValue(CIVector(x: 6500, y: 0), forKey: "inputTargetNeutral")
            result = temperatureFilter.outputImage ?? result
        }

        return result
    }

    private func renderComposedFrame(output: CVPixelBuffer, background: CIImage, cameraFrame: CIImage?) {
        // 渲染背景
        ciContext.render(background, to: output)

        // 应用蒙版并渲染摄像头画面
        if let camera = cameraFrame {
            renderCameraWithMask(to: output, cameraFrame: camera, background: background)
        }

        // 添加水印
        renderWatermark(to: output)
    }

    private func renderCameraWithMask(to output: CVPixelBuffer, cameraFrame: CIImage, background: CIImage) {
        // 计算蒙版区域
        let outputWidth = CGFloat(self.outputWidth)
        let outputHeight = CGFloat(self.outputHeight)

        let maskSize = min(outputWidth, outputHeight) * maskSettings.size
        let maskWidth = maskSize * maskSettings.aspectRatio
        let maskHeight = maskSize

        let maskRect = CGRect(
            x: (outputWidth - maskWidth) / 2 + maskSettings.offsetX * outputWidth,
            y: (outputHeight - maskHeight) / 2 + maskSettings.offsetY * outputHeight,
            width: maskWidth,
            height: maskHeight
        )

        // 缩放摄像头画面到蒙版尺寸
        let scaleX = maskWidth / cameraFrame.extent.width
        let scaleY = maskHeight / cameraFrame.extent.height
        let scale = max(scaleX, scaleY)

        let scaledCamera = cameraFrame.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        // 裁剪并居中
        let croppedCamera = scaledCamera.cropped(to: CGRect(
            x: (scaledCamera.extent.width - maskWidth) / 2,
            y: (scaledCamera.extent.height - maskHeight) / 2,
            width: maskWidth,
            height: maskHeight
        ))

        // 创建蒙版
        var maskImage: CIImage?

        switch maskSettings.shape {
        case .circle:
            // 圆形蒙版
            let circleRadius = min(maskWidth, maskHeight) / 2
            let center = CGPoint(x: circleRadius, y: circleRadius)
            maskImage = CIImage(
                color: .white
            ).cropped(
                to: CGRect(x: 0, y: 0, width: circleRadius * 2, height: circleRadius * 2)
            ).composited(
                over: CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: circleRadius * 2, height: circleRadius * 2))
            )

        case .roundedSquare:
            // 圆角方形蒙版
            maskImage = createRoundedSquareMask(width: maskWidth, height: maskHeight, cornerRadius: maskSettings.cornerRadius)
        }

        // 应用边缘虚化
        if maskSettings.blurRadius > 0, let mask = maskImage {
            if let blurFilter = CIFilter(name: "CIGaussianBlur") {
                blurFilter.setValue(mask, forKey: kCIInputImageKey)
                blurFilter.setValue(maskSettings.blurRadius, forKey: kCIInputRadiusKey)
                maskImage = blurFilter.outputImage
            }
        }

        // 使用蒙版合成摄像头画面
        if let mask = maskImage {
            // 这里需要将蒙版应用到摄像头画面，然后渲染到输出
            // 简化版本：直接渲染摄像头画面到蒙版区域
            ciContext.render(croppedCamera, to: output, bounds: maskRect, colorSpace: CGColorSpaceCreateDeviceRGB())
        }
    }

    private func createRoundedSquareMask(width: CGFloat, height: CGFloat, cornerRadius: CGFloat) -> CIImage {
        // 创建带圆角的矩形蒙版
        // 简化实现
        return CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }

    private func renderWatermark(to output: CVPixelBuffer) {
        let outputWidth = CGFloat(self.outputWidth)
        let outputHeight = CGFloat(self.outputHeight)
        let fontSize: CGFloat = {
            switch canvasAspectRatio {
            case .portrait9x16:
                return 9
            case .landscape16x9:
                return 14
            case .square1x1, .portrait3x4, .landscape4x3:
                return 11
            }
        }()

        // 锁定像素缓冲区
        CVPixelBufferLockBaseAddress(output, [])
        defer { CVPixelBufferUnlockBaseAddress(output, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(output) else { return }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(output)

        // 创建图形上下文
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: baseAddress,
            width: Int(outputWidth),
            height: Int(outputHeight),
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }

        // 水印文字
        let text = "Created by BeancurdHero" as NSString
        let padding: CGFloat = 16

        // 计算文字位置（右上角）
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.6)
        ]

        let textSize = text.size(withAttributes: attributes)
        let textX = outputWidth - textSize.width - padding
        let textY = padding

        // 绘制文字
        text.draw(at: CGPoint(x: textX, y: textY), withAttributes: attributes)
    }

    private func generateOutputURL(savePath: URL? = nil) -> URL {
        // 如果有指定保存路径，直接使用
        if let customPath = savePath {
            let filename = "Recording_\(Int(Date().timeIntervalSince1970)).mp4"
            return customPath.appendingPathComponent(filename)
        }

        // 否则使用 Movies 目录
        let moviesPath = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        let filename = "Recording_\(Int(Date().timeIntervalSince1970)).mp4"
        return moviesPath.appendingPathComponent(filename)
    }
}

// MARK: - Errors

enum VideoProcessorError: LocalizedError {
    case invalidImage
    case writerSetupFailed
    case frameCompositionFailed

    var errorDescription: String? {
        switch self {
        case .invalidImage: return "无效的图像"
        case .writerSetupFailed: return "写入器设置失败"
        case .frameCompositionFailed: return "帧合成失败"
        }
    }
}
