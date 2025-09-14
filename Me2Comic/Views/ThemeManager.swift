//
//  ThemeManager.swift
//  Me2Comic
//
//  Theme management system for color scheme switching
//

import SwiftUI

// MARK: - Theme Protocol

protocol Theme {
    // Background colors
    var bgPrimary: Color { get }
    var bgSecondary: Color { get }
    var bgTertiary: Color { get }
    
    // Accent colors
    var accentGreen: Color { get }
    var accentOrange: Color { get }
    
    // Text colors
    var textLight: Color { get }
    var textMuted: Color { get }
    
    // Status colors
    var successGreen: Color { get }
    var warningOrange: Color { get }
    var errorRed: Color { get }
}

// MARK: - Deep Green Theme (Original)

struct DeepGreenTheme: Theme {
    let bgPrimary = Color(hex: "#0D140F")      // Deep green base
    let bgSecondary = Color(hex: "#141F17")    // Slightly lighter deep green
    let bgTertiary = Color(hex: "#1F2921")     // For cards and panels
    let accentGreen = Color(hex: "#33CC66")    // Bright green
    let accentOrange = Color(hex: "#FF9933")   // Orange
    let textLight = Color(hex: "#EBEDEA")      // Light text
    let textMuted = Color(hex: "#99A694")      // Neutral gray
    let successGreen = Color(hex: "#4DB366")   // Success state
    let warningOrange = Color(hex: "#FF9926")  // Warning state
    let errorRed = Color(hex: "#F24D40")       // Error state
}

// MARK: - macOS Dark Theme

struct MacOSDarkTheme: Theme {
    let bgPrimary = Color(hex: "#1E1E1E")      // Dark gray base
    let bgSecondary = Color(hex: "#2D2D30")    // Slightly lighter gray
    let bgTertiary = Color(hex: "#3E3E42")     // For cards and panels
    let accentGreen = Color(hex: "#52C766")    // System green
    let accentOrange = Color(hex: "#FF9F0A")   // System orange
    let textLight = Color(hex: "#FFFFFF")      // Pure white text
    let textMuted = Color(hex: "#98989D")      // System secondary label
    let successGreen = Color(hex: "#32D74B")   // System green
    let warningOrange = Color(hex: "#FFD60A")  // System yellow
    let errorRed = Color(hex: "#FF453A")       // System red
}

// MARK: - Theme Manager

@MainActor
final class ThemeManager: ObservableObject {
    static let shared = ThemeManager()
    
    enum ThemeType: String, CaseIterable {
        case deepGreen = "deepGreen"
        case macOSDark = "macOSDark"
        
        var displayName: String {
            switch self {
            case .deepGreen:
                return NSLocalizedString("ThemeDeepGreen", comment: "Deep Green theme name")
            case .macOSDark:
                return NSLocalizedString("ThemeMacOSDark", comment: "macOS Dark theme name")
            }
        }
        
        var theme: Theme {
            switch self {
            case .deepGreen:
                return DeepGreenTheme()
            case .macOSDark:
                return MacOSDarkTheme()
            }
        }
    }
    
    @Published var currentTheme: Theme
    @Published var currentThemeType: ThemeType {
        didSet {
            currentTheme = currentThemeType.theme
            UserDefaults.standard.set(currentThemeType.rawValue, forKey: "SelectedTheme")
        }
    }
    
    private init() {
        // Load saved theme or use default
        let savedTheme = UserDefaults.standard.string(forKey: "SelectedTheme") ?? ThemeType.deepGreen.rawValue
        let themeType = ThemeType(rawValue: savedTheme) ?? .deepGreen
        self.currentThemeType = themeType
        self.currentTheme = themeType.theme
    }
}
