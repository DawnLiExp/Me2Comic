//
//  ThemeManager.swift
//  Me2Comic
//
//  Created by Me2 on 2025/9/14.
//

import SwiftUI

/// Available application themes
enum AppTheme: String, CaseIterable {
    case greenDark
    case macOSDark
    
    var displayName: String {
        switch self {
        case .greenDark:
            return NSLocalizedString("ThemeGreenDark", comment: "Green Dark Theme")
        case .macOSDark:
            return NSLocalizedString("ThemeMacOSDark", comment: "macOS Dark Theme")
        }
    }
    
    /// Whether this is a light theme
    var isLightTheme: Bool {
        switch self {
        case .greenDark:
            return false
        case .macOSDark:
            return true
        }
    }
}

/// Theme manager for handling theme switching and persistence
@MainActor
final class ThemeManager: ObservableObject {
    // MARK: - Singleton

    static let shared = ThemeManager()
    
    // MARK: - Properties

    @Published private(set) var currentTheme: AppTheme
    
    // MARK: - Constants

    private enum UserDefaultsKeys {
        static let selectedTheme = "Me2Comic.selectedTheme"
        static let pendingTheme = "Me2Comic.pendingTheme"
    }
    
    // MARK: - Initialization

    private init() {
        // Check for pending theme first (from restart)
        if let pendingTheme = UserDefaults.standard.string(forKey: UserDefaultsKeys.pendingTheme),
           let theme = AppTheme(rawValue: pendingTheme)
        {
            // Apply pending theme and clear it
            self.currentTheme = theme
            UserDefaults.standard.set(theme.rawValue, forKey: UserDefaultsKeys.selectedTheme)
            UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.pendingTheme)
        }
        // Otherwise load saved theme or use default
        else if let savedTheme = UserDefaults.standard.string(forKey: UserDefaultsKeys.selectedTheme),
                let theme = AppTheme(rawValue: savedTheme)
        {
            self.currentTheme = theme
        } else {
            self.currentTheme = .greenDark
        }
    }
    
    // MARK: - Public Methods
    
    /// Set the application theme
    /// - Parameter theme: The theme to apply
    /// - Returns: Whether a restart is required
    func setTheme(_ theme: AppTheme) -> Bool {
        guard theme != currentTheme else { return false }
        
        // Save the theme for next launch
        UserDefaults.standard.set(theme.rawValue, forKey: UserDefaultsKeys.selectedTheme)
        // Don't update currentTheme here to avoid partial application
        return true
    }
    
    /// Get color for a specific semantic color based on current theme
    func color(for colorType: SemanticColor) -> Color {
        switch currentTheme {
        case .greenDark:
            return colorType.greenDarkColor
        case .macOSDark:
            return colorType.macOSDarkColor
        }
    }
}

/// Semantic color types used throughout the app
enum SemanticColor {
    // Backgrounds
    case bgPrimary
    case bgSecondary
    case bgTertiary
    
    // Accents
    case accentPrimary
    case accentSecondary
    
    // Text
    case textLight
    case textMuted
    
    // Status
    case successGreen
    case warningOrange
    case errorRed
    
    // MARK: - Midnight Blue Theme

    var greenDarkColor: Color {
        switch self {
        case .bgPrimary:
            return Color(hex: "#1A1D26") // 深蓝灰基础背景
        case .bgSecondary:
            return Color(hex: "#222834") // 稍亮的蓝灰
        case .bgTertiary:
            return Color(hex: "#2A3142") // 卡片/面板背景
        case .accentPrimary:
            return Color(hex: "#5E7CE2") // 柔和蓝紫色
        case .accentSecondary:
            return Color(hex: "#F97B8B") // 珊瑚粉色
        case .textLight:
            return Color(hex: "#E8ECEF") // 柔和白色文本
        case .textMuted:
            return Color(hex: "#8B92A5") // 柔和灰蓝文本
        case .successGreen:
            return Color(hex: "#6BCB77") // 柔和绿色
        case .warningOrange:
            return Color(hex: "#FFB344") // 暖橙色
        case .errorRed:
            return Color(hex: "#FF6B6B") // 柔和红色
        }
    }
        
    // MARK: - Warm Sand Theme

    var macOSDarkColor: Color {
        switch self {
        case .bgPrimary:
            return Color(hex: "#F5F2ED") // 暖米色背景
        case .bgSecondary:
            return Color(hex: "#FFFFFF") // 纯白卡片
        case .bgTertiary:
            return Color(hex: "#FAF8F5") // 浅米色层级
        case .accentPrimary:
            return Color(hex: "#4A5D7A") // 深蓝灰强调
        case .accentSecondary:
            return Color(hex: "#E67E5B") // 陶土橙
        case .textLight:
            return Color(hex: "#2C3E50") // 深色主文本
        case .textMuted:
            return Color(hex: "#7F8C9A") // 中灰色次要文本
        case .successGreen:
            return Color(hex: "#52B788") // 自然绿
        case .warningOrange:
            return Color(hex: "#F4A261") // 琥珀色
        case .errorRed:
            return Color(hex: "#E76F71") // 珊瑚红
        }
    }
}
