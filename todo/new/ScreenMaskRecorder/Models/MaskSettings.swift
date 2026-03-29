//
//  MaskSettings.swift
//  ScreenMaskRecorder
//
//  蒙版配置模型
//

import Foundation
import CoreGraphics

/// 蒙版形状
enum MaskShape: String, CaseIterable {
    case circle = "圆形"
    case roundedSquare = "圆角方形"

    var icon: String {
        switch self {
        case .circle: return "circle"
        case .roundedSquare: return "square.rounded"
        }
    }
}

/// 蒙版配置
struct MaskSettings {
    var shape: MaskShape = .circle
    var size: CGFloat = 0.5        // 相对于画面大小 (0.1-0.9)
    var aspectRatio: CGFloat = 1.0  // 宽高比 (0.5-2.0)
    var blurRadius: CGFloat = 0     // 边缘虚化程度 (0-50)
    var offsetX: CGFloat = 0        // 水平位置偏移 (-0.5 到 0.5)
    var offsetY: CGFloat = 0        // 垂直位置偏移 (-0.5 到 0.5)
    var cornerRadius: CGFloat = 20  // 圆角方形时的圆角半径

    static let `default` = MaskSettings()
}
