import Foundation
import Combine
import AppKit

struct DependencyStatus: Identifiable {
    let id = UUID()
    let name: String
    let icon: String
    var isReady: Bool
    var message: String
    var action: (() -> Void)?
}

struct RuntimeSelection {
    var environment: RuntimeEnvironment
    var engine: TranscriptionEngine
    var modelID: String
}

struct PerformanceProfile {
    var device: String
    var threads: Int
    var batchSizeSeconds: Int
    var mergeLengthSeconds: Int
    var speakerDiarizationEnabled: Bool
    var mpsAvailable: Bool
    var summary: String

    static let automatic = PerformanceProfile(
        device: "cpu",
        threads: 2,
        batchSizeSeconds: 60,
        mergeLengthSeconds: 15,
        speakerDiarizationEnabled: true,
        mpsAvailable: false,
        summary: "尚未预热，使用保守默认配置"
    )
}

enum PerformanceTier: String, CaseIterable, Identifiable {
    case low
    case medium
    case high

    var id: String { rawValue }

    var title: String {
        switch self {
        case .low:
            return "低"
        case .medium:
            return "中"
        case .high:
            return "高"
        }
    }

    var description: String {
        switch self {
        case .low:
            return "更省资源，适合低配机器"
        case .medium:
            return "均衡速度和稳定性"
        case .high:
            return "更高吞吐，适合高配机器"
        }
    }
}

@MainActor
class EnvironmentChecker: ObservableObject {
    @Published var deps: [DependencyStatus] = []
    @Published var pythonPath: String = ""
    @Published var pythonSitePackages: String = ""
    @Published var isInstallingDependency = false
    @Published var installMessage: String = ""
    @Published var isChecking = false
    @Published var hasChecked = false
    @Published var checkProgress = "尚未预热环境"
    @Published var performanceProfile = PerformanceProfile.automatic
    @Published var recommendedPerformanceTier: PerformanceTier = .medium
    @Published var selectedPerformanceTier: PerformanceTier = .medium
    @Published var recommendationDetail: String = "尚未预热"
    var customPythonPath: String = ""
    var savedPerformanceTier: PerformanceTier?

    var runtimeSelection = RuntimeSelection(
        environment: .macAppleSilicon,
        engine: .funASR,
        modelID: TranscriptionEngine.funASR.defaultModelID
    )

    var allReady: Bool {
        let required = Self.requiredDependencyNames(for: runtimeSelection.engine)
        return required.allSatisfy { name in
            deps.contains { $0.name == name && $0.isReady }
        }
    }

    func check() {
        warmUp()
    }

    func initialize(cachedPythonPath: String) {
        let trimmed = cachedPythonPath.trimmingCharacters(in: .whitespacesAndNewlines)
        pythonPath = trimmed
        customPythonPath = trimmed
        deps = []
        performanceProfile = PerformanceProfile.automatic
        recommendedPerformanceTier = .medium
        selectedPerformanceTier = .medium
        recommendationDetail = "尚未预热"
        hasChecked = false
        if trimmed.isEmpty {
            checkProgress = "请先选择运行环境和转写引擎，再点击“预热环境”进行检测"
        } else {
            checkProgress = "已加载当前 Python，选择引擎后点击“预热环境”开始检测"
            deps = [
                DependencyStatus(
                    name: "python3",
                    icon: "chevron.left.forwardslash.chevron.right",
                    isReady: true,
                    message: "上次使用\n\(trimmed)"
                )
            ]
        }
    }

    func updateRuntimeSelection(environment: RuntimeEnvironment, engine: TranscriptionEngine, modelID: String) {
        runtimeSelection = RuntimeSelection(environment: environment, engine: engine, modelID: modelID)
        deps = pythonPath.isEmpty ? [] : [
            DependencyStatus(
                name: "python3",
                icon: "chevron.left.forwardslash.chevron.right",
                isReady: true,
                message: "当前配置\n\(pythonPath)"
            )
        ]
        hasChecked = false
        performanceProfile = PerformanceProfile.automatic
        recommendedPerformanceTier = .medium
        selectedPerformanceTier = .medium
        recommendationDetail = "请先预热环境获取推荐依据"
        checkProgress = "当前选择：\(engine.title)。点击“预热环境”检测依赖和模型。"
        installMessage = ""
    }

