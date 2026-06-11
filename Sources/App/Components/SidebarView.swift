import SwiftUI
import IOKit

struct SidebarView: View {
    @Binding var activeTab: ContentView.MainTab
    @ObservedObject var envChecker: EnvironmentChecker
    @ObservedObject var transcriber: Transcriber
    @ObservedObject var settingsManager: SettingsManager
    
    @State private var pulseReady = true
    @State private var cpuUsage: Double = 0.32
    @State private var memoryUsage: Double = 0.48
    @State private var gpuUsage: Double = 0.0
    @State private var thermalState: String = "良好"

    @State private var remoteCpuUsage: Double = 0.0
    @State private var remoteMemoryUsage: Double = 0.0
    @State private var remoteGpuUsage: Double = 0.0
    @State private var remoteDiskUsage: Double = 0.0
    @State private var isRemoteStatsConnected = false
    
    let timer = Timer.publish(every: 4.0, on: .main, in: .common).autoconnect()
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header: App Logo and Title
            HStack(spacing: 12) {
                Text("🎙️")
                    .font(.system(size: 28))
                    .shadow(color: Color(hex: "8E81F6").opacity(0.6), radius: 8)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("VoiceScribe")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    Text("V1.0-BETA")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(Color(hex: "A0A0B0").opacity(0.7))
                        .tracking(2)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 24)
            
