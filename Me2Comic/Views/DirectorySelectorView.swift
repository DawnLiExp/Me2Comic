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
    
    @State private var isHovered = false
    @State private var isDragging = false
    
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
                    .rotationEffect(.degrees(isHovered ? 45 : 0))
                    .animation(.spring(response: 0.3), value: isHovered)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.bgTertiary.opacity(isDragging ? 0.6 : 0.3))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(
                                isDragging ? accentColor : (isHovered ? accentColor.opacity(0.5) : Color.clear),
                                lineWidth: 1
                            )
                    )
            )
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            isHovered = hovering
        }
        .onDrop(of: [.fileURL], isTargeted: $isDragging) { providers in
            handleDrop(providers: providers)
            return true
        }
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
                            DispatchQueue.main.async {
                                onSelect(url)
                            }
                        }
                    }
                }
            }
        }
    }
}
