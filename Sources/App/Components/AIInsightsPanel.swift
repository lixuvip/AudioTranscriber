import SwiftUI
import UniformTypeIdentifiers
import PDFKit
import CoreText

struct AIInsightsPanel: View {
    @ObservedObject var transcriber: Transcriber
    @ObservedObject var settingsManager: SettingsManager
    @ObservedObject var envChecker: EnvironmentChecker
    @State private var selectedTab: InsightTab = .minutes
    @State private var summaryModelID: String = ""

    // Checklist state
    @State private var checkedItems: Set<UUID> = []
    @State private var actionItems: [ActionItem] = [
        ActionItem(text: "测试用于波形可视化图层的 GPU 硬件加速。"),
        ActionItem(text: "确认并微调不同社交平台的导出模板及字数限制。"),
        ActionItem(text: "结合 mlx-audio 在 Apple Silicon 设备上进行极端长音频测试。")
    ]
    
    enum InsightTab: String, CaseIterable {
        case minutes = "Minutes"
        case actions = "Actions"
        case social = "Social"
        
        var icon: String {
            switch self {
            case .minutes: return "doc.plaintext"
            case .actions: return "checklist"
            case .social: return "square.and.arrow.up"
            }
        }
        
        var titleZh: String {
            switch self {
            case .minutes: return "会议纪要"
            case .actions: return "行动项"
            case .social: return "宣发文案"
            }
        }
    }
    
    struct ActionItem: Identifiable {
        let id = UUID()
        let text: String
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(Color(hex: "8E81F6"))
                Text("AI 智能生成")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundColor(Color(hex: "8E81F6"))
            }
            