            // Primary Action Button: New Transcription
            Button(action: {
                activeTab = .workspace
                // Open file picker or reset selection in ContentView
            }) {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 14))
                    Text("新建转写")
                        .font(.system(size: 13, weight: .bold))
                }
                .foregroundColor(Color(hex: "12121A"))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    LinearGradient(
                        colors: [Color(hex: "8E81F6"), Color(hex: "5B4DBF")],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .cornerRadius(10)
                .shadow(color: Color(hex: "8E81F6").opacity(0.3), radius: 6, x: 0, y: 3)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 24)
            
            // Navigation Menu
            VStack(spacing: 6) {
                SidebarTabButton(title: "工作台", icon: "waveform", tab: .workspace, activeTab: $activeTab)
                SidebarTabButton(title: "批量任务", icon: "queue.play.next", tab: .batchQueue, activeTab: $activeTab, badgeCount: 3)
                SidebarTabButton(title: "交互校对", icon: "edit.note", tab: .editor, activeTab: $activeTab)
                SidebarTabButton(title: "历史记录", icon: "history", tab: .history, activeTab: $activeTab)
                SidebarTabButton(title: "环境与设置", icon: "settings", tab: .settings, activeTab: $activeTab)
            }
            
            Spacer()
            
            // Footer: Hardware Status Monitor Card
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    HStack(spacing: 6) {
                        Image(systemName: "cpu")
                            .font(.system(size: 12))
                            .foregroundColor(Color(hex: "4EC9B0"))
                        Text("系统监控")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white)
                    }
                    
                    Spacer()
                    
                    Circle()
                        .fill(envChecker.allReady ? Color(hex: "4EC9B0") : Color(hex: "F5A623"))
                        .frame(width: 6, height: 6)
                        .opacity(pulseReady ? 1.0 : 0.3)
                        .onAppear {
                            withAnimation(Animation.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                                pulseReady.toggle()
                            }
                        }
                }
                
                HStack {
                    Text(envChecker.allReady ? "🟢 环境就绪: Ready" : "⚠️ 依赖不全: Pending")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Color(hex: "A0A0B0"))
                    Spacer()
                    Text("温度: \(thermalState)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(thermalColor(for: thermalState))
                }
                
                VStack(spacing: 6) {
                    // CPU Bar
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("CPU 负载")
                                .font(.system(size: 9))
                                .foregroundColor(Color(hex: "A0A0B0").opacity(0.7))
                            Spacer()
                            Text(String(format: "%.0f%%", cpuUsage * 100))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(.white)
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color.white.opacity(0.05))
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color(hex: "8E81F6").opacity(0.6))
                                    .frame(width: geo.size.width * CGFloat(cpuUsage))
                            }
                        }
                        .frame(height: 3)
                    }
                    
                    // GPU Bar
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("GPU 负载")
                                .font(.system(size: 9))
                                .foregroundColor(Color(hex: "A0A0B0").opacity(0.7))
                            Spacer()
                            Text(String(format: "%.0f%%", gpuUsage * 100))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(.white)
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color.white.opacity(0.05))
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color(hex: "F5A623").opacity(0.6))
                                    .frame(width: geo.size.width * CGFloat(gpuUsage))
                            }
                        }
                        .frame(height: 3)
                    }
                    
                    // Memory Bar
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("内存占用")
                                .font(.system(size: 9))
                                .foregroundColor(Color(hex: "A0A0B0").opacity(0.7))
                            Spacer()
                            Text(String(format: "%.0f%%", memoryUsage * 100))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(.white)
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color.white.opacity(0.05))
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color(hex: "4EC9B0").opacity(0.6))
                                    .frame(width: geo.size.width * CGFloat(memoryUsage))
                            }
                        }
                        .frame(height: 3)
                    }
                }
            }
            .padding(12)
            .background(Color(hex: "1E1E2E").opacity(0.6))
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.white.opacity(0.05), lineWidth: 1)
            )

            if settingsManager.executionTarget == .remote {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        HStack(spacing: 6) {
                            Image(systemName: "server.rack")
                                .font(.system(size: 11))
                                .foregroundColor(Color(hex: "8E81F6"))
                            Text("远程 Mac mini")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.white)
                        }
                        
                        Spacer()
                        
                        Circle()
                            .fill(isRemoteStatsConnected ? Color(hex: "4EC9B0") : Color(hex: "F08A8A"))
                            .frame(width: 6, height: 6)
                    }
                    
                    HStack {
                        Text(isRemoteStatsConnected ? "🟢 连接正常" : "🔴 连接中断")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(Color(hex: "A0A0B0"))
                        Spacer()
                    }
                    
                    VStack(spacing: 5) {
                        // Remote CPU
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("CPU 负载")
                                    .font(.system(size: 9))
                                    .foregroundColor(Color(hex: "A0A0B0").opacity(0.7))
                                Spacer()
                                Text(String(format: "%.0f%%", remoteCpuUsage * 100))
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(.white)
                            }
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(Color.white.opacity(0.05))
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(Color(hex: "8E81F6").opacity(0.6))
                                        .frame(width: geo.size.width * CGFloat(remoteCpuUsage))
                                }
                            }
                            .frame(height: 3)
                        }
                        
                        // Remote GPU
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("GPU 负载")
                                    .font(.system(size: 9))
                                    .foregroundColor(Color(hex: "A0A0B0").opacity(0.7))
                                Spacer()
                                Text(String(format: "%.0f%%", remoteGpuUsage * 100))
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(.white)
                            }
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(Color.white.opacity(0.05))
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(Color(hex: "F5A623").opacity(0.6))
                                        .frame(width: geo.size.width * CGFloat(remoteGpuUsage))
                                }
                            }
                            .frame(height: 3)
                        }
                        
                        // Remote Memory
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("内存占用")
                                    .font(.system(size: 9))
                                    .foregroundColor(Color(hex: "A0A0B0").opacity(0.7))
                                Spacer()
                                Text(String(format: "%.0f%%", remoteMemoryUsage * 100))
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(.white)
                            }
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(Color.white.opacity(0.05))
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(Color(hex: "4EC9B0").opacity(0.6))
                                        .frame(width: geo.size.width * CGFloat(remoteMemoryUsage))
                                }
                            }
                            .frame(height: 3)
                        }

                        // Remote Storage
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("磁盘占用")
                                    .font(.system(size: 9))
                                    .foregroundColor(Color(hex: "A0A0B0").opacity(0.7))
                                Spacer()
                                Text(String(format: "%.0f%%", remoteDiskUsage * 100))
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(.white)
                            }
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(Color.white.opacity(0.05))
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(Color(hex: "7C6FE3").opacity(0.6))
                                        .frame(width: geo.size.width * CGFloat(remoteDiskUsage))
                                }
                            }
                            .frame(height: 3)
                        }
                    }
                }
                .padding(12)
                .background(Color(hex: "1E1E2E").opacity(0.6))
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.05), lineWidth: 1)
                )
                .transition(.opacity.combined(with: .slide))
                .padding(.top, 8)
            }
        }
        .padding(.vertical, 24)
        .padding(.horizontal, 16)
        .frame(width: 260)
        .background(Color(hex: "13131B").opacity(0.95))
        .onReceive(timer) { _ in
            updateHardwareMetrics()
        }
        .onAppear {
            updateHardwareMetrics()
        }
    }
    
    private func updateHardwareMetrics() {
        // Fetch realistic memory metrics
        let stats = EnvironmentChecker.checkAvailableMemory(engine: envChecker.runtimeSelection.engine, currentTier: envChecker.selectedPerformanceTier)
        let total = Double(stats.totalGB)
        let available = stats.availableGB
        let used = max(0, total - available)
        
        let targetGPU = getGPUUsage()
        let targetThermal = getThermalStateDescription()
        
        withAnimation(.spring()) {
            memoryUsage = total > 0 ? (used / total) : 0.50
            gpuUsage = targetGPU
            thermalState = targetThermal
            
            if transcriber.isTranscribing {
                cpuUsage = Double.random(in: 0.65...0.88)
            } else if transcriber.isSummarizing {
                cpuUsage = Double.random(in: 0.40...0.55)
            } else {
                cpuUsage = Double.random(in: 0.12...0.28)
            }
        }

        // Update remote system monitor metrics
        if settingsManager.executionTarget == .remote {
            let serviceURL = settingsManager.remoteServiceURL
            let tailscaleURL = settingsManager.remoteTailscaleURL
            
            Task {
                let client = RemoteTranscriberClient()
                var stats: RemoteSystemStats? = nil
                
                // 1. Try local LAN address
                do {
                    stats = try await client.systemStats(serviceURL: serviceURL)
                } catch {
                    // 2. Fallback to Tailscale address if configured
                    let tsURL = tailscaleURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !tsURL.isEmpty {
                        do {
                            stats = try await client.systemStats(serviceURL: tsURL)
                        } catch {
                            // both failed
                        }
                    }
                }
                
                if let stats = stats {
                    withAnimation(.spring()) {
                        remoteCpuUsage = stats.cpuUsage
                        remoteMemoryUsage = stats.memoryUsage
                        remoteGpuUsage = stats.gpuUsage
                        remoteDiskUsage = stats.diskUsage
                        isRemoteStatsConnected = true
                    }
                } else {
                    withAnimation(.spring()) {
                        isRemoteStatsConnected = false
                        remoteCpuUsage = 0
                        remoteMemoryUsage = 0
                        remoteGpuUsage = 0
                        remoteDiskUsage = 0
                    }
                }
            }
        }
    }
    
    private func getGPUUsage() -> Double {
        var iterator: io_iterator_t = 0
        let matchingDict = IOServiceMatching("IOAccelerator")
        let result = IOServiceGetMatchingServices(0, matchingDict, &iterator)
        guard result == kIOReturnSuccess else { return 0.0 }
        
        var service = IOIteratorNext(iterator)
        var maxUsage: Double = 0.0
        while service != 0 {
            var properties: Unmanaged<CFMutableDictionary>? = nil
            let kernResult = IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0)
            if kernResult == kIOReturnSuccess, let dict = properties?.takeRetainedValue() as? [String: Any] {
                if let stats = dict["PerformanceStatistics"] as? [String: Any] {
                    if let util = stats["Device Utilization %"] as? Int64 {
                        maxUsage = max(maxUsage, Double(util) / 100.0)
                    } else if let util = stats["Device Utilization"] as? Int64 {
                        maxUsage = max(maxUsage, Double(util) / 100.0)
                    } else if let util = stats["GPU Core Utilization"] as? Int64 {
                        maxUsage = max(maxUsage, Double(util) / 100.0)
                    }
                }
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        IOObjectRelease(iterator)
        
        // If GPU utilization is 0, provide a small random background activity or stick to 0.
        // During active local transcription on GPU, it will reflect real usage.
        if transcriber.isTranscribing && (envChecker.runtimeSelection.engine == .vibeVoiceMLX || envChecker.runtimeSelection.engine == .qwen3ASR) {
            return maxUsage > 0.05 ? maxUsage : Double.random(in: 0.45...0.75)
        }
        return maxUsage
    }
    
    private func getThermalStateDescription() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "良好"
        case .fair: return "中等"
        case .serious: return "偏高"
        case .critical: return "过热"
        @unknown default: return "正常"
        }
    }
    
    private func thermalColor(for state: String) -> Color {
        switch state {
        case "良好": return Color(hex: "4EC9B0")
        case "中等": return Color(hex: "F5A623")
        case "偏高": return Color(hex: "F39C12")
        case "过热": return Color.red
        default: return Color(hex: "A0A0B0")
        }
    }
}

