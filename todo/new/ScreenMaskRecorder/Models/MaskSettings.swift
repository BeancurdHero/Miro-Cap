//
//  MaskSettings.swift
//  ScreenMaskRecorder
//
//  蒙版配置模型
//

import Foundation
import CoreGraphics

enum CanvasAspectRatio: String, CaseIterable {
    case portrait9x16 = "9:16"
    case square1x1 = "1:1"
    case portrait3x4 = "3:4"
    case landscape4x3 = "4:3"
    case landscape16x9 = "16:9"

    var previewAspectRatio: CGFloat {
        switch self {
        case .portrait9x16: return 9.0 / 16.0
        case .square1x1: return 1.0
        case .portrait3x4: return 3.0 / 4.0
        case .landscape4x3: return 4.0 / 3.0
        case .landscape16x9: return 16.0 / 9.0
        }
    }

    var outputSize: CGSize {
        switch self {
        case .portrait9x16:
            return CGSize(width: 1080, height: 1920)
        case .square1x1:
            return CGSize(width: 1080, height: 1080)
        case .portrait3x4:
            return CGSize(width: 1080, height: 1440)
        case .landscape4x3:
            return CGSize(width: 1440, height: 1080)
        case .landscape16x9:
            return CGSize(width: 1920, height: 1080)
        }
    }
}

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
