//
//  MainView.swift
//  ScreenMaskRecorder
//
//  主界面视图
//

import SwiftUI
import AVFoundation
import AVKit
import UniformTypeIdentifiers
import CoreImage

// 文件选择器类型
enum FilePickerType {
    case image
    case video
}

struct MainView: View {
    @StateObject private var viewModel = RecordingViewModel()
    @State private var showingFilterPanel = false
    @State private var showingSettings = false
    @State private var showingFilePicker = false
    @State private var filePickerType: FilePickerType = .image
    @State private var filterPanelOffset = CGSize.zero

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                // 应用标题 - Miro Cap
                Text("Miro Cap")
                    .font(.custom("Nanum Pen Script", size: 31))
                    .foregroundColor(.primary)
                    .padding(.top, 0)
                    .padding(.bottom, 25)

                // 录屏预览区域
                RecordingPreviewView()
                    .environmentObject(viewModel)
                    .aspectRatio(16/9, contentMode: .fit)
                    .background(Color.black)
                    .cornerRadius(12)

                // 控制按钮
                controlButtons

                Divider()
                    .padding(.vertical, 8)

                // 控制面板
                controlPanel
            }
            .padding(24)
            .frame(minWidth: 900, minHeight: 700)

            if showingFilterPanel {
                FilterPanel(offset: $filterPanelOffset) {
                    showingFilterPanel = false
                }
                .environmentObject(viewModel)
                .padding(.top, 24)
                .padding(.trailing, 24)
                .offset(filterPanelOffset)
                .zIndex(1)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: showingFilterPanel)
        .onAppear {
            Task {
                await viewModel.startCamera()
            }
        }
        .alert("录制完成", isPresented: $viewModel.showRecordingCompleteAlert) {
            Button("好的") {
                viewModel.showRecordingCompleteAlert = false
            }
            Button("在 Finder 中显示") {
                viewModel.showRecordingInFinder()
                viewModel.showRecordingCompleteAlert = false
            }
        } message: {
            if let url = viewModel.lastRecordingURL {
                Text("视频已保存到:\n\(url.path)")
                    .font(.system(.body, design: .monospaced))
            }
        }
    }

    // MARK: - Control Buttons

    private var controlButtons: some View {
        HStack(spacing: 16) {
            // 上传背景
            Menu {
                Button {
                    showImagePicker()
                } label: {
                    Label("选择图片", systemImage: "photo")
                }

                Button {
                    showVideoPicker()
                } label: {
                    Label("选择视频", systemImage: "video")
                }

                Divider()

                if case .none = viewModel.backgroundMedia {
                    EmptyView()
                } else {
                    Button(role: .destructive) {
                        viewModel.clearBackground()
                    } label: {
                        Label("清除背景", systemImage: "trash")
                    }
                }
            } label: {
                Label("上传背景", systemImage: "folder")
            }
            .buttonStyle(.borderedProminent)

            Spacer()

            // 录制/停止
            if viewModel.recordingState.isRecording {
                Button {
                    Task {
                        try? await viewModel.stopRecording()
                    }
                } label: {
                    Label("停止", systemImage: "stop.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            } else {
                Button {
                    Task {
                        try? await viewModel.startRecording()
                    }
                } label: {
                    Label("录制", systemImage: "record.circle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.isCameraAuthorized)
            }

            // 录制时长
            if viewModel.recordingState != .idle {
                Text(viewModel.formattedDuration)
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: 80)
            }
        }
        .padding(.horizontal)
    }

    // MARK: - Control Panel

    private var controlPanel: some View {
        VStack(spacing: 16) {
            // 蒙版控制
            maskControls

            Divider()

            // 其他控制
            HStack(spacing: 16) {
                // 保存路径按钮
                Button {
                    viewModel.chooseSavePath()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                        if let path = viewModel.savePath {
                            Text(path.lastPathComponent)
                                .lineLimit(1)
                        } else {
                            Text("保存到 Movies")
                        }
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10))
                    }
                }
                .buttonStyle(.bordered)
                .help("选择视频保存位置")

                // 滤镜按钮
                Button {
                    showingFilterPanel.toggle()
                } label: {
                    Label("滤镜", systemImage: "camera.filters")
                }
                .buttonStyle(.bordered)

                // 人像去除开关
                Toggle("人像背景去除", isOn: $viewModel.isPortraitSegmentationEnabled)
                    .toggleStyle(.switch)

                Spacer()

                // 设置按钮
                Button {
                    showingSettings = true
                } label: {
                    Label("设置", systemImage: "gearshape")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }

    // MARK: - File Picker

    private func showImagePicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image, .jpeg, .png, .gif]
        panel.title = "选择背景图片"
        panel.prompt = "选择"

        if panel.runModal() == .OK, let url = panel.url {
            viewModel.setBackgroundImage(url)
        }
    }

    private func showVideoPicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.movie, .mpeg, .mpeg2Video, .mpeg4Movie, .quickTimeMovie]
        panel.title = "选择背景视频"
        panel.prompt = "选择"

        if panel.runModal() == .OK, let url = panel.url {
            viewModel.setBackgroundVideo(url)
        }
    }

    // MARK: - Mask Controls

    private var maskControls: some View {
        HStack(spacing: 24) {
            // 蒙版形状
            VStack(alignment: .leading, spacing: 8) {
                Text("形状")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Picker("蒙版形状", selection: $viewModel.maskSettings.shape) {
                    ForEach(MaskShape.allCases, id: \.self) { shape in
                        Text(shape.rawValue).tag(shape)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
            }

            // 大小
            VStack(alignment: .leading, spacing: 8) {
                Text("大小")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Slider(
                    value: $viewModel.maskSettings.size,
                    in: 0.1...0.9
                )
                .frame(width: 120)
            }

            // 虚化
            VStack(alignment: .leading, spacing: 8) {
                Text("边缘虚化")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Slider(
                    value: $viewModel.maskSettings.blurRadius,
                    in: 0...50
                )
                .frame(width: 120)
            }

            Spacer()

            // 重置按钮
            Button {
                viewModel.maskSettings = .default
            } label: {
                Text("重置")
            }
            .buttonStyle(.bordered)
        }
    }
}

// MARK: - Recording Preview View

struct RecordingPreviewView: View {
    @EnvironmentObject var viewModel: RecordingViewModel
    @State private var currentDragOffset = CGSize.zero
    @State private var isDragging = false
    @State private var dragStartPosition = CGPoint.zero

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // 背景层
                backgroundLayer

                // 摄像头蒙版层 - 可拖动
                cameraMaskLayer(
                    canvasSize: geometry.size,
                    dragOffset: currentDragOffset,
                    isDragging: $isDragging
                )
                    .simultaneousGesture(
                        DragGesture(coordinateSpace: .local)
                            .onChanged { value in
                                if dragStartPosition == .zero {
                                    dragStartPosition = value.startLocation
                                }
                                isDragging = true
                                currentDragOffset = value.translation
                            }
                            .onEnded { value in
                                isDragging = false
                                // 保存最终位置
                                let newX = viewModel.maskSettings.offsetX + value.translation.width / geometry.size.width
                                let newY = viewModel.maskSettings.offsetY + value.translation.height / geometry.size.height
                                viewModel.maskSettings.offsetX = max(-0.45, min(0.45, newX))
                                viewModel.maskSettings.offsetY = max(-0.45, min(0.45, newY))
                                currentDragOffset = .zero
                                dragStartPosition = .zero
                            }
                    )

                // 水印
                watermarkOverlay

                // 未授权提示
                if !viewModel.isCameraAuthorized {
                    VStack {
                        Image("camera.metering.matrix")
                            .font(.system(size: 60))
                            .foregroundColor(.white.opacity(0.3))
                        Text("请授权摄像头访问")
                            .foregroundColor(.white)
                    }
                }
            }
        }
    }

    // MARK: - Background Layer

    private var backgroundLayer: some View {
        Group {
            switch viewModel.backgroundMedia {
            case .none:
                Color.black
            case .image(let url):
                Image(nsImage: NSImage(contentsOf: url) ?? NSImage())
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            case .video(let url):
                VideoPlayerView(url: url)
            }
        }
    }

    // MARK: - Camera Mask Layer

    private func cameraMaskLayer(
        canvasSize: CGSize,
        dragOffset: CGSize,
        isDragging: Binding<Bool>
    ) -> some View {
        let size = min(canvasSize.width, canvasSize.height) * viewModel.maskSettings.size
        let width = size * viewModel.maskSettings.aspectRatio
        let height = size
        let blurRadius = viewModel.maskSettings.blurRadius
        let isCircle = viewModel.maskSettings.shape == .circle
        let cornerRadius = viewModel.maskSettings.cornerRadius
        let centerX = canvasSize.width / 2 + viewModel.maskSettings.offsetX * canvasSize.width + dragOffset.width
        let centerY = canvasSize.height / 2 + viewModel.maskSettings.offsetY * canvasSize.height + dragOffset.height

        return ZStack {
            // 蒙版背景（半透明）
            if isCircle {
                Circle()
                    .fill(Color.white.opacity(0.2))
                    .frame(width: width, height: height)
            } else {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.white.opacity(0.2))
                    .frame(width: width, height: height)
            }

            // 摄像头预览
            if let frame = viewModel.currentFrame {
                CameraFrameView(pixelBuffer: frame, filterSettings: viewModel.filterSettings)
                    .clipShape(
                        isCircle ?
                        AnyShape(Circle()) :
                        AnyShape(RoundedRectangle(cornerRadius: cornerRadius))
                    )
                    .frame(width: width, height: height)
            } else if let previewLayer = viewModel.cameraPreviewLayer {
                CameraPreviewView(previewLayer: previewLayer, filterSettings: viewModel.filterSettings)
                    .clipShape(
                        isCircle ?
                        AnyShape(Circle()) :
                        AnyShape(RoundedRectangle(cornerRadius: cornerRadius))
                    )
                    .frame(width: width, height: height)
            }

            // 边缘虚化效果 - 使用半透明边框实现柔和边缘
            if blurRadius > 0 {
                if isCircle {
                    Circle()
                        .stroke(Color.white.opacity(min(0.5, blurRadius / 100)), lineWidth: blurRadius / 3)
                        .blur(radius: blurRadius / 4)
                        .frame(width: width, height: height)
                } else {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(Color.white.opacity(min(0.5, blurRadius / 100)), lineWidth: blurRadius / 3)
                        .blur(radius: blurRadius / 4)
                        .frame(width: width, height: height)
                }
            }

            // 拖动提示图标
            if !isDragging.wrappedValue {
                Image(systemName: "hand.draw")
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.6))
                    .padding(4)
                    .background(Circle().fill(Color.black.opacity(0.4)))
                    .offset(y: height / 2 + 25)
            }
        }
        .frame(width: width, height: height)
        .position(x: centerX, y: centerY)
        .onHover { hovering in
            if hovering {
                NSCursor.openHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }

    // MARK: - Watermark Overlay

    private var watermarkOverlay: some View {
        VStack {
            HStack {
                Spacer()
                Text("Created by BeancurdHero")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
                    .padding(16)
            }
            Spacer()
        }
    }
}