    func warmUp() {
        guard !isChecking else { return }
        isChecking = true
        hasChecked = false
        checkProgress = "正在检测 \(runtimeSelection.engine.title) 依赖..."
        installMessage = ""

        let requestedPythonPath = customPythonPath
        let runtimeSelection = runtimeSelection
        Task.detached(priority: .userInitiated) {
            let result = Self.performEnvironmentCheck(customPythonPath: requestedPythonPath, runtimeSelection: runtimeSelection)
            await MainActor.run {
                self.pythonPath = result.pythonPath
                self.pythonSitePackages = result.pythonSitePackages
                self.deps = result.deps
                self.performanceProfile = result.performanceProfile
                self.recommendedPerformanceTier = result.recommendedPerformanceTier
                // 优先恢复用户上次手动选择的档位
                if let saved = self.savedPerformanceTier {
                    self.selectedPerformanceTier = saved
                    self.applyPerformanceTier(saved)
                    self.savedPerformanceTier = nil
                } else {
                    self.selectedPerformanceTier = result.recommendedPerformanceTier
                }
                self.recommendationDetail = result.recommendationDetail
                self.checkProgress = result.progressMessage
                self.isChecking = false
                self.hasChecked = true
            }
        }
    }

    func applyPerformanceTier(_ tier: PerformanceTier) {
        selectedPerformanceTier = tier
        let detected = Self.detectPerformanceProfile(pythonPath: pythonPath, engine: runtimeSelection.engine)
        performanceProfile = Self.profile(for: tier, detected: detected, engine: runtimeSelection.engine)
        checkProgress = "已切换到\(tier.title)档，可直接开始转写。"
    }

    nonisolated private struct EnvironmentCheckResult {
        var pythonPath: String
        var pythonSitePackages: String
        var deps: [DependencyStatus]
        var performanceProfile: PerformanceProfile
        var recommendedPerformanceTier: PerformanceTier
        var recommendationDetail: String
        var progressMessage: String
    }

    nonisolated private static func performEnvironmentCheck(customPythonPath: String, runtimeSelection: RuntimeSelection) -> EnvironmentCheckResult {
        let pythonDetection = detectPython(customPythonPath: customPythonPath, engine: runtimeSelection.engine)
        let pythonPath = pythonDetection.path
        var deps: [DependencyStatus] = []

        deps.append(checkFFmpegStatus())
        deps.append(checkPythonStatus(pythonPath))
        switch runtimeSelection.engine {
        case .funASR:
            deps.append(checkFunASRStatus(pythonPath))
            deps.append(checkFunASRModelsStatus(pythonPath))
        case .vibeVoiceMLX:
            deps.append(checkMLXAudioStatus(pythonPath))
            deps.append(checkMLXModelStatus(pythonPath, modelID: runtimeSelection.modelID))
        }

        let detection = detectPerformanceProfile(pythonPath: pythonPath, engine: runtimeSelection.engine)
        let recommendedTier = detectRecommendedPerformanceTier(profile: detection, engine: runtimeSelection.engine)
        let profile = profile(for: recommendedTier, detected: detection, engine: runtimeSelection.engine)
        let detail = recommendationDetail(from: detection, recommendedTier: recommendedTier, engine: runtimeSelection.engine)
        let readyCount = deps.filter(\.isReady).count
        let progress = "预热完成：\(readyCount)/\(deps.count) 项可用，\(runtimeSelection.engine.title)，推荐\(recommendedTier.title)档"

        return EnvironmentCheckResult(
            pythonPath: pythonPath,
            pythonSitePackages: pythonDetection.sitePackages,
            deps: deps,
            performanceProfile: profile,
            recommendedPerformanceTier: recommendedTier,
            recommendationDetail: detail,
            progressMessage: progress
        )
    }

