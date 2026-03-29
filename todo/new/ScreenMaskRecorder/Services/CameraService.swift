//
//  CameraService.swift
//  ScreenMaskRecorder
//
//  摄像头捕获服务
//

import Foundation
import AVFoundation
import Combine
import CoreVideo
import QuartzCore

/// 摄像头位置
enum CameraPosition {
    case front
    case back
}

@MainActor
class CameraService: NSObject, ObservableObject {
    // MARK: - Published Properties

    @Published var isAuthorized = false
    @Published var isRunning = false
    @Published var previewLayer: AVCaptureVideoPreviewLayer?
    @Published var currentFrame: CVPixelBuffer?

    // MARK: - Private Properties

    private var captureSession: AVCaptureSession?
    private var videoOutput: AVCaptureVideoDataOutput?
    private var audioOutput: AVCaptureAudioDataOutput?
    private let sessionQueue = DispatchQueue(label: "com.screenmaskrecorder.camera")
    nonisolated(unsafe) private var hasLoggedFirstVideoFrame = false
    nonisolated(unsafe) private var hasLoggedFirstAudioSample = false
    nonisolated(unsafe) private var lastPreviewDispatchTime: CFTimeInterval = 0
    nonisolated(unsafe) private var previewUpdatePending = false
    private let previewUpdateInterval: CFTimeInterval = 1.0 / 12.0
    nonisolated(unsafe) var onVideoSample: ((CMSampleBuffer) -> Void)?
    nonisolated(unsafe) var onAudioSample: ((CMSampleBuffer) -> Void)?

    // MARK: - Initialization

    override init() {
        super.init()
        checkAuthorization()
    }

    // MARK: - Authorization

    private func checkAuthorization() {
        // 检查摄像头权限
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            print("✓ 摄像头权限已授予")
            isAuthorized = true
        case .notDetermined:
            print("摄像头权限未决定，准备请求授权")
            requestAuthorization()
        case .denied, .restricted:
            print("⚠️ 摄像头权限被拒绝 - 请在系统设置中允许")
            isAuthorized = false
        default:
            isAuthorized = false
        }

        // 检查麦克风权限
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            print("麦克风权限已授予")
        case .notDetermined:
            requestAudioAuthorization()
        case .denied, .restricted:
            print("⚠️ 麦克风权限被拒绝 - 请在系统设置中允许")
        @unknown default:
            print("麦克风权限状态未知")
        }
    }

    private func requestAudioAuthorization() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            if granted {
                print("✓ 麦克风权限已授予")
            } else {
                print("✗ 麦克风权限被拒绝")
            }
        }
    }

    private func requestAuthorization() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            Task { @MainActor in
                self?.isAuthorized = granted
                print("摄像头权限请求结果: \(granted)")
                if granted {
                    await self?.startSession()
                }
            }
        }
    }

    // MARK: - Session Control

    func startSession() async {
        guard isAuthorized else { return }

        await setupCaptureSession()
        captureSession?.startRunning()
        isRunning = true
        print("startSession 完成，isRunning=\(captureSession?.isRunning ?? false)")
    }

    func stopSession() async {
        captureSession?.stopRunning()
        isRunning = false
    }

    // MARK: - Setup

    private func setupCaptureSession() async {
        sessionQueue.sync {
            // 避免重复创建
            if captureSession != nil { return }

            let session = AVCaptureSession()
            session.sessionPreset = .high

            let discoveryDeviceTypes: [AVCaptureDevice.DeviceType]
            if #available(macOS 14.0, *) {
                discoveryDeviceTypes = [
                    .builtInWideAngleCamera,
                    .continuityCamera,
                    .external
                ]
            } else {
                discoveryDeviceTypes = [
                    .builtInWideAngleCamera
                ]
            }

            let discoverySession = AVCaptureDevice.DiscoverySession(
                deviceTypes: discoveryDeviceTypes,
                mediaType: .video,
                position: .unspecified
            )

            // 获取默认摄像头
            guard let camera = AVCaptureDevice.default(for: .video) ?? discoverySession.devices.first else {
                print("无法获取摄像头设备")
                return
            }

            print("使用摄像头设备: \(camera.localizedName)")

            do {
                let input = try AVCaptureDeviceInput(device: camera)

                if session.canAddInput(input) {
                    session.addInput(input)
                }

                // 配置视频输出
                let output = AVCaptureVideoDataOutput()
                output.setSampleBufferDelegate(self, queue: sessionQueue)
                output.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                ]

                if session.canAddOutput(output) {
                    session.addOutput(output)
                }

                self.videoOutput = output

                // 配置音频输出（麦克风）
                if let microphone = AVCaptureDevice.default(for: .audio) {
                    let audioInput = try AVCaptureDeviceInput(device: microphone)
                    if session.canAddInput(audioInput) {
                        session.addInput(audioInput)
                    }

                    let audioOut = AVCaptureAudioDataOutput()
                    audioOut.setSampleBufferDelegate(self, queue: sessionQueue)

                    if session.canAddOutput(audioOut) {
                        session.addOutput(audioOut)
                    }

                    self.audioOutput = audioOut
                }

                // 创建预览层
                let previewLayer = AVCaptureVideoPreviewLayer(session: session)
                previewLayer.videoGravity = .resizeAspectFill
                self.previewLayer = previewLayer

                self.captureSession = session
                print("摄像头会话配置完成")

            } catch {
                print("摄像头输入配置失败: \(error)")
            }
        }
    }

    func stopStreamingCallbacks() {
        onVideoSample = nil
        onAudioSample = nil
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraService: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // 处理视频帧
        if output is AVCaptureVideoDataOutput {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            onVideoSample?(sampleBuffer)

            if !hasLoggedFirstVideoFrame {
                hasLoggedFirstVideoFrame = true
                print("✓ 收到第一帧视频: \(CVPixelBufferGetWidth(pixelBuffer))x\(CVPixelBufferGetHeight(pixelBuffer))")
            }

            let now = CACurrentMediaTime()
            guard !previewUpdatePending, now - lastPreviewDispatchTime >= previewUpdateInterval else {
                return
            }

            previewUpdatePending = true
            lastPreviewDispatchTime = now

            Task { @MainActor in
                self.currentFrame = pixelBuffer
                self.previewUpdatePending = false
            }
        }
        // 处理音频样本
        else if output is AVCaptureAudioDataOutput {
            onAudioSample?(sampleBuffer)
            if !hasLoggedFirstAudioSample {
                hasLoggedFirstAudioSample = true
                print("✓ 收到第一帧音频")
            }
        }
    }

    nonisolated func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // 只在开始时打印一次
    }
}
