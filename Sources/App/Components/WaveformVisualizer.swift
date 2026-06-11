import SwiftUI

struct WaveformVisualizer: View {
    let barCount: Int = 90
    var isAnimating: Bool
    
    @State private var barHeights: [CGFloat] = []
    let timer = Timer.publish(every: 0.12, on: .main, in: .common).autoconnect()
    
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<barHeights.count, id: \.self) { index in
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: isAnimating 
                                ? [Color(hex: "8E81F6"), Color(hex: "4EC9B0")]
                                : [Color(hex: "8E81F6").opacity(0.35), Color(hex: "8E81F6").opacity(0.15)],
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    )
                    .frame(width: 3, height: barHeights[index])
            }
        }
        .frame(height: 48)
        .onAppear {
            initializeHeights()
        }
        .onReceive(timer) { _ in
            if isAnimating {
                updateHeights()
            }
        }
        .onChange(of: isAnimating) { animating in
            if !animating {
                // Return to static resting wave pattern
                withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                    initializeHeights()
                }
            }
        }
    }
    
    private func initializeHeights() {
        var heights: [CGFloat] = []
        for i in 0..<barCount {
            // Create a nice natural bell-curve / wave-like resting pattern
            let progress = Double(i) / Double(barCount)
            let factor = sin(progress * Double.pi) * 0.7 + 0.3
            let height = CGFloat(10 + factor * 26 + Double.random(in: -3...3))
            heights.append(max(6, min(48, height)))
        }
        barHeights = heights
    }
    
    private func updateHeights() {
        withAnimation(.interactiveSpring(response: 0.15, dampingFraction: 0.6)) {
            for i in 0..<barHeights.count {
                let progress = Double(i) / Double(barCount)
                // Combine a base sine wave with clean random variation
                let baseFactor = sin(progress * Double.pi * 3.0 + Date().timeIntervalSince1970 * 4.0) * 0.4 + 0.6
                let height = CGFloat(8 + baseFactor * 32 + Double.random(in: -6...6))
                barHeights[i] = max(6, min(48, height))
            }
        }
    }
}
