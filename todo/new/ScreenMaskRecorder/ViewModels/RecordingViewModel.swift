//
//  RecordingViewModel.swift
//  ScreenMaskRecorder
//
//  核心业务逻辑和状态管理
//

import Foundation
import SwiftUI
import AVFoundation
import Combine

/// 录制状态
enum RecordingState {
    case idle           // 空闲
    case recording      // 录制中
    case paused         // 暂停
    case processing     // 处理中

    var isRecording: Bool {
        self == .recording
    }
}

/// 背景媒体类型
enum BackgroundMediaType {
    case none
    case image(URL)
    case video(URL)
}

/// 录制完成事件
struct RecordingCompletedEvent {
    let url: URL
    let duration: TimeInterval
}

@MainActor
class RecordingViewModel: ObservableObject {
    // MARK: - Published Properties

    @Published var recordingState: RecordingState = .idle
    @Published var backgroundMedia: BackgroundMediaType = .none
    @Published var canvasAspectRatio: CanvasAspectRatio = .landscape16x9
    @Published var backgroundScale: CGFloat = 1.0
    @Published var maskSettings = MaskSettings.default
    @Published var filterSettings = FilterSettings.default
    @Published var isPortraitSegmentationEnabled = false

    // 录制输出
    @Published var outputURL: URL?
    @Published var savePath: URL? {
        didSet {
            // 保存用户选择的路径偏好
            if let path = savePath {
                UserDefaults.standard.set(path.path, forKey: "defaultSavePath")
            }
        }
    }
    @Published var lastRecordingURL: URL?
    @Published var showRecordingCompleteAlert = false

    // 摄像头相关
    @Published var cameraPreviewLayer: AVCaptureVideoPreviewLayer?
    @Published var currentFrame: CVPixelBuffer?
    @Published var isCameraAuthorized = false
    @Published var recordingDuration: TimeInterval = 0

    // MARK: - Initialization

    init() {
        // 从 UserDefaults 恢复保存路径
        if let savedPath = UserDefaults.standard.string(forKey: "defaultSavePath") {
            savePath = URL(fileURLWithPath: savedPath)
        }
        setupServices()
    }

    private var cameraService: CameraService?
    private var videoProcessor: VideoProcessor?
    private var portraitSegmenter: PortraitSegmenter?

    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Setup

    private func setupServices() {
        cameraService = CameraService()
        portraitSegmenter = PortraitSegmenter()
        videoProcessor = VideoProcessor()

        // 监听摄像头授权状态
        cameraService?.$isAuthorized
            .receive(on: DispatchQueue.main)
            .assign(to: &$isCameraAuthorized)

        // 监听预览层
        cameraService?.$previewLayer
            .receive(on: DispatchQueue.main)
            .assign(to: &$cameraPreviewLayer)

        cameraService?.$currentFrame
            .receive(on: DispatchQueue.main)
            .assign(to: &$currentFrame)
    }

    // MARK: - Camera Control

    func startCamera() async {
        await cameraService?.startSession()
    }

    func stopCamera() async {
        await cameraService?.stopSession()
    }

    // MARK: - Background Media

    func setBackgroundImage(_ url: URL) {
        backgroundMedia = .image(url)
    }

    func setBackgroundVideo(_ url: URL) {
        backgroundMedia = .video(url)
    }

    func clearBackground() {
        backgroundMedia = .none
    }

    // MARK: - Recording Control

    func startRecording() async throws {
        guard isCameraAuthorized else {
            throw RecordingError.cameraNotAuthorized
        }

        // 请求麦克风权限
        let audioAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if audioAuthStatus == .notDetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            print("麦克风权限请求结果: \(granted)")
        } else if audioAuthStatus == .denied || audioAuthStatus == .restricted {
            print("⚠️ 麦克风权限被拒绝，请在系统设置中允许")
        }

        // 先停止之前的录制（如果有）
        if recordingState == .recording || recordingState == .paused {
            try? await stopRecording()
        }

        recordingState = .recording
        recordingDuration = 0

        // 启动计时器
        startTimer()

        // 如果没有设置保存路径，使用默认 Movies 目录
        if savePath == nil {
            let moviesPath = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            savePath = moviesPath
        }

        // 启动视频处理
        try await videoProcessor?.startRecording(
            backgroundMedia: backgroundMedia,
            canvasAspectRatio: canvasAspectRatio,
            backgroundScale: backgroundScale,
            maskSettings: maskSettings,
            filterSettings: filterSettings,
            isPortraitSegmentationEnabled: isPortraitSegmentationEnabled,
            savePath: savePath
        )

        cameraService?.onVideoSample = { [weak videoProcessor] sampleBuffer in
            videoProcessor?.processVideoSample(sampleBuffer)
        }
        cameraService?.onAudioSample = { [weak videoProcessor] sampleBuffer in
            videoProcessor?.processAudioSample(sampleBuffer)
        }
    }

    func stopRecording() async throws -> URL? {
        print("RecordingViewModel: 停止录制，当前状态: \(recordingState)")
        recordingState = .processing
        stopTimer()
        cameraService?.stopStreamingCallbacks()

        // 传入保存路径
        let url = try await videoProcessor?.stopRecording(savePath: savePath)
        outputURL = url
        lastRecordingURL = url
        recordingState = .idle
        recordingDuration = 0

        print("RecordingViewModel: 录制已停止，状态重置为 idle")

        // 显示完成提示
        if url != nil {
            showRecordingCompleteAlert = true
        }

        return url
    }

    // 选择保存路径
    func chooseSavePath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.title = "选择视频保存位置"
        panel.prompt = "选择"

        if panel.runModal() == .OK, let url = panel.url {
            savePath = url
        }
    }

    // 在 Finder 中显示录制的视频
    func showRecordingInFinder() {
        guard let url = lastRecordingURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func pauseRecording() async {
        recordingState = .paused
        stopTimer()
        await videoProcessor?.pauseRecording()
    }

    func resumeRecording() async {
        recordingState = .recording
        startTimer()
        await videoProcessor?.resumeRecording()
    }

    // MARK: - Timer

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.recordingDuration += 0.1
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Format Duration

    var formattedDuration: String {
        let minutes = Int(recordingDuration) / 60
        let seconds = Int(recordingDuration) % 60
        let milliseconds = Int((recordingDuration.truncatingRemainder(dividingBy: 1)) * 100)
        return String(format: "%02d:%02d.%02d", minutes, seconds, milliseconds)
    }
}

// MARK: - Errors

enum RecordingError: LocalizedError {
    case cameraNotAuthorized
    case noCameraAvailable
    case recordingFailed(String)
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .cameraNotAuthorized:
            return "未授权摄像头访问"
        case .noCameraAvailable:
            return "没有可用的摄像头"
        case .recordingFailed(let message):
            return "录制失败: \(message)"
        case .exportFailed(let message):
            return "导出失败: \(message)"
        }
    }
}
