//
//  Extensions.swift
//  Me2Comic
//
//  Created by Me2 on 2025/8/6.
//

import SwiftUI

/// `Color` 扩展，十六进制字符串初始化颜色
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

/// `ShapeStyle` 的扩展，用于定义应用程序的自定义颜色资产。
extension ShapeStyle where Self == Color {
    /// 标题和标签
    static var textPrimary: Color { Color(hex: "#C0C1C3") }
    /// 次级文本颜色，说明区文字
    static var textSecondary: Color { Color(hex: "#A9B1C2") }
    /// 主背景颜色，按钮背景色，设置页面背景色
    static var backgroundPrimary: Color { Color(hex: "#252A33") }
    /// 次级背景颜色，用于按钮和开关
    static var backgroundSecondary: Color { Color(hex: "#35383F") }
    /// 边框修饰，分隔线
    static var accent: Color { Color(hex: "#28D4E3") }
    /// 整体背景色，右侧整体面板背景色
    static var panelBackground: Color { Color(hex: "#1F232A") }
    /// 左侧面板背景颜色，用于侧边栏
    static var leftPanelBackground: Color { Color(hex: "#1A1C22") }
}
