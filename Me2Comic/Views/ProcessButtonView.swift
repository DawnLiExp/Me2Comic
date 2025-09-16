//
//  ProcessButtonView.swift
//  Me2Comic
//
//  Created by Me2 on 2025/9/11.
//

import SwiftUI

// MARK: - ProcessButton

/// Button to start the image processing.
struct ProcessButton: View {
    let enabled: Bool
    let action: () -> Void

    @State private var isHovered = false
    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "play.fill")
                    .font(.system(size: 14))

                Text(NSLocalizedString("StartProcessing", comment: "开始处理"))
                    .font(.system(size: 15, weight: .medium))
            }
            .foregroundColor(enabled ? .white : .textMuted)
            .padding(.horizontal, 30)
            .padding(.vertical, 15)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(
                        enabled ?
                            (isPressed ? Color.accentGreen.opacity(0.7) : (isHovered ? Color.accentGreen.opacity(1.1) : Color.accentGreen.opacity(0.8)))
                            : Color.bgTertiary.opacity(0.5)
                    )
            )
            .scaleEffect(isPressed ? 0.98 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isPressed)
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(!enabled)
        .onHover { hovering in
            isHovered = hovering
        }
        .pressAction {
            isPressed = true
        } onRelease: {
            isPressed = false
        }
    }
}

// MARK: - MinimalToggleStyle

/// A minimal toggle style for switches.
struct MinimalToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(configuration.isOn ? Color.accentGreen : Color.bgTertiary)
            .frame(width: 42, height: 24)
            .overlay(
                Circle()
                    .fill(Color.white)
                    .frame(width: 18, height: 18)
                    .offset(x: configuration.isOn ? 9 : -9)
                    .animation(.spring(response: 0.2), value: configuration.isOn)
            )
            .onTapGesture {
                configuration.isOn.toggle()
            }
    }
}

// Custom ViewModifier for press action
private struct PressAction: ViewModifier {
    var onPress: () -> Void
    var onRelease: () -> Void

    @GestureState private var isPressed: Bool = false

    func body(content: Content) -> some View {
        content
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .updating($isPressed) { _, state, _ in
                        state = true
                    }
                    .onEnded { _ in
                        if isPressed {
                            onRelease()
                        }
                    }
            )
            .onChange(of: isPressed) { _, newValue in
                if newValue {
                    onPress()
                }
            }
    }
}

private extension View {
    func pressAction(onPress: @escaping () -> Void, onRelease: @escaping () -> Void) -> some View {
        modifier(PressAction(onPress: onPress, onRelease: onRelease))
    }
}