            // Tab Buttons
            HStack(spacing: 8) {
                ForEach(InsightTab.allCases, id: \.self) { tab in
                    let isActive = selectedTab == tab
                    Button(action: { selectedTab = tab }) {
                        HStack(spacing: 4) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 10))
                            Text(tab.titleZh)
                                .font(.system(size: 11, weight: .bold))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(isActive ? Color(hex: "8E81F6") : Color(hex: "1E1E2E"))
                        .foregroundColor(isActive ? Color(hex: "12121A") : Color(hex: "A0A0B0"))
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(isActive ? Color.clear : Color.white.opacity(0.05), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            
            // Tab Content
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch selectedTab {
                    case .minutes:
                        VStack(alignment: .leading, spacing: 8) {
                            Text("会议摘要简报")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(Color(hex: "A0A0B0").opacity(0.6))
                                .tracking(1)
                            
                            if let summary = transcriber.generatedSummary {
                                ScrollView {
                                    Text(summary)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundColor(.white.opacity(0.9))
                                        .lineSpacing(6)
                                        .padding(12)
                                        .background(Color.white.opacity(0.02))
                                        .cornerRadius(8)
                                }
                                .frame(maxHeight: 300)
                            } else {
                                Text("“暂无已生成的 AI 会议纪要。转写完成后，点击下方按钮，即可调用配置的大模型一键智能生成结构化会议纪要。”")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(.white.opacity(0.5))
                                    .lineSpacing(6)
                                    .padding(12)
                                    .background(Color.white.opacity(0.02))
                                    .cornerRadius(8)
                            }
                            
                            if transcriber.isSummarizing {
                                HStack(spacing: 8) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("大模型思考中...")
                                        .font(.system(size: 12))
                                        .foregroundColor(Color(hex: "A0A0B0"))
                                }
                                .padding(.top, 12)
                            } else {
                                if !settingsManager.customModels.isEmpty {
                                    VStack(spacing: 8) {
                                        if settingsManager.customModels.count > 1 {
                                            HStack {
                                                Text("模型选择")
                                                    .font(.system(size: 10))
                                                    .foregroundColor(Color(hex: "A0A0B0"))
                                                Picker("", selection: $summaryModelID) {
                                                    ForEach(settingsManager.customModels) { m in
                                                        Text(m.name).tag(m.id)
                                                    }
                                                }
                                                .pickerStyle(.menu)
                                                Spacer()
                                            }
                                        }
                                        Button(action: {
                                            if let model = settingsManager.customModels.first(where: { $0.id == summaryModelID }) {
                                                settingsManager.lastSummaryModelID = summaryModelID
                                                transcriber.startSummarization(
                                                    audioURL: transcriber.currentAudioURL,
                                                    outputDir: transcriber.currentOutputDir,
                                                    model: model,
                                                    pythonPath: envChecker.pythonPath,
                                                    summaryPrompt: settingsManager.summaryPrompt
                                                )
                                            }
                                        }) {
                                            HStack {
                                                Image(systemName: "sparkles")
                                                Text(transcriber.generatedSummary == nil ? "开始 AI 智能摘要" : "重新生成 AI 摘要")
                                            }
                                            .font(.system(size: 12, weight: .bold))
                                            .foregroundColor(.white)
                                            .padding(.horizontal, 14)
                                            .padding(.vertical, 8)
                                            .background(Color(hex: "8E81F6"))
                                            .cornerRadius(8)
                                        }
                                        .buttonStyle(.plain)
                                        .disabled(summaryModelID.isEmpty)
                                    }
                                    .padding(.top, 12)
                                } else {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text("未检测到配置的自定义大模型。")
                                            .font(.system(size: 12, weight: .bold))
                                            .foregroundColor(Color(hex: "F39C12"))
                                        
                                        Text("提示：请先在“设置”中配置自定义大模型 (LLM)，配置好之后在此处即可生成会议摘要。")
                                            .font(.system(size: 11))
                                            .foregroundColor(Color(hex: "A0A0B0").opacity(0.6))
                                            .lineSpacing(4)
                                    }
                                    .padding(12)
                                    .background(Color.white.opacity(0.02))
                                    .cornerRadius(8)
                                    .padding(.top, 12)
                                }
                            }
                        }
                        
                    case .actions:
                        VStack(alignment: .leading, spacing: 12) {
                            Text("待办任务清单")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(Color(hex: "A0A0B0").opacity(0.6))
                                .tracking(1)
                            
                            ForEach(actionItems) { item in
                                let isChecked = checkedItems.contains(item.id)
                                Button(action: {
                                    withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) {
                                        if isChecked {
                                            checkedItems.remove(item.id)
                                        } else {
                                            checkedItems.insert(item.id)
                                        }
                                    }
                                }) {
                                    HStack(alignment: .top, spacing: 10) {
                                        Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                                            .font(.system(size: 14))
                                            .foregroundColor(isChecked ? Color(hex: "4EC9B0") : Color(hex: "8E81F6").opacity(0.6))
                                            .padding(.top, 1)
                                        
                                        Text(item.text)
                                            .font(.system(size: 12))
                                            .foregroundColor(isChecked ? Color(hex: "A0A0B0").opacity(0.6) : .white)
                                            .strikethrough(isChecked, color: Color(hex: "A0A0B0").opacity(0.6))
                                            .multilineTextAlignment(.leading)
                                            .lineSpacing(4)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        
                    case .social:
                        VStack(alignment: .leading, spacing: 8) {
                            Text("多渠道宣发模版")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(Color(hex: "A0A0B0").opacity(0.6))
                                .tracking(1)
                            
                            Text("🚀 离线音频转写神器！VoiceScribe 迎来 v1.0 大版本更新！\n\n🔒 100% 本地运行，绝不上传任何音频文件，彻底守护你的会议与隐私安全。\n💻 双核引擎驱动：FunASR 智能识别 + VibeVoice MLX 极致加速，完美适配 M 芯片！\n\n#VoiceScribe #本地AI #语音识别 #macOS #效率工具")
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.8))
                                .lineSpacing(5)
                                .padding(12)
                                .background(Color.white.opacity(0.02))
                                .cornerRadius(8)
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)
            
            // Export Section
            VStack(spacing: 0) {
                Divider()
                    .background(Color.white.opacity(0.05))
                    .padding(.bottom, 12)
                
                Menu {
                    Button(action: { triggerExport(format: "pdf") }) {
                        Label("导出为 PDF 简报", systemImage: "doc.richtext")
                    }
                    Button(action: { triggerExport(format: "md") }) {
                        Label("导出为 Markdown 文本", systemImage: "text.alignleft")
                    }
                    Button(action: { triggerExport(format: "srt") }) {
                        Label("导出为 SRT 双语字幕", systemImage: "captions.bubble")
                    }
                } label: {
                    HStack {
                        Spacer()
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 12))
                        Text("导出本期文档")
                            .font(.system(size: 12, weight: .bold))
                        Spacer()
                    }
                    .foregroundColor(.white)
                    .padding(.vertical, 10)
                    .background(Color(hex: "34343D"))
                    .cornerRadius(10)
                }
                .menuStyle(.borderlessButton)
            }
        }
        .padding(18)
        .background(Color(hex: "1E1E2E").opacity(0.5))
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.05), lineWidth: 1)
        )
        .onAppear {
            if summaryModelID.isEmpty || !settingsManager.customModels.contains(where: { $0.id == summaryModelID }) {
                let preferred = !settingsManager.lastSummaryModelID.isEmpty
                    && settingsManager.customModels.contains(where: { $0.id == settingsManager.lastSummaryModelID })
                    ? settingsManager.lastSummaryModelID
                    : settingsManager.selectedModel
                summaryModelID = preferred
                if summaryModelID.isEmpty, let first = settingsManager.customModels.first {
                    summaryModelID = first.id
                }
            }
        }
    }
    
    private func triggerExport(format: String) {
        let savePanel = NSSavePanel()
        
        let baseName = transcriber.currentTranscriptTitle.isEmpty ? "VoiceScribe_Export" : transcriber.currentTranscriptTitle
        savePanel.nameFieldStringValue = "\(baseName).\(format)"
        
        if format == "pdf" {
            savePanel.allowedContentTypes = [.pdf]
        } else if format == "md" {
            savePanel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        } else if format == "srt" {
            savePanel.allowedContentTypes = [UTType(filenameExtension: "srt") ?? .plainText]
        } else {
            savePanel.allowedContentTypes = [.plainText]
        }
        
        savePanel.begin { response in
            if response == .OK, let url = savePanel.url {
                do {
                    switch format {
                    case "md":
                        let content = buildMarkdownExportContent()
                        try content.write(to: url, atomically: true, encoding: .utf8)
                    case "srt":
                        let srtContent = buildSRTContent()
                        try srtContent.write(to: url, atomically: true, encoding: .utf8)
                    case "pdf":
                        let text = buildTextForPDF()
                        if let pdfData = generatePDFData(from: text, title: baseName) {
                            try pdfData.write(to: url)
                        } else {
                            throw NSError(domain: "PDFGeneration", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to generate PDF data"])
                        }
                    default:
                        break
                    }
                } catch {
                    print("Export failed: \(error.localizedDescription)")
                }
            }
        }
    }
    
    private func buildMarkdownExportContent() -> String {
        var content = "# \(transcriber.currentTranscriptTitle) - VoiceScribe 导出报告\n\n"
        
        if let summary = transcriber.generatedSummary {
            content += "## 🎙️ AI 智能摘要与会议纪要\n\n\(summary)\n\n"
        }
        
        content += "## 📝 转写整理版正文\n\n"
        if let speakerTextURL = transcriber.currentSpeakerTextURL,
           let text = try? String(contentsOf: speakerTextURL, encoding: .utf8) {
            content += text
        } else {
            // Fallback from segments
            let nameMap = Dictionary(uniqueKeysWithValues: transcriber.speakerRoles.map {
                ($0.placeholder, $0.displayName.isEmpty ? $0.placeholder : $0.displayName)
            })
            for segment in transcriber.currentTranscriptSegments {
                let start = timestamp(from: segment.start)
                let name = nameMap[segment.placeholder] ?? segment.placeholder
                content += "[\(start)] 【\(name)】 \(segment.text)\n"
            }
        }
        return content
    }
    
    private func buildSRTContent() -> String {
        var srt = ""
        let nameMap = Dictionary(uniqueKeysWithValues: transcriber.speakerRoles.map {
            ($0.placeholder, $0.displayName.isEmpty ? $0.placeholder : $0.displayName)
        })
        
        for (index, segment) in transcriber.currentTranscriptSegments.enumerated() {
            srt += "\(index + 1)\n"
            let startStr = formatSRTTime(segment.start)
            let endStr = formatSRTTime(segment.end)
            srt += "\(startStr) --> \(endStr)\n"
            
            let speaker = nameMap[segment.placeholder] ?? segment.placeholder
            srt += "【\(speaker)】: \(segment.text)\n\n"
        }
        return srt
    }
    
    private func buildTextForPDF() -> String {
        return buildMarkdownExportContent()
    }
    
    private func formatSRTTime(_ seconds: Double) -> String {
        let hrs = Int(seconds) / 3600
        let mins = (Int(seconds) % 3600) / 60
        let secs = Int(seconds) % 60
        let ms = Int((seconds.truncatingRemainder(dividingBy: 1)) * 1000)
        return String(format: "%02d:%02d:%02d,%03d", hrs, mins, secs, ms)
    }
    
    private func timestamp(from seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
    
    private func generatePDFData(from text: String, title: String) -> Data? {
        let pdfMetaData = [
            kCGPDFContextCreator: "VoiceScribe",
            kCGPDFContextTitle: title
        ] as CFDictionary
        
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let pdfContext = CGContext(consumer: consumer, mediaBox: nil, pdfMetaData) else {
            return nil
        }
        
        let font = NSFont.systemFont(ofSize: 12)
        let titleFont = NSFont.boldSystemFont(ofSize: 18)
        
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 4
        
        let attributedString = NSMutableAttributedString()
        attributedString.append(NSAttributedString(string: title + "\n\n", attributes: [
            .font: titleFont,
            .foregroundColor: NSColor.black
        ]))
        attributedString.append(NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: NSColor.black,
            .paragraphStyle: style
        ]))
        
        let framesetter = CTFramesetterCreateWithAttributedString(attributedString)
        var range = CFRangeMake(0, 0)
        var pageNum = 1
        let margin: CGFloat = 54
        let pageSize = CGSize(width: 612, height: 792) // Letter size
        let textRect = CGRect(x: margin, y: margin, width: pageSize.width - margin * 2, height: pageSize.height - margin * 2)
        
        while range.location < attributedString.length {
            pdfContext.beginPage(mediaBox: nil)
            
            // Draw text
            let path = CGPath(rect: textRect, transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, range, path, nil)
            CTFrameDraw(frame, pdfContext)
            
            let visibleRange = CTFrameGetVisibleStringRange(frame)
            range.location += visibleRange.length
            
            pdfContext.endPage()
            pageNum += 1
        }
        
        pdfContext.closePDF()
        return data as Data
    }
}
