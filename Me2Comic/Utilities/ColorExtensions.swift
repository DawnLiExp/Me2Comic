//
//  ColorExtensions.swift
//  Me2Comic
//
//  Created by Me2 on 2025/9/11.
//

import SwiftUI

extension Color {
    // MARK: - Hex Initializer

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
            (a, r, g, b) = (1, 1, 1, 0)
        }
        
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
    
    // MARK: - Theme-aware Semantic Colors
    
    @MainActor
    static var bgPrimary: Color {
        ThemeManager.shared.color(for: .bgPrimary)
    }
    
    @MainActor
    static var bgSecondary: Color {
        ThemeManager.shared.color(for: .bgSecondary)
    }
    
    @MainActor
    static var bgTertiary: Color {
        ThemeManager.shared.color(for: .bgTertiary)
    }
    
    @MainActor
    static var accentGreen: Color {
        ThemeManager.shared.color(for: .accentPrimary)
    }
    
    @MainActor
    static var accentOrange: Color {
        ThemeManager.shared.color(for: .accentSecondary)
    }
    
    @MainActor
    static var textLight: Color {
        ThemeManager.shared.color(for: .textLight)
    }
    
    @MainActor
    static var textMuted: Color {
        ThemeManager.shared.color(for: .textMuted)
    }
    
    @MainActor
    static var successGreen: Color {
        ThemeManager.shared.color(for: .successGreen)
    }
    
    @MainActor
    static var warningOrange: Color {
        ThemeManager.shared.color(for: .warningOrange)
    }
    
    @MainActor
    static var errorRed: Color {
        ThemeManager.shared.color(for: .errorRed)
    }
    
    // MARK: - Adaptive Colors for Light/Dark Theme Support
    
    @MainActor
    static var isLightTheme: Bool {
        ThemeManager.shared.currentTheme.isLightTheme
    }
    
    @MainActor
    static var adaptiveTextPrimary: Color {
        isLightTheme ? Color(hex: "#2C3E50") : Color(hex: "#EDE9F6")
    }
    
    @MainActor
    static var adaptiveTextSecondary: Color {
        isLightTheme ? Color(hex: "#6B7C6D") : Color(hex: "#9B95A8")
    }
    
    @MainActor
    static var adaptiveControlText: Color {
        isLightTheme ? Color(hex: "#2C3E50") : Color(hex: "#EDE9F6")
    }
    
    @MainActor
    static var adaptiveDivider: Color {
        isLightTheme ? Color(hex: "#E0E0E0") : Color(hex: "#3A3A3A")
    }
}
