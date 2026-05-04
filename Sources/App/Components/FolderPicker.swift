import SwiftUI
import AppKit

extension NSOpenPanel {
    static func openDirectory(completion: @escaping (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "选择输出目录"
        panel.begin { response in
            completion(response == .OK ? panel.url : nil)
        }
    }

    static func openPythonExecutable(completion: @escaping (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "选择可用的 Python 可执行文件，例如 /opt/anaconda3/bin/python3"
        panel.prompt = "选择 Python"
        panel.directoryURL = URL(fileURLWithPath: "/")
        panel.begin { response in
            completion(response == .OK ? panel.url : nil)
        }
    }
}

struct FolderPickerView: View {
    @Binding var isPresented: Bool
    var onSelect: (URL?) -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("选择输出目录")
                .font(.system(size: 14, weight: .semibold))

            Button("打开文件夹选择器") {
                NSOpenPanel.openDirectory { url in
                    isPresented = false
                    onSelect(url)
                }
            }
            .buttonStyle(.borderedProminent)

            Button("取消") {
                isPresented = false
                onSelect(nil)
            }
            .buttonStyle(.bordered)
        }
        .padding(32)
        .frame(width: 300, height: 140)
    }
}
