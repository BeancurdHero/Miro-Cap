//
//  BackgroundUploadView.swift
//  ScreenMaskRecorder
//
//  背景上传/预览视图
//

import SwiftUI
import AVFoundation
import AVKit

struct BackgroundUploadView: View {
    @EnvironmentObject var viewModel: RecordingViewModel
    @State private var isDragging = false

    var body: some View {
        VStack(spacing: 16) {
            Text("选择背景")
                .font(.headline)

            // 拖拽区域
            dropZone

            // 或分割线
            HStack {
                Rectangle()
                    .fill(Color.secondary.opacity(0.3))
                    .frame(height: 1)
                Text("或")
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                Rectangle()
                    .fill(Color.secondary.opacity(0.3))
                    .frame(height: 1)
            }

            // 按钮选择
            HStack(spacing: 16) {
                Button {
                    selectImage()
                } label: {
                    Label("选择图片", systemImage: "photo")
                }
                .buttonStyle(.bordered)

                Button {
                    selectVideo()
                } label: {
                    Label("选择视频", systemImage: "video")
                }
                .buttonStyle(.bordered)

                if case .none = viewModel.backgroundMedia {
                    EmptyView()
                } else {
                    Button {
                        viewModel.clearBackground()
                    } label: {
                        Label("清除", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
            }

            // 预览
            previewSection
        }
        .padding()
    }

    // MARK: - Drop Zone

    private var dropZone: some View {
        VStack(spacing: 12) {
            Image(systemName: isDragging ? "arrow.down.doc.fill" : "arrow.down.doc")
                .font(.system(size: 48))
                .foregroundColor(isDragging ? .accentColor : .secondary)

            Text(isDragging ? "释放文件" : "拖拽图片或视频到此处")
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 120)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(
                            isDragging ? Color.accentColor : Color.secondary.opacity(0.3),
                            lineWidth: 2
                        )
                )
        )
        .onDrop(of: [.fileURL], isTargeted: $isDragging) { providers in
            handleDrop(providers: providers)
            return true
        }
    }

    // MARK: - Preview Section

    @ViewBuilder
    private var previewSection: some View {
        switch viewModel.backgroundMedia {
        case .none:
            EmptyView()
        case .image(let url):
            VStack(alignment: .leading, spacing: 8) {
                Text("图片预览")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Image(nsImage: NSImage(contentsOf: url) ?? NSImage())
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 150)
                    .cornerRadius(8)
            }
        case .video(let url):
            VStack(alignment: .leading, spacing: 8) {
                Text("视频预览")
                    .font(.caption)
                    .foregroundColor(.secondary)
                VideoPlayerPreview(url: url)
                    .frame(height: 150)
                    .cornerRadius(8)
            }
        }
    }

    // MARK: - Actions

    private func selectImage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]

        if panel.runModal() == .OK, let url = panel.url {
            viewModel.setBackgroundImage(url)
        }
    }

    private func selectVideo() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.movie]

        if panel.runModal() == .OK, let url = panel.url {
            viewModel.setBackgroundVideo(url)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) {
        guard let provider = providers.first else { return }

        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else { return }

            Task { @MainActor in
                if utType(url: url).conforms(to: .image) {
                    viewModel.setBackgroundImage(url)
                } else if utType(url: url).conforms(to: .movie) {
                    viewModel.setBackgroundVideo(url)
                }
            }
        }
    }

    private func utType(url: URL) -> UTType {
        guard let utType = UTType(filenameExtension: url.pathExtension) else {
            return UTType.data
        }
        return utType
    }
}

// MARK: - Video Player Preview

struct VideoPlayerPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true

        let player = AVPlayer()
        let playerLayer = AVPlayerLayer(player: player)
        playerLayer.videoGravity = .resizeAspectFill
        view.layer = playerLayer

        context.coordinator.player = player
        context.coordinator.playerLayer = playerLayer

        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        player.play()
        player.volume = 0  // 预览时静音

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
        if let playerLayer = nsView.layer as? AVPlayerLayer {
            playerLayer.frame = nsView.bounds
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

// #Preview is only available in Xcode
// #Preview {
//     BackgroundUploadView()
//         .environmentObject(RecordingViewModel())
// }
