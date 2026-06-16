import SwiftUI

struct SilentInstallProgressCapsule: View {
    let status: String
    let progress: Double

    @State private var animateBreathing = false

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(hex: "1E1E2A"))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(hex: "8E81F6").opacity(0.3), lineWidth: 1)
                    )

                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(hex: "7C6FE3"),
                                Color(hex: "A899FF")
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .opacity(animateBreathing ? 0.6 : 1.0)
                    .scaleEffect(x: CGFloat(min(max(progress, 0.0), 1.0)), y: 1.0, anchor: .leading)
                    .animation(.easeInOut(duration: 0.1), value: progress)

                HStack {
                    Image(systemName: "sparkles")
                        .foregroundColor(.white)
                        .opacity(animateBreathing ? 0.5 : 1.0)

                    Text("\(status)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)

                    Spacer()

                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 16)
            }
            .frame(height: 42)
        }
        .onAppear {
            withAnimation(
                .easeInOut(duration: 1.5)
                .repeatForever(autoreverses: true)
            ) {
                animateBreathing = true
            }
        }
    }
}
