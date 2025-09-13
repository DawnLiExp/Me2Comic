//
//  CPUUsageChartView.swift
//  Me2Comic
//
//  Created by Me2 on 2025/9/13.
//

import SwiftUI

// MARK: - CPU Usage Chart View

struct CPUUsageChartView: View {
    @StateObject private var cpuMonitor = CPUMonitor()
    
    private let chartHeight: CGFloat = 100
    
    var body: some View {
        VStack(spacing: 8) {
            // Header
            HStack {
                Label {
                    Text(NSLocalizedString("CPUUsage", comment: ""))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.textLight)
                } icon: {
                    Image(systemName: "cpu")
                        .font(.system(size: 14))
                        .foregroundColor(.accentGreen)
                }
                
                Spacer()
                
                Text("\(Int(cpuMonitor.currentUsage * 100))%")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.textMuted)
            }
            
            // Chart
            ZStack {
                // Background
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.bgTertiary.opacity(0.3))
                
                // Grid lines
                GridLinesView()
                
                // Usage curve
                if !cpuMonitor.usageHistory.isEmpty {
                    GeometryReader { geometry in
                        CPUCurveView(
                            data: cpuMonitor.usageHistory,
                            size: geometry.size
                        )
                        .drawingGroup()
                    }
                }
            }
            .frame(height: chartHeight)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.bgTertiary.opacity(0.5), lineWidth: 1)
            )
        }
        .onAppear {
            cpuMonitor.startMonitoring()
        }
        .onDisappear {
            cpuMonitor.stopMonitoring()
        }
    }
}

// MARK: - Grid Lines View

private struct GridLinesView: View {
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                // Horizontal lines at 25%, 50%, 75%
                let horizontalLines = [0.25, 0.5, 0.75]
                for percentage in horizontalLines {
                    let y = geometry.size.height * (1.0 - percentage)
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: geometry.size.width, y: y))
                }
            }
            .stroke(Color.textMuted.opacity(0.1), lineWidth: 0.5)
        }
    }
}

// MARK: - CPU Curve View

private struct CPUCurveView: View {
    let data: [CPUUsageData]
    let size: CGSize
    
    var body: some View {
        ZStack {
            // Gradient fill
            Path { path in
                buildPath(&path, closeForFill: true)
            }
            .fill(
                LinearGradient(
                    colors: [
                        Color.accentGreen.opacity(0.3),
                        Color.accentGreen.opacity(0.1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            
            // Curve line
            Path { path in
                buildPath(&path, closeForFill: false)
            }
            .stroke(Color.accentGreen, lineWidth: 1.5)
        }
    }
    
    private func buildPath(_ path: inout Path, closeForFill: Bool) {
        guard !data.isEmpty else { return }
        
        let xStep = size.width / CGFloat(max(data.count - 1, 1))
        
        for (index, point) in data.enumerated() {
            let x = CGFloat(index) * xStep
            let y = size.height * (1.0 - point.usage)
            
            if index == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        
        if closeForFill {
            path.addLine(to: CGPoint(x: CGFloat(data.count - 1) * xStep, y: size.height))
            path.addLine(to: CGPoint(x: 0, y: size.height))
            path.closeSubpath()
        }
    }
}