    /// 自动探测 FunASR 对应的 Python：扫描所有 python3，逐个测试 import funasr
    nonisolated private static func detectPython(customPythonPath: String, engine: TranscriptionEngine) -> (path: String, sitePackages: String) {
        var candidates: [String] = []

        // 用户手动指定的 Python 永远优先。
        let trimmedCustomPath = customPythonPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedCustomPath.isEmpty {
            candidates.append(trimmedCustomPath)
        }

        appendUniquePythonCandidates(from: discoverPythonCandidates(), to: &candidates)

        for p in candidates {
            let isUsable: Bool
            switch engine {
            case .funASR:
                isUsable = pythonCanImportFunASR(p)
            case .vibeVoiceMLX:
                isUsable = pythonCanImportMLXAudio(p)
            }
            guard isUsable else { continue }
            return (p, sitePackagesPath(for: p))
        }

        return (candidates.first ?? "python3", "")
    }

    nonisolated private static func discoverPythonCandidates() -> [String] {
        let appPython = appManagedPythonPath()
        let knownPaths = [
            appPython,
            "/opt/anaconda3/bin/python3",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3",
        ]
        var candidates = knownPaths
        candidates.append(contentsOf: runShell("which -a python3 2>/dev/null").components(separatedBy: "\n"))
        candidates.append(contentsOf: runShell("find /opt/anaconda3/envs /opt/homebrew/Caskroom/miniconda/base/envs -maxdepth 3 -path '*/bin/python3' -type f 2>/dev/null").components(separatedBy: "\n"))
        return candidates
    }

    nonisolated private static func appendUniquePythonCandidates(from paths: [String], to candidates: inout [String]) {
        for path in paths {
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !candidates.contains(trimmed) else { continue }
            guard FileManager.default.isExecutableFile(atPath: trimmed) else { continue }
            candidates.append(trimmed)
        }
    }

    nonisolated private static func pythonCanImportFunASR(_ python: String) -> Bool {
        runPython(
            python,
            code: "import funasr; print('FUNOK')",
            cleanPythonEnvironment: true
        ).contains("FUNOK")
    }

    nonisolated private static func pythonCanImportMLXAudio(_ python: String) -> Bool {
        runPython(
            python,
            code: "import importlib.util; print('MLXOK' if importlib.util.find_spec('mlx_audio') else '')",
            cleanPythonEnvironment: true
        ).contains("MLXOK")
    }

