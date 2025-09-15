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
    
    // MARK: - Theme-aware Semantic Colors
    
    /// Primary background color - darkest
    @MainActor
    static var bgPrimary: Color {
        ThemeManager.shared.color(for: .bgPrimary)
    }
    
    /// Secondary background color - slightly lighter
    @MainActor
    static var bgSecondary: Color {
        ThemeManager.shared.color(for: .bgSecondary)
    }
    
    /// Tertiary background color - for cards and panels
    @MainActor
    static var bgTertiary: Color {
        ThemeManager.shared.color(for: .bgTertiary)
    }
    
    /// Primary accent color
    @MainActor
    static var accentGreen: Color {
        ThemeManager.shared.color(for: .accentPrimary)
    }
    
    /// Secondary accent color
    @MainActor
    static var accentOrange: Color {
        ThemeManager.shared.color(for: .accentSecondary)
    }
    
    /// Primary text color - light
    @MainActor
    static var textLight: Color {
        ThemeManager.shared.color(for: .textLight)
    }
    
    /// Secondary text color - muted
    @MainActor
    static var textMuted: Color {
        ThemeManager.shared.color(for: .textMuted)
    }
    
    /// Success status color
    @MainActor
    static var successGreen: Color {
        ThemeManager.shared.color(for: .successGreen)
    }
    
    /// Warning status color
    @MainActor
    static var warningOrange: Color {
        ThemeManager.shared.color(for: .warningOrange)
    }
    
    /// Error status color
    @MainActor
    static var errorRed: Color {
        ThemeManager.shared.color(for: .errorRed)
    }
    
    // MARK: - Adaptive Colors for Light/Dark Theme Support
    
    /// Check if current theme is light
    @MainActor
    static var isLightTheme: Bool {
        let theme = ThemeManager.shared.currentTheme
        switch theme {
        case .greenDark:
            return false // Dark theme
        case .macOSDark:
            return true // Actually a light theme (Sage Garden)
        }
    }
    
    /// Adaptive primary text color - automatically adjusts for theme
    @MainActor
    static var adaptiveTextPrimary: Color {
        // Returns appropriate text color based on theme brightness
        isLightTheme ? Color(hex: "#2C3E50") : Color(hex: "#EDE9F6")
    }
    
    /// Adaptive secondary text color - automatically adjusts for theme
    @MainActor
    static var adaptiveTextSecondary: Color {
        // Returns appropriate muted text color based on theme brightness
        isLightTheme ? Color(hex: "#6B7C6D") : Color(hex: "#9B95A8")
    }
    
    /// Adaptive control text for pickers and menus
    @MainActor
    static var adaptiveControlText: Color {
        // Ensures picker text is visible on any theme
        isLightTheme ? Color(hex: "#2C3E50") : Color(hex: "#EDE9F6")
    }
    
    /// Adaptive divider color
    @MainActor
    static var adaptiveDivider: Color {
        isLightTheme ? Color(hex: "#E0E0E0") : Color(hex: "#3A3A3A")
    }
}