// MARK: - Camera Preview Layer View

struct CameraFrameView: View {
    let pixelBuffer: CVPixelBuffer
    var filterSettings: FilterSettings = .default

    var body: some View {
        if let image = CameraFrameRenderer.shared.image(from: pixelBuffer, filterSettings: filterSettings) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            Color.black
        }
    }
}

final class CameraFrameRenderer {
    static let shared = CameraFrameRenderer()

    private let ciContext = CIContext()

    func image(from pixelBuffer: CVPixelBuffer, filterSettings: FilterSettings) -> NSImage? {
        let ciImage = filterSettings.apply(to: CIImage(cvPixelBuffer: pixelBuffer), context: ciContext)

        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: ciImage.extent.width, height: ciImage.extent.height))
    }
}

// 滤镜修饰符 - 应用滤镜效果到视图
struct FilterEffect: ViewModifier {
    let filterSettings: FilterSettings

    func body(content: Content) -> some View {
        let basic = filterSettings.basic
        let preset = filterSettings.preset

        // 基础调整
        let adjustedContent = content
            .brightness(Double(basic.brightness))
            .contrast(Double(basic.contrast))
            .saturation(Double(basic.saturation))

        // 预设滤镜效果
        switch preset {
        case .none:
            adjustedContent
        case .noir:
            adjustedContent
                .saturation(0)
                .contrast(1.2)
        case .vintage:
            adjustedContent
                .saturation(0.7)
                .brightness(0.1)
                .colorMultiply(Color.yellow.opacity(0.2))
        case .warm:
            adjustedContent
                .colorMultiply(Color.orange.opacity(0.15))
                .saturation(1.2)
        case .cool:
            adjustedContent
                .colorMultiply(Color.blue.opacity(0.1))
                .saturation(0.9)
        case .dreamy:
            adjustedContent
                .blur(radius: 0.5)
                .brightness(0.1)
        case .fisheye:
            adjustedContent
        }
    }
}