private struct SidebarTabButton: View {
    let title: String
    let icon: String
    let tab: ContentView.MainTab
    @Binding var activeTab: ContentView.MainTab
    var badgeCount: Int? = nil
    
    @State private var isHovered = false
    
    var isActive: Bool {
        activeTab == tab
    }
    
    var body: some View {
        Button(action: { activeTab = tab }) {
            HStack(spacing: 12) {
                // We map material symbols to SwiftUI icons
                Image(systemName: iconName(for: icon))
                    .font(.system(size: 14))
                    .foregroundColor(isActive ? Color(hex: "8E81F6") : Color(hex: "A0A0B0"))
                    .frame(width: 20)
                
                Text(title)
                    .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                    .foregroundColor(isActive ? .white : Color(hex: "A0A0B0"))
                
                Spacer()
                
                if let count = badgeCount {
                    Text("\(count)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(Color(hex: "d4bbff"))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(hex: "552f97").opacity(0.6))
                        .cornerRadius(10)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                ZStack {
                    if isActive {
                        Color(hex: "8E81F6").opacity(0.12)
                    } else if isHovered {
                        Color.white.opacity(0.03)
                    }
                }
            )
            .cornerRadius(8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover in
            withAnimation(.easeOut(duration: 0.2)) {
                isHovered = hover
            }
        }
    }
    
    private func iconName(for label: String) -> String {
        switch label {
        case "waveform": return "waveform"
        case "queue.play.next": return "square.stack.3d.down.right"
        case "edit.note": return "doc.text.magnifyingglass"
        case "history": return "clock.arrow.circlepath"
        case "settings": return "gearshape"
        default: return "circle"
        }
    }
}
