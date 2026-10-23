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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "play.fill")
                    .font(.system(size: 14))

                Text("StartProcessing")
                    .font(.system(size: 15, weight: .medium))
            }
            .foregroundColor(enabled ? .buttonForeground : .textMuted)
            .padding(.horizontal, 30)
            .padding(.vertical, 15)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(enabled ? Color.buttonBackground : Color.bgTertiary)
                    .overlay {
                        if enabled {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(isPressed ? Color.black.opacity(0.12) : Color.white.opacity(isHovered ? 0.06 : 0))
                        }
                    }
            )
            .scaleEffect(isPressed && !reduceMotion ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: isPressed)
        }
        .buttonStyle(ProcessActionStyle())
        .disabled(!enabled)
        .onHover { hovering in
            isHovered = hovering
        }
        .pressAction {
            if enabled { isPressed = true }
        } onRelease: {
            isPressed = false
        }
    }
}

// MARK: - MinimalToggleStyle

/// A minimal toggle style for switches.
struct MinimalToggleStyle: ToggleStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(configuration.isOn ? Color.accentGreen : Color.bgTertiary)
            .frame(width: 42, height: 24)
            .overlay(
                Circle()
                    .fill(configuration.isOn ? Color.bgPrimary : Color.textMuted)
                    .frame(width: 18, height: 18)
                    .offset(x: configuration.isOn ? 9 : -9)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: configuration.isOn)
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
                if newValue { onPress() } else { onRelease() }
            }
    }
}

private extension View {
    func pressAction(onPress: @escaping () -> Void, onRelease: @escaping () -> Void) -> some View {
        modifier(PressAction(onPress: onPress, onRelease: onRelease))
    }
}

/// Keep the explicitly designed disabled foreground instead of the plain style's extra dimming.
private struct ProcessActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}