extension View {
    func filterEffect(_ filterSettings: FilterSettings) -> some View {
        self.modifier(FilterEffect(filterSettings: filterSettings))
    }
}

// 摄像头预览组件（带滤镜支持）
struct CameraPreviewView: View {
    let previewLayer: AVCaptureVideoPreviewLayer
    var filterSettings: FilterSettings = .default

    var body: some View {
        CameraPreviewLayerView(previewLayer: previewLayer)
    }
}

struct CameraPreviewLayerView: NSViewRepresentable {
    let previewLayer: AVCaptureVideoPreviewLayer

    func makeNSView(context: Context) -> NSView {
        let view = PreviewHostingView()
        view.configure(with: previewLayer)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let hostingView = nsView as? PreviewHostingView {
            hostingView.configure(with: previewLayer)
        }
    }
}

final class PreviewHostingView: NSView {
    private weak var hostedPreviewLayer: AVCaptureVideoPreviewLayer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
    }

    func configure(with previewLayer: AVCaptureVideoPreviewLayer) {
        guard hostedPreviewLayer !== previewLayer else {
            needsLayout = true
            return
        }

        hostedPreviewLayer?.removeFromSuperlayer()
        hostedPreviewLayer = previewLayer
        previewLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(previewLayer)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        hostedPreviewLayer?.frame = bounds
    }
}

// MARK: - Video Player View

struct VideoPlayerView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSView {
        let player = AVPlayer()
        let playerLayer = AVPlayerLayer(player: player)
        let view = PlayerHostingView()
        view.configure(with: playerLayer)

        context.coordinator.player = player
        context.coordinator.playerLayer = playerLayer

        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        player.play()

        // 循环播放
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { _ in
            player.seek(to: .zero)
            player.play()
        }

        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let hostingView = nsView as? PlayerHostingView,
           let playerLayer = context.coordinator.playerLayer {
            hostingView.configure(with: playerLayer)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator {
        var player: AVPlayer?
        var playerLayer: AVPlayerLayer?

        deinit {
            player?.pause()
        }
    }
}

final class PlayerHostingView: NSView {
    private weak var hostedPlayerLayer: AVPlayerLayer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
    }

    func configure(with playerLayer: AVPlayerLayer) {
        guard hostedPlayerLayer !== playerLayer else {
            needsLayout = true
            return
        }

        hostedPlayerLayer?.removeFromSuperlayer()
        hostedPlayerLayer = playerLayer
        playerLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(playerLayer)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        hostedPlayerLayer?.frame = bounds
    }
}

// #Preview is only available in Xcode
// #Preview {
//     MainView()
// }
