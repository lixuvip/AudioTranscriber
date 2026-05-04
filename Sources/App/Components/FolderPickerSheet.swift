import SwiftUI

struct FolderPickerSheet: View {
    @Binding var isPresented: Bool
    var onSelect: (URL?) -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("选择输出目录")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)

            Text("点击下方按钮打开 macOS 文件选择器，选择输出目录。留空则默认保存在音频文件同目录。")
                .font(.system(size: 12))
                .foregroundColor(Color(hex: "A0A0B0"))
                .multilineTextAlignment(.center)

            Button(action: {
                NSOpenPanel.openDirectory { url in
                    onSelect(url)
                }
            }) {
                HStack {
                    Image(systemName: "folder")
                    Text("选择文件夹...")
                }
                .frame(maxWidth: 200)
            }
            .buttonStyle(.borderedProminent)

            Button("取消") {
                isPresented = false
                onSelect(nil)
            }
            .buttonStyle(.bordered)
        }
        .padding(32)
        .frame(width: 380, height: 220)
        .background(Color(hex: "2A2A3C"))
    }
}
