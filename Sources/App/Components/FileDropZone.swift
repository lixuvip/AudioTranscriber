import SwiftUI
import UniformTypeIdentifiers

struct FileDropZone: View {
    @Binding var selectedFileURL: URL?
    @Binding var isDragging: Bool
    var onSelect: () -> Void

    var body: some View {
        if selectedFileURL != nil {
            SelectedFileRow(url: selectedFileURL!, onClear: { selectedFileURL = nil })
        } else {
            DropZoneView(isDragging: $isDragging, onSelect: onSelect, onDrop: { url in
                selectedFileURL = url
            })
        }
    }
}

struct SelectedFileRow: View {
    let url: URL
    var onClear: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "waveform")
                .foregroundColor(Color(hex: "7C6FE3"))
            Text(url.lastPathComponent)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.white)
                .lineLimit(1)
            Spacer()
            Button(action: onClear) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(Color(hex: "A0A0B0"))
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(Color(hex: "2A2A3C"))
        .cornerRadius(8)
        .padding(.horizontal, 24)
    }
}

struct DropZoneView: View {
    @Binding var isDragging: Bool
    var onSelect: () -> Void
    var onDrop: (URL) -> Void

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    Color(hex: isDragging ? "7C6FE3" : "3A3A4C"),
                    style: StrokeStyle(lineWidth: 2, dash: [8, 4])
                )
                .background(Color(hex: "2A2A3C").opacity(0.3))

            VStack(spacing: 10) {
                Image(systemName: "waveform.circle")
                    .font(.system(size: 36))
                    .foregroundColor(Color(hex: "7C6FE3"))
                Text("拖拽音频文件到这里")
                    .font(.system(size: 13))
                    .foregroundColor(Color(hex: "A0A0B0"))
                Button(action: onSelect) {
                    Text("选择文件")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(Color(hex: "7C6FE3"))
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(height: 130)
        .padding(.horizontal, 24)
        .onDrop(of: [.fileURL], isTargeted: $isDragging) { providers in
            guard let provider = providers.first else { return false }
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                DispatchQueue.main.async { onDrop(url) }
            }
            return true
        }
    }
}
