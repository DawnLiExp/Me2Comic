//
//  VisualEffectView.swift
//  Me2Comic
//
//  Created by Me2 on 2025/9/14.
//

import AppKit
import SwiftUI

struct VisualEffectView: NSViewRepresentable {
    enum Material {
        case sidebar
        case menu
        case popover
        case hudWindow
        case fullScreenUI
        case titlebar
        case windowBackground
        case underWindowBackground
        case contentBackground
        case underPageBackground
        
        var nsMaterial: NSVisualEffectView.Material {
            switch self {
            case .sidebar: return .sidebar
            case .menu: return .menu
            case .popover: return .popover
            case .hudWindow: return .hudWindow
            case .fullScreenUI: return .fullScreenUI
            case .titlebar: return .titlebar
            case .windowBackground: return .windowBackground
            case .underWindowBackground: return .underWindowBackground
            case .contentBackground: return .contentBackground
            case .underPageBackground: return .underPageBackground
            }
        }
    }
    
    enum BlendingMode {
        case behindWindow
        case withinWindow
        
        var nsBlendingMode: NSVisualEffectView.BlendingMode {
            switch self {
            case .behindWindow: return .behindWindow
            case .withinWindow: return .withinWindow
            }
        }
    }
    
    let material: Material
    let blendingMode: BlendingMode
    
    init(material: Material = .sidebar, blendingMode: BlendingMode = .behindWindow) {
        self.material = material
        self.blendingMode = blendingMode
    }
    
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material.nsMaterial
        view.blendingMode = blendingMode.nsBlendingMode
        view.state = .active
        return view
    }
    
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material.nsMaterial
        nsView.blendingMode = blendingMode.nsBlendingMode
    }
}
