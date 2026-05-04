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

@MainActor
class EnvironmentChecker: ObservableObject {
    @Published var deps: [DependencyStatus] = []
    @Published var pythonPath: String = ""
    @Published var pythonSitePackages: String = ""
    @Published var isInstallingDependency = false
    @Published var installMessage: String = ""
    var customPythonPath: String = ""

    var allReady: Bool {
        deps.filter { ["ffmpeg", "python3", "funasr"].contains($0.name) }.allSatisfy { $0.isReady }
    }

    func check() {
        pythonSitePackages = ""
        pythonPath = detectPython()
        checkFFmpeg()
        checkPython()
        checkFunASR()
        checkModels()
    }

    /// 自动探测 FunASR 对应的 Python：扫描所有 python3，逐个测试 import funasr
    private func detectPython() -> String {
        var candidates: [String] = []

        // 用户手动指定的 Python 永远优先。
        if !customPythonPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            candidates.append(customPythonPath)
        }

        appendUniquePythonCandidates(from: discoverPythonCandidates(), to: &candidates)

        for p in candidates {
            guard pythonCanImportFunASR(p) else { continue }
            pythonSitePackages = sitePackagesPath(for: p)
            return p
        }

        return candidates.first ?? "python3"
    }

    private func discoverPythonCandidates() -> [String] {
        let knownPaths = [
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

    private func appendUniquePythonCandidates(from paths: [String], to candidates: inout [String]) {
        for path in paths {
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !candidates.contains(trimmed) else { continue }
            guard FileManager.default.isExecutableFile(atPath: trimmed) else { continue }
            candidates.append(trimmed)
        }
    }

    private func pythonCanImportFunASR(_ python: String) -> Bool {
        runPython(
            python,
            code: "import funasr; print('FUNOK')",
            cleanPythonEnvironment: true
        ).contains("FUNOK")
    }

    private func sitePackagesPath(for python: String) -> String {
        let code = "import site; paths = site.getsitepackages(); print(paths[0] if paths else '')"
        return runPython(python, code: code, cleanPythonEnvironment: true)
            .components(separatedBy: "\n")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func runPython(_ python: String, code: String, cleanPythonEnvironment: Bool = false) -> String {
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

    private func runShell(_ command: String) -> String {
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

    private func checkFFmpeg() {
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

            deps.removeAll { $0.name == "ffmpeg" }
            deps.append(DependencyStatus(
                name: "ffmpeg", icon: "play.rectangle.fill",
                isReady: task.terminationStatus == 0,
                message: task.terminationStatus == 0 ? "✓ \(ver)" : "✗ 未找到"
            ))
        } catch {
            deps.removeAll { $0.name == "ffmpeg" }
            deps.append(DependencyStatus(
                name: "ffmpeg", icon: "play.rectangle.fill",
                isReady: false, message: "✗ 未找到"
            ))
        }
    }

    private func checkPython() {
        let python = pythonPath
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
            deps.removeAll { $0.name == "python3" }
            deps.append(DependencyStatus(
                name: "python3", icon: "chevron.left.forwardslash.chevron.right",
                isReady: task.terminationStatus == 0,
                message: task.terminationStatus == 0 ? "✓ \(version)\n\(python)" : "✗ 未找到"
            ))
        } catch {
            deps.removeAll { $0.name == "python3" }
            deps.append(DependencyStatus(
                name: "python3", icon: "chevron.left.forwardslash.chevron.right",
                isReady: false, message: "✗ 未找到"
            ))
        }
    }

    private func checkFunASR() {
        let python = pythonPath
        let output = runPython(python, code: "import funasr; print('OK')", cleanPythonEnvironment: true)
        deps.removeAll { $0.name == "funasr" }
        deps.append(DependencyStatus(
            name: "funasr", icon: "waveform",
            isReady: output.contains("OK"),
            message: output.contains("OK") ? "✓ FunASR 已安装" : "✗ 此 Python 未安装 FunASR"
        ))
    }

    private func checkModels() {
        let models = ["paraformer-zh", "fsmn-vad", "ct-punc", "cam++"]

        // 用 python 查 modelscope 模型缓存路径
        let python = pythonPath
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

        deps.removeAll { $0.name == "models" }
        if missing.isEmpty {
            deps.append(DependencyStatus(
                name: "models", icon: "folder.fill",
                isReady: true, message: "✓ 全部模型已下载"
            ))
        } else {
            deps.append(DependencyStatus(
                name: "models", icon: "folder.fill",
                isReady: false,
                message: "⚠️ 缺少: \(missing.joined(separator: ", "))",
                action: nil
            ))
        }
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

        let command = "\"\(python)\" -m pip install -U funasr modelscope openai"
        openTerminal(command: command)
        installMessage = "已打开 Terminal 安装 Python 依赖。"
    }

    func installModels() {
        let python = pythonPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !python.isEmpty, FileManager.default.isExecutableFile(atPath: python) else {
            installMessage = "请先选择有效的 Python 可执行文件。"
            return
        }

        let code = "from funasr import AutoModel; AutoModel(model='paraformer-zh', vad_model='fsmn-vad', punc_model='ct-punc', spk_model='cam++', device='cpu', disable_update=True)"
        openTerminal(command: "\"\(python)\" -c \"\(code)\"")
        installMessage = "已打开 Terminal 下载 FunASR 模型。"
    }

    private func isBrewInstalled() -> Bool {
        runShell("command -v brew >/dev/null 2>&1; echo $?").trimmingCharacters(in: .whitespacesAndNewlines) == "0"
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
}
