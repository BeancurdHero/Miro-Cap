//
//  FilterPanel.swift
//  ScreenMaskRecorder
//
//  滤镜选择面板
//

import SwiftUI

struct FilterPanel: View {
    @EnvironmentObject var viewModel: RecordingViewModel
    @Binding var offset: CGSize
    let onClose: () -> Void
    @State private var dragStartOffset: CGSize?

    var body: some View {
        VStack(spacing: 0) {
            titleBar

            Divider()

            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 24) {
                    // 预设滤镜
                    presetFiltersSection

                    Divider()

                    // 基础调整
                    basicAdjustmentsSection
                }
                .padding()
            }
            .scrollIndicators(.visible)
        }
        .frame(width: 500, height: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.2), radius: 24, x: 0, y: 12)
    }

    private var titleBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("滤镜")
                    .font(.headline)
                Text("拖动标题栏可移动，调整时预览会实时更新")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Image(systemName: "hand.draw")
                .foregroundColor(.secondary)

            Button("完成") {
                onClose()
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.95))
        .contentShape(Rectangle())
        .gesture(
            DragGesture()
                .onChanged { value in
                    if dragStartOffset == nil {
                        dragStartOffset = offset
                    }

                    let start = dragStartOffset ?? .zero
                    offset = CGSize(
                        width: start.width + value.translation.width,
                        height: start.height + value.translation.height
                    )
                }
                .onEnded { _ in
                    dragStartOffset = nil
                }
        )
    }

    // MARK: - Preset Filters

    private var presetFiltersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("预设滤镜")
                .font(.headline)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(FilterPreset.allCases, id: \.self) { preset in
                        presetFilterButton(preset)
                    }
                }
                .padding(.horizontal, 4)
            }
        }
    }

    private func presetFilterButton(_ preset: FilterPreset) -> some View {
        Button {
            viewModel.filterSettings.preset = preset
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .frame(width: 80, height: 80)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(
                                    viewModel.filterSettings.preset == preset ?
                                    Color.accentColor : Color.clear,
                                    lineWidth: 3
                                )
                        )

                    Image(systemName: preset.icon)
                        .font(.system(size: 32))
                        .foregroundColor(.primary)
                }

                Text(preset.rawValue)
                    .font(.caption)
                    .foregroundColor(viewModel.filterSettings.preset == preset ? .accentColor : .primary)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Basic Adjustments

    private var basicAdjustmentsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("基础调整")
                .font(.headline)

            // 亮度
            adjustmentSlider(
                name: "亮度",
                icon: "sun.max",
                value: $viewModel.filterSettings.basic.brightness,
                range: -1.0...1.0
            )

            // 对比度
            adjustmentSlider(
                name: "对比度",
                icon: "circle.lefthalf.filled",
                value: $viewModel.filterSettings.basic.contrast,
                range: 0.0...4.0
            )

            // 饱和度
            adjustmentSlider(
                name: "饱和度",
                icon: "paintpalette",
                value: $viewModel.filterSettings.basic.saturation,
                range: 0.0...2.0
            )

            // 色温
            adjustmentSlider(
                name: "色温",
                icon: "thermometer",
                value: $viewModel.filterSettings.basic.temperature,
                range: 3000...8000
            )

            // 曝光
            adjustmentSlider(
                name: "曝光",
                icon: "aperture",
                value: $viewModel.filterSettings.basic.exposure,
                range: -5.0...5.0
            )

            adjustmentSlider(
                name: "镜头缩放",
                icon: "plus.magnifyingglass",
                value: $viewModel.filterSettings.zoom,
                range: 0.4...1.4,
                valueFormat: "%.2fx"
            )

            adjustmentSlider(
                name: "鱼眼强度",
                icon: "camera.macro",
                value: $viewModel.filterSettings.fisheyeIntensity,
                range: 0.4...2.0,
                valueFormat: "%.2fx"
            )

            if viewModel.filterSettings.preset != .fisheye {
                Text("“鱼眼强度” 仅在选中鱼眼预设时生效")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // 重置按钮
            HStack {
                Spacer()
                Button("重置全部") {
                    viewModel.filterSettings = .default
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func adjustmentSlider(
        name: String,
        icon: String,
        value: Binding<Float>,
        range: ClosedRange<Float>,
        valueFormat: String = "%.2f"
    ) -> some View {
        HStack {
            Image(systemName: icon)
                .frame(width: 24)
                .foregroundColor(.secondary)

            Text(name)
                .frame(width: 60, alignment: .leading)

            Slider(value: value, in: range)
                .frame(width: 200)

            Text(String(format: valueFormat, value.wrappedValue))
                .frame(width: 50, alignment: .trailing)
                .foregroundColor(.secondary)
                .font(.system(.body, design: .monospaced))
        }
    }
}

// #Preview is only available in Xcode
// #Preview {
//     FilterPanel(offset: .constant(.zero), onClose: {})
//         .environmentObject(RecordingViewModel())
// }
