//
//  ThemeManager.swift
//  Me2Comic
//
//  Created by Me2 on 2025/9/14.
//

import SwiftUI

// MARK: - Theme Definition

enum AppTheme: String, CaseIterable {
    case midnightBlue
    case warmSand
    case forestShadow
    case macOsDark
    
    var displayName: String {
        switch self {
        case .midnightBlue:
            return NSLocalizedString("ThemeMidnightBlue", comment: "")
        case .warmSand:
            return NSLocalizedString("ThemeWarmSand", comment: "")
        case .forestShadow:
            return NSLocalizedString("ThemeForestShadow", comment: "")
        case .macOsDark:
            return NSLocalizedString("ThemeMacOsDark", comment: "")
        }
    }
    
    var isLightTheme: Bool {
        switch self {
        case .warmSand:
            return true
        case .midnightBlue, .forestShadow, .macOsDark:
            return false
        }
    }
}

// MARK: - Theme Manager

@MainActor
final class ThemeManager: ObservableObject {
    static let shared = ThemeManager()
    
    @Published private(set) var currentTheme: AppTheme
    
    private enum UserDefaultsKeys {
        static let selectedTheme = "Me2Comic.selectedTheme"
        static let pendingTheme = "Me2Comic.pendingTheme"
    }
    
    private init() {
        // Migrate old theme identifiers
        if let savedTheme = UserDefaults.standard.string(forKey: UserDefaultsKeys.selectedTheme) {
            let migratedTheme: String
            switch savedTheme {
            case "greenDark":
                migratedTheme = "midnightBlue"
            case "macOSDark":
                migratedTheme = "warmSand"
            default:
                migratedTheme = savedTheme
            }
            
            if migratedTheme != savedTheme {
                UserDefaults.standard.set(migratedTheme, forKey: UserDefaultsKeys.selectedTheme)
            }
        }
        
        // Check for pending theme first (from restart)
        if let pendingTheme = UserDefaults.standard.string(forKey: UserDefaultsKeys.pendingTheme),
           let theme = AppTheme(rawValue: pendingTheme)
        {
            self.currentTheme = theme
            UserDefaults.standard.set(theme.rawValue, forKey: UserDefaultsKeys.selectedTheme)
            UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.pendingTheme)
        }
        // Load saved theme or use default
        else if let savedTheme = UserDefaults.standard.string(forKey: UserDefaultsKeys.selectedTheme),
                let theme = AppTheme(rawValue: savedTheme)
        {
            self.currentTheme = theme
        } else {
            self.currentTheme = .midnightBlue
        }
    }
    
    func setTheme(_ theme: AppTheme) -> Bool {
        guard theme != currentTheme else { return false }
        UserDefaults.standard.set(theme.rawValue, forKey: UserDefaultsKeys.selectedTheme)
        return true
    }
    
    func color(for colorType: SemanticColor) -> Color {
        switch currentTheme {
        case .midnightBlue:
            return colorType.midnightBlueColor
        case .warmSand:
            return colorType.warmSandColor
        case .forestShadow:
            return colorType.forestShadowColor
        case .macOsDark:
            return colorType.macOsDarkColor
        }
    }
}

// MARK: - Semantic Colors

enum SemanticColor {
    case bgPrimary
    case bgSecondary
    case bgTertiary
    case accentPrimary
    case accentSecondary
    case textLight
    case textMuted
    case successGreen
    case warningOrange
    case errorRed
    
    // MARK: Midnight Blue Theme
    
    var midnightBlueColor: Color {
        switch self {
        case .bgPrimary:
            return Color(hex: "#1A1D26")
        case .bgSecondary:
            return Color(hex: "#222834")
        case .bgTertiary:
            return Color(hex: "#2A3142")
        case .accentPrimary:
            return Color(hex: "#5E7CE2")
        case .accentSecondary:
            return Color(hex: "#F97B8B")
        case .textLight:
            return Color(hex: "#E8ECEF")
        case .textMuted:
            return Color(hex: "#8B92A5")
        case .successGreen:
            return Color(hex: "#6BCB77")
        case .warningOrange:
            return Color(hex: "#FFB344")
        case .errorRed:
            return Color(hex: "#FF6B6B")
        }
    }
    
    // MARK: Warm Sand Theme
    
    var warmSandColor: Color {
        switch self {
        case .bgPrimary:
            return Color(hex: "#F5F2ED")
        case .bgSecondary:
            return Color(hex: "#FFFFFF")
        case .bgTertiary:
            return Color(hex: "#FAF8F5")
        case .accentPrimary:
            return Color(hex: "#4A5D7A")
        case .accentSecondary:
            return Color(hex: "#E67E5B")
        case .textLight:
            return Color(hex: "#2C3E50")
        case .textMuted:
            return Color(hex: "#7F8C9A")
        case .successGreen:
            return Color(hex: "#52B788")
        case .warningOrange:
            return Color(hex: "#F4A261")
        case .errorRed:
            return Color(hex: "#E76F71")
        }
    }
    
    // MARK: Forest Shadow Theme
    
    var forestShadowColor: Color {
        switch self {
        case .bgPrimary:
            return Color(hex: "#0D140F")
        case .bgSecondary:
            return Color(hex: "#141F17")
        case .bgTertiary:
            return Color(hex: "#1F2921")
        case .accentPrimary:
            return Color(hex: "#33CC66")
        case .accentSecondary:
            return Color(hex: "#FF9933")
        case .textLight:
            return Color(hex: "#EBEDEA")
        case .textMuted:
            return Color(hex: "#99A694")
        case .successGreen:
            return Color(hex: "#4DB366")
        case .warningOrange:
            return Color(hex: "#FF9926")
        case .errorRed:
            return Color(hex: "#F24D40")
        }
    }
    
    // MARK: macOS Dark Theme
    
    var macOsDarkColor: Color {
        switch self {
        case .bgPrimary:
            return Color(hex: "#1E1E1E")
        case .bgSecondary:
            return Color(hex: "#2C2C2C")
        case .bgTertiary:
            return Color(hex: "#3A3A3A")
        case .accentPrimary:
            return Color(hex: "#007AFF")
        case .accentSecondary:
            return Color(hex: "#FF9500")
        case .textLight:
            return Color(hex: "#FFFFFF")
        case .textMuted:
            return Color(hex: "#8E8E93")
        case .successGreen:
            return Color(hex: "#34C759")
        case .warningOrange:
            return Color(hex: "#FF9500")
        case .errorRed:
            return Color(hex: "#FF3B30")
        }
    }
}