    nonisolated private static func appManagedPythonPath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".voicescribe")
            .appendingPathComponent("venv")
            .appendingPathComponent("bin")
            .appendingPathComponent("python3")
            .path
    }

    nonisolated private static func sitePackagesPath(for python: String) -> String {
        let code = "import site; paths = site.getsitepackages(); print(paths[0] if paths else '')"
        return runPython(python, code: code, cleanPythonEnvironment: true)
            .components(separatedBy: "\n")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    nonisolated private static func runPython(_ python: String, code: String, cleanPythonEnvironment: Bool = false) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: python)
        task.arguments = ["-c", code]
        if cleanPythonEnvironment {
            var env = ProcessInfo.processInfo.environment
            env.removeValue(forKey: "PYTHONPATH")
            env.removeValue(forKey: "PYTHONHOME")
            task.environment = env
        }
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }

    nonisolated private static func runShell(_ command: String) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-c", command]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }

    nonisolated private static func checkFFmpegStatus() -> DependencyStatus {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        task.arguments = ["ffmpeg"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            let verTask = Process()
            verTask.executableURL = URL(fileURLWithPath: "/bin/bash")
            verTask.arguments = ["-c", "\(path.isEmpty ? "ffmpeg" : path) -version 2>&1 | head -1"]
            let verPipe = Pipe()
            verTask.standardOutput = verPipe
            verTask.standardError = verPipe
            try verTask.run()
            verTask.waitUntilExit()
            let verData = verPipe.fileHandleForReading.readDataToEndOfFile()
            let ver = String(data: verData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            return DependencyStatus(
                name: "ffmpeg", icon: "play.rectangle.fill",
                isReady: task.terminationStatus == 0,
                message: task.terminationStatus == 0 ? "✓ \(ver)" : "✗ 未找到"
            )
        } catch {
            return DependencyStatus(
                name: "ffmpeg", icon: "play.rectangle.fill",
                isReady: false, message: "✗ 未找到"
            )
        }
    }

    nonisolated private static func checkPythonStatus(_ python: String) -> DependencyStatus {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: python)
        task.arguments = ["--version"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            let version = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return DependencyStatus(
                name: "python3", icon: "chevron.left.forwardslash.chevron.right",
                isReady: task.terminationStatus == 0,
                message: task.terminationStatus == 0 ? "✓ \(version)\n\(python)" : "✗ 未找到"
            )
        } catch {
            return DependencyStatus(
                name: "python3", icon: "chevron.left.forwardslash.chevron.right",
                isReady: false, message: "✗ 未找到"
            )
        }
    }

    nonisolated private static func checkFunASRStatus(_ python: String) -> DependencyStatus {
        let output = runPython(python, code: "import funasr; print('OK')", cleanPythonEnvironment: true)
        return DependencyStatus(
            name: "funasr", icon: "waveform",
            isReady: output.contains("OK"),
            message: output.contains("OK") ? "✓ FunASR 已安装" : "✗ 此 Python 未安装 FunASR"
        )
    }

    nonisolated private static func checkFunASRModelsStatus(_ python: String) -> DependencyStatus {
        let models = ["paraformer-zh", "fsmn-vad", "ct-punc", "cam++"]

        // 用 python 查 modelscope 模型缓存路径
        let script = """
        \(python) -c \"
        import os, sys
        try:
            from modelscope.hub.api import HubApi
            api = HubApi()
            cache_dirs = api.get_cache_dir()
            print(';'.join(cache_dirs))
        except Exception as e:
            print('', file=sys.stderr)
        \" 2>&1
        """

        var searchPaths: [URL] = []
        let findTask = Process()
        findTask.executableURL = URL(fileURLWithPath: "/bin/bash")
        findTask.arguments = ["-c", script]
        let findPipe = Pipe()
        findTask.standardOutput = findPipe
        findTask.standardError = findPipe
        do {
            try findTask.run()
            findTask.waitUntilExit()
            let data = findPipe.fileHandleForReading.readDataToEndOfFile()
            if let out = String(data: data, encoding: .utf8) {
                for line in out.components(separatedBy: ";") {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        searchPaths.append(URL(fileURLWithPath: trimmed))
                    }
                }
            }
        } catch { }

        // 备选：常见路径
        let home = FileManager.default.homeDirectoryForCurrentUser
        let fallback = [
            home.appendingPathComponent(".cache/modelscope/hub/models/iic"),
            home.appendingPathComponent(".cache/modelscope/hub/damo"),
            home.appendingPathComponent(".cache/huggingface/hub"),
        ]
        for p in fallback {
            if !searchPaths.contains(p) && FileManager.default.fileExists(atPath: p.path) {
                searchPaths.append(p)
            }
        }

        // 扫描模型目录
        var modelDirs: [URL] = []
        for base in searchPaths {
            if let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                while let url = enumerator.nextObject() as? URL {
                    var isDir: ObjCBool = false
                    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                        modelDirs.append(url)
                    }
                }
            }
        }

        var missing: [String] = []
        for m in models {
            // 模糊匹配：模型名包含关键词即可
            let keywords: [String]
            switch m {
            case "paraformer-zh":
                keywords = ["paraformer", "seaco_paraformer"]
            case "fsmn-vad":
                keywords = ["fsmn_vad", "vad_zh-cn"]
            case "ct-punc":
                keywords = ["ct_punc", "punc_zh-cn", "ct_transformer", "ct-transformer", "punc_ct-transformer"]
            case "cam++":
                keywords = ["campplus", "cam++", "cam_plus"]
            default:
                keywords = [m]
            }

            var found = false
            for dir in modelDirs {
                let name = dir.lastPathComponent
                if keywords.contains(where: { name.contains($0) }) {
                    found = true
                    break
                }
            }
            if !found { missing.append(m) }
        }

        if missing.isEmpty {
            return DependencyStatus(
                name: "models", icon: "folder.fill",
                isReady: true, message: "✓ 全部模型已下载"
            )
        } else {
            return DependencyStatus(
                name: "models", icon: "folder.fill",
                isReady: false,
                message: "⚠️ 缺少: \(missing.joined(separator: ", "))",
                action: nil
            )
        }
    }

    nonisolated private static func checkMLXAudioStatus(_ python: String) -> DependencyStatus {
        let code = """
        import importlib.util
        spec = importlib.util.find_spec('mlx_audio')
        print('OK' if spec is not None else '')
        """
        let output = runPython(python, code: code, cleanPythonEnvironment: true)
        return DependencyStatus(
            name: "mlx-audio", icon: "cpu",
            isReady: output.contains("OK"),
            message: output.contains("OK") ? "✓ MLX Audio 已安装" : "✗ 此 Python 未安装 mlx_audio"
        )
    }

    nonisolated private static func checkMLXModelStatus(_ python: String, modelID: String) -> DependencyStatus {
        let hasMLXAudio = pythonCanImportMLXAudio(python)
        guard hasMLXAudio else {
            return DependencyStatus(
                name: "mlx-model", icon: "cube.box.fill",
                isReady: false,
                message: "✗ 请先安装 mlx_audio 依赖"
            )
        }
        let sanitizedModelID = modelID.replacingOccurrences(of: "'", with: "")
        let code = """
        import os
        from huggingface_hub import snapshot_download
        try:
            path = snapshot_download(repo_id='\(sanitizedModelID)', local_files_only=True)
            print(path)
        except Exception:
            print('')
        """
        let output = runPython(python, code: code, cleanPythonEnvironment: true)
        let isReady = !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return DependencyStatus(
            name: "mlx-model", icon: "cube.box.fill",
            isReady: isReady,
            message: isReady ? "✓ MLX 模型已缓存" : "✗ 未检测到 \(modelID)"
        )
    }

    nonisolated private static func detectPerformanceProfile(pythonPath: String, engine: TranscriptionEngine) -> PerformanceProfile {
        let totalCores = intFromShell("sysctl -n hw.ncpu 2>/dev/null", fallback: ProcessInfo.processInfo.processorCount)
        let performanceCores = intFromShell("sysctl -n hw.perflevel0.physicalcpu 2>/dev/null", fallback: max(1, totalCores - 2))
        let memoryBytes = int64FromShell("sysctl -n hw.memsize 2>/dev/null", fallback: Int64(ProcessInfo.processInfo.physicalMemory))
        let memoryGB = max(1, Int(memoryBytes / 1_073_741_824))
        let cpuBrand = runShell("sysctl -n machdep.cpu.brand_string 2>/dev/null").trimmingCharacters(in: .whitespacesAndNewlines)
        let mpsAvailable = pythonSupportsMPS(pythonPath)

        let usefulCores = max(1, performanceCores > 0 ? performanceCores : totalCores)
        let threads: Int
        // 限制线程数避免 CPU 占满：最多使用一半性能核心
        if memoryGB >= 32 && usefulCores >= 10 {
            threads = min(usefulCores / 2, 6)
        } else if memoryGB >= 16 && usefulCores >= 6 {
            threads = min(usefulCores / 2, 4)
        } else {
            threads = min(max(1, usefulCores / 2), 2)
        }

        let batchSizeSeconds: Int
        // 减小批处理大小以降低内存峰值
        if memoryGB >= 32 {
            batchSizeSeconds = 120
        } else if memoryGB >= 16 {
            batchSizeSeconds = 90
        } else {
            batchSizeSeconds = 60
        }

        let device = engine == .vibeVoiceMLX ? "mlx" : "cpu"
        let chipText = cpuBrand.isEmpty ? "\(totalCores) 核 CPU" : cpuBrand
        let accelerationHint: String
        if engine == .vibeVoiceMLX {
            accelerationHint = "，优先使用 Apple Silicon MLX"
        } else {
            accelerationHint = mpsAvailable ? "，检测到 MPS 可用但暂不默认启用" : ""
        }
        let summary = "自动性能：\(threads) 线程，batch \(batchSizeSeconds)s，\(engine == .vibeVoiceMLX ? "MLX 模式" : "CPU 稳定模式")\(accelerationHint)（\(chipText)，\(memoryGB)GB）"

        return PerformanceProfile(
            device: device,
            threads: threads,
            batchSizeSeconds: batchSizeSeconds,
            mergeLengthSeconds: 15,
            speakerDiarizationEnabled: true,
            mpsAvailable: mpsAvailable,
            summary: summary
        )
    }

    nonisolated private static func detectRecommendedPerformanceTier(profile: PerformanceProfile, engine: TranscriptionEngine) -> PerformanceTier {
        let memoryBytes = int64FromShell("sysctl -n hw.memsize 2>/dev/null", fallback: Int64(ProcessInfo.processInfo.physicalMemory))
        let memoryGB = max(1, Int(memoryBytes / 1_073_741_824))
        let threads = profile.threads

        switch engine {
        case .vibeVoiceMLX:
            if memoryGB >= 32 && threads >= 4 {
                return .high
            } else if memoryGB >= 16 {
                return .medium
            } else {
                return .low
            }
        case .funASR:
            if memoryGB >= 24 && threads >= 4 {
                return .high
            } else if memoryGB >= 12 {
                return .medium
            } else {
                return .low
            }
        }
    }

    nonisolated private static func recommendationDetail(from profile: PerformanceProfile, recommendedTier: PerformanceTier, engine: TranscriptionEngine) -> String {
        let mode = engine == .vibeVoiceMLX ? "MLX" : "CPU"
        return "检测结果：\(profile.summary)。当前建议采用\(recommendedTier.title)档（\(mode)）。"
    }

    nonisolated private static func profile(for tier: PerformanceTier, detected: PerformanceProfile, engine: TranscriptionEngine) -> PerformanceProfile {
        let baseThreads: Int
        let baseBatch: Int
        let mergeLength: Int

        switch tier {
        case .low:
            baseThreads = max(1, min(2, detected.threads - 1))
            baseBatch = 60
            mergeLength = 10
        case .medium:
            baseThreads = max(2, min(detected.threads, 4))
            baseBatch = engine == .vibeVoiceMLX ? 90 : 90
            mergeLength = 12
        case .high:
            baseThreads = max(detected.threads, engine == .vibeVoiceMLX ? 4 : 2)
            baseBatch = engine == .vibeVoiceMLX ? 120 : 120
            mergeLength = 15
        }

        let summary = "当前档位：\(tier.title)（\(detected.summary)）"
        return PerformanceProfile(
            device: detected.device,
            threads: baseThreads,
            batchSizeSeconds: baseBatch,
            mergeLengthSeconds: mergeLength,
            speakerDiarizationEnabled: true,
            mpsAvailable: detected.mpsAvailable,
            summary: summary
        )
    }

    nonisolated private static func pythonSupportsMPS(_ pythonPath: String) -> Bool {
        let code = """
        import sys
        try:
            import torch
            print('YES' if torch.backends.mps.is_available() else 'NO')
        except Exception:
            print('NO')
        """
        return runPython(pythonPath, code: code, cleanPythonEnvironment: true).contains("YES")
    }

    nonisolated private static func intFromShell(_ command: String, fallback: Int) -> Int {
        let value = runShell(command).trimmingCharacters(in: .whitespacesAndNewlines)
        return Int(value) ?? fallback
    }

    nonisolated private static func int64FromShell(_ command: String, fallback: Int64) -> Int64 {
        let value = runShell(command).trimmingCharacters(in: .whitespacesAndNewlines)
        return Int64(value) ?? fallback
    }

    func installFFmpeg() {
        if isBrewInstalled() {
            openTerminal(command: "brew install ffmpeg")
            installMessage = "已打开 Terminal 执行 ffmpeg 安装。"
        } else {
            NSWorkspace.shared.open(URL(string: "https://ffmpeg.org/download.html")!)
            installMessage = "未检测到 Homebrew，已打开 ffmpeg 下载页。"
        }
    }

    func installPythonDependencies() {
        let python = pythonPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !python.isEmpty, FileManager.default.isExecutableFile(atPath: python) else {
            installMessage = "请先选择有效的 Python 可执行文件。"
            return
        }

        let managedPython = Self.appManagedPythonPath()
        let managedVenv = (managedPython as NSString).deletingLastPathComponent
        let managedVenvRoot = (managedVenv as NSString).deletingLastPathComponent
        let command: String
        switch runtimeSelection.engine {
        case .funASR:
            command = """
            mkdir -p "\(managedVenvRoot)" && \
            "\(python)" -m venv "\(managedVenvRoot)" && \
            "\(managedPython)" -m pip install -U pip setuptools wheel && \
            "\(managedPython)" -m pip install -U funasr modelscope openai
            """
        case .vibeVoiceMLX:
            command = """
            mkdir -p "\(managedVenvRoot)" && \
            "\(python)" -m venv "\(managedVenvRoot)" && \
            "\(managedPython)" -m pip install -U pip setuptools wheel && \
            "\(managedPython)" -m pip install -U mlx-audio huggingface_hub openai
            """
        }
        openTerminal(command: command)
        installMessage = "已打开 Terminal，为 \(runtimeSelection.engine.title) 创建独立环境并安装依赖。"
    }

    func installModels() {
        let managedPython = Self.appManagedPythonPath()
        let fallbackPython = pythonPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let python = FileManager.default.isExecutableFile(atPath: managedPython) ? managedPython : fallbackPython
        guard !python.isEmpty, FileManager.default.isExecutableFile(atPath: python) else {
            installMessage = "请先安装依赖，应用会先创建自己的 Python 环境。"
            return
        }

        let command: String
        switch runtimeSelection.engine {
        case .funASR:
            let code = "from funasr import AutoModel; AutoModel(model='paraformer-zh', vad_model='fsmn-vad', punc_model='ct-punc', spk_model='cam++', device='cpu', disable_update=True)"
            command = "\"\(python)\" -c \"\(code)\""
        case .vibeVoiceMLX:
            let repo = runtimeSelection.modelID.replacingOccurrences(of: "\"", with: "")
            command = "\"\(python)\" -c \"from huggingface_hub import snapshot_download; snapshot_download(repo_id='\(repo)')\""
        }
        openTerminal(command: command)
        installMessage = "已打开 Terminal 下载 \(runtimeSelection.engine.title) 模型。"
    }

    private func isBrewInstalled() -> Bool {
        Self.runShell("command -v brew >/dev/null 2>&1; echo $?").trimmingCharacters(in: .whitespacesAndNewlines) == "0"
    }

    private func openTerminal(command: String) {
        let escapedCommand = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Terminal"
            activate
            do script "\(escapedCommand)"
        end tell
        """
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        try? task.run()
    }

    func refreshAfterExternalInstall() {
        check()
    }

    nonisolated private static func requiredDependencyNames(for engine: TranscriptionEngine) -> [String] {
        switch engine {
        case .funASR:
            return ["ffmpeg", "python3", "funasr", "models"]
        case .vibeVoiceMLX:
            return ["ffmpeg", "python3", "mlx-audio", "mlx-model"]
        }
    }
}
