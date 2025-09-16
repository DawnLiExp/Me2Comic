//
//  DirectorySelectorView.swift
//  Me2Comic
//
//  Created by Me2 on 2025/9/11.
//

import AppKit
import SwiftUI

// MARK: - MinimalDirectorySelector

/// A minimal directory selector component.
struct MinimalDirectorySelector: View {
    let title: String
    let subtitle: String
    let path: String?
    let icon: String
    let accentColor: Color
    let onSelect: (URL) -> Void
    
    @State private var interactionState: InteractionState = .normal
    
    private enum InteractionState {
        case normal, hovered, dragging
        
        var iconRotation: Double {
            switch self {
            case .hovered: return 45
            default: return 0
            }
        }
        
        var backgroundOpacity: Double {
            switch self {
            case .dragging: return 0.6
            default: return 0.3
            }
        }
        
        func borderColor(accent: Color) -> (Color, Double) {
            switch self {
            case .dragging: return (accent, 1.0)
            case .hovered: return (accent, 0.5)
            default: return (Color.clear, 0)
            }
        }
    }
    
    var body: some View {
        Button(action: selectDirectory) {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundColor(accentColor)
                    .frame(width: 32)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.textLight)
                        .lineLimit(1)
                    
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.textMuted)
                            .lineLimit(1)
                    }
                }
                
                Spacer()
                
                Image(systemName: "arrow.right.circle")
                    .font(.system(size: 16))
                    .foregroundColor(accentColor)
                    .rotationEffect(.degrees(interactionState.iconRotation))
                    .animation(.spring(response: 0.3), value: interactionState.iconRotation)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.bgTertiary.opacity(interactionState.backgroundOpacity))
                    .overlay(
                        borderOverlay
                    )
                    .animation(.easeInOut(duration: 0.15), value: interactionState.backgroundOpacity)
            )
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            if !isDragging {
                interactionState = hovering ? .hovered : .normal
            }
        }
        .onDrop(of: [.fileURL], isTargeted: Binding(
            get: { interactionState == .dragging },
            set: { interactionState = $0 ? .dragging : .normal }
        )) { providers in
            handleDrop(providers: providers)
            return true
        }
    }
    
    @ViewBuilder
    private var borderOverlay: some View {
        let border = interactionState.borderColor(accent: accentColor)
        RoundedRectangle(cornerRadius: 10)
            .strokeBorder(
                border.0.opacity(border.1),
                lineWidth: 1
            )
    }
    
    private var isDragging: Bool {
        interactionState == .dragging
    }
    
    /// Selects a directory using NSOpenPanel.
    private func selectDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        
        if panel.runModal() == .OK, let url = panel.url {
            onSelect(url)
        }
    }
    
    /// Handles drag and drop of file URLs.
    private func handleDrop(providers: [NSItemProvider]) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier("public.file-url") {
                provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                    if let data = item as? Data,
                       let url = URL(dataRepresentation: data, relativeTo: nil)
                    {
                        var isDirectory: ObjCBool = false
                        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                           isDirectory.boolValue
                        {
                            Task { @MainActor in
                                onSelect(url)
                            }
                        }
                    }
                }
            }
        }
    }
}
