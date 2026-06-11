import SwiftUI

struct TranscriptionTimelineView: View {
    @ObservedObject var transcriber: Transcriber
    
    @State private var pulsing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            let stages = transcriber.timelineStages
            
            ForEach(0..<stages.count, id: \.self) { index in
                let stage = stages[index]
                let isLast = index == stages.count - 1
                
                HStack(alignment: .top, spacing: 14) {
                    // Left Timeline Indicator column with linking line
                    VStack(spacing: 0) {
                        indicatorView(status: stage.status)
                            .frame(width: 18, height: 18)
                        
                        if !isLast {
                            // Connecting line to next stage
                            let nextStage = stages[index + 1]
                            lineView(currentStatus: stage.status, nextStatus: nextStage.status)
                                .frame(width: 2)
                                .frame(minHeight: 18) // vertical spacing
                        }
                    }
                    
                    // Stage title & detail text
                    VStack(alignment: .leading, spacing: 2) {
                        Text(stage.title)
                            .font(.system(size: 12, weight: stage.status == .inProgress ? .semibold : .regular))
                            .foregroundColor(titleColor(for: stage.status))
                            .lineLimit(1)
                        
                        if stage.status == .inProgress {
                            Text("处理中...")
                                .font(.system(size: 10))
                                .foregroundColor(Color(hex: "8E81F6").opacity(0.8))
                        }
                    }
                    .padding(.top, 1)
                    
                    Spacer()
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                )
        )
        .onAppear {
            withAnimation(Animation.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                pulsing = true
            }
        }
    }
    
    @ViewBuilder
    private func indicatorView(status: StageStatus) -> some View {
        switch status {
        case .completed:
            ZStack {
                Circle()
                    .fill(Color(hex: "4EC9B0").opacity(0.15))
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(Color(hex: "4EC9B0"))
            }
        case .inProgress:
            ZStack {
                Circle()
                    .fill(Color(hex: "8E81F6").opacity(0.2))
                    .scaleEffect(pulsing ? 1.3 : 1.0)
                    .opacity(pulsing ? 0.3 : 0.8)
                
                Circle()
                    .stroke(Color(hex: "8E81F6"), lineWidth: 1.5)
                
                Circle()
                    .fill(Color(hex: "8E81F6"))
                    .frame(width: 6, height: 6)
            }
        case .failed:
            ZStack {
                Circle()
                    .fill(Color(hex: "F08A8A").opacity(0.15))
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(Color(hex: "F08A8A"))
            }
        case .pending:
            Circle()
                .stroke(Color(hex: "3A3A4C"), lineWidth: 1.5)
                .background(Circle().fill(Color(hex: "1C1C28")))
        }
    }
    
    @ViewBuilder
    private func lineView(currentStatus: StageStatus, nextStatus: StageStatus) -> some View {
        if currentStatus == .completed {
            Rectangle()
                .fill(Color(hex: "4EC9B0").opacity(0.5))
        } else if currentStatus == .inProgress || nextStatus == .inProgress {
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [Color(hex: "8E81F6").opacity(0.5), Color(hex: "3A3A4C").opacity(0.3)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        } else {
            // Pending dashed style or light solid line
            Rectangle()
                .fill(Color(hex: "3A3A4C").opacity(0.4))
        }
    }
    
    private func titleColor(for status: StageStatus) -> Color {
        switch status {
        case .completed:
            return Color(hex: "A0A0B0")
        case .inProgress:
            return .white
        case .failed:
            return Color(hex: "F08A8A")
        case .pending:
            return Color(hex: "5A5A6C")
        }
    }
}
