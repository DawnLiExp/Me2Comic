//
//  ProcessingView.swift
//  Me2Comic
//
//  Created by Me2 on 2025/9/11.
//

import SwiftUI

// MARK: - ProcessingView

/// View for displaying processing progress.
struct ProcessingView: View {
    let progress: Double
    let processedCount: Int
    let totalCount: Int
    let onStop: () -> Void
    
    @State private var rotation: Double = 0
    
    var body: some View {
        VStack(spacing: 40) {
            // Progress Indicator
            ZStack {
                // Progress Arc
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        LinearGradient(
                            colors: [.accentGreen, .accentGreen.opacity(0.6)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        style: StrokeStyle(lineWidth: 8, lineCap: .round)
                    )
                    .frame(width: 200, height: 200)
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.5), value: progress)
                
                // Decorative Ring
                Circle()
                    .stroke(
                        LinearGradient(
                            colors: [.accentGreen.opacity(0.3), .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 2
                    )
                    .frame(width: 180, height: 180)
                    .rotationEffect(.degrees(rotation))
                    .animation(.linear(duration: 2).repeatForever(autoreverses: false), value: rotation)
                    .onAppear { rotation = 360 }
                
                // Center Content
                VStack(spacing: 8) {
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 48, weight: .light, design: .rounded))
                        .foregroundColor(.textLight)
                    
                    Text("\(processedCount) / \(totalCount)")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.textMuted)
                }
            }
            
            // Status Text
            VStack(spacing: 8) {
                Text(NSLocalizedString("ProcessingStatus", comment: "正在处理..."))
                    .font(.system(size: 20, weight: .light))
                    .foregroundColor(.textLight)
                
                //   Text(NSLocalizedString("EstimatedTimeRemaining", comment: "预计剩余时间: 2分34秒"))
                //       .font(.system(size: 13))
                //        .foregroundColor(.textMuted)
            }
            
            // Stop Button
            Button(action: onStop) {
                HStack(spacing: 8) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 12))
                    Text(NSLocalizedString("Stop", comment: "停止"))
                        .font(.system(size: 14, weight: .medium))
                }
                .foregroundColor(.errorRed)
                .padding(.horizontal, 24)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.errorRed.opacity(0.1))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color.errorRed.opacity(0.3), lineWidth: 1)
                        )
                )
            }
            .buttonStyle(PlainButtonStyle())
        }
    }
}
