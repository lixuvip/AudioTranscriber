import SwiftUI

struct LogView: View {
    let logs: [String]

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            ScrollViewReader { proxy in
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(logs.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(lineColor(for: line))
                            .id(index)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onChange(of: logs.count) { _ in
                    if !logs.isEmpty {
                        proxy.scrollTo(logs.count - 1, anchor: .bottom)
                    }
                }
            }
        }
        .background(Color(hex: "16161E"))
        .cornerRadius(8)
        .padding(.horizontal, 24)
    }

    private func lineColor(for line: String) -> Color {
        if line.contains("✓") { return Color(hex: "4EC9B0") }
        if line.contains("✗") || line.contains("error") || line.contains("Error") { return Color(hex: "F14C4C") }
        if line.contains("warning") || line.contains("Warning") { return Color(hex: "CCA700") }
        if line.hasPrefix("[") { return Color(hex: "7C6FE3") }
        return Color(hex: "C0C0D0")
    }
}
