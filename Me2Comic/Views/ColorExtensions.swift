//
//  ColorExtensions.swift
//  Me2Comic
//
//  Created by Me2 on 2025/9/11.
//

import SwiftUI

// MARK: - Color Hex Extension

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
}

// MARK: - Theme-aware Color Properties

extension Color {
    // Background colors
    @MainActor
    static var bgPrimary: Color {
        ThemeManager.shared.currentTheme.bgPrimary
    }
    
    @MainActor
    static var bgSecondary: Color {
        ThemeManager.shared.currentTheme.bgSecondary
    }
    
    @MainActor
    static var bgTertiary: Color {
        ThemeManager.shared.currentTheme.bgTertiary
    }
    
    // Accent colors
    @MainActor
    static var accentGreen: Color {
        ThemeManager.shared.currentTheme.accentGreen
    }
    
    @MainActor
    static var accentOrange: Color {
        ThemeManager.shared.currentTheme.accentOrange
    }
    
    // Text colors
    @MainActor
    static var textLight: Color {
        ThemeManager.shared.currentTheme.textLight
    }
    
    @MainActor
    static var textMuted: Color {
        ThemeManager.shared.currentTheme.textMuted
    }
    
    // Status colors
    @MainActor
    static var successGreen: Color {
        ThemeManager.shared.currentTheme.successGreen
    }
    
    @MainActor
    static var warningOrange: Color {
        ThemeManager.shared.currentTheme.warningOrange
    }
    
    @MainActor
    static var errorRed: Color {
        ThemeManager.shared.currentTheme.errorRed
    }
}
