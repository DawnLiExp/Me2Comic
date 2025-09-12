//
//  ColorExtensions.swift
//  Me2Comic
//
//  Created by Me2 on 2025/9/11.
//

import SwiftUI

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit) -> RGB (24-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0) // Fallback to clear or black if invalid
        }

        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }

    /// 主背景色 - 深绿基调
    static let bgPrimary = Color(hex: "#0D140F") // 0.05, 0.08, 0.06
    /// 次级背景色 - 稍亮的深绿
    static let bgSecondary = Color(hex: "#141F17") // 0.08, 0.12, 0.09
    /// 三级背景色 - 用于卡片和面板
    static let bgTertiary = Color(hex: "#1F2921") // 0.12, 0.16, 0.13
    /// 主强调色 - 亮绿色
    static let accentGreen = Color(hex: "#33CC66") // 0.2, 0.8, 0.4
    /// 次强调色 - 橙色
    static let accentOrange = Color(hex: "#FF9933") // 1.0, 0.6, 0.2
    /// 主文本色 - 浅色
    static let textLight = Color(hex: "#EBEDEA") // 0.92, 0.94, 0.90
    /// 次级文本色 - 中性灰
    static let textMuted = Color(hex: "#99A694") // 0.60, 0.65, 0.58
    /// 成功状态色
    static let successGreen = Color(hex: "#4DB366") // 0.3, 0.9, 0.4
    /// 警告状态色
    static let warningOrange = Color(hex: "#FF9926") // 1.0, 0.65, 0.15
    /// 错误状态色
    static let errorRed = Color(hex: "#F24D40") // 0.95, 0.3, 0.25
}
