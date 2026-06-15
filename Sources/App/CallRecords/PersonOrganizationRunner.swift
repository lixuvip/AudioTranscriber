import Combine
import Foundation

struct PersonOrganizationRequest {
    let personID: String
    let preparation: PersonOrganizationPreparation
    let model: LLMModel
    let templateID: String
    let prompt: String
    let archiveRoot: URL
    let pythonPath: String
    let scriptPath: String
}

struct PersonOrganizationRunResult {
    let version: PersonOrganizationVersion?
    let cancelled: Bool
    let errorMessage: String?
}

@MainActor
final class PersonOrganizationRunner: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var progressText = ""
    @Published private(set) var errorMessage: String?

    private var process: Process?
    private var didCancel = false
    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    func start(
        request: PersonOrganizationRequest,
        completion: @escaping (PersonOrganizationRunResult) -> Void
    ) {
        guard !isRunning else {
            completion(
                PersonOrganizationRunResult(
                    version: nil,
                    cancelled: false,
                    errorMessage: "人物整理任务正在运行"
                )
            )
            return
        }

        isRunning = true
        didCancel = false
        errorMessage = nil
        progressText = "正在准备人物整理输入"

        let fileManager = FileManager.default
        let runID = UUID().uuidString
        let shortRunID = String(runID.prefix(8))
        let temporaryDirectory = request.archiveRoot
            .appendingPathComponent(".tmp", isDirectory: true)
        let inputURL = temporaryDirectory
            .appendingPathComponent("person-organization-\(runID).md")
        let temporaryOutputURL = temporaryDirectory
            .appendingPathComponent("person-organization-\(runID)-output.md")
        let createdAt = now()
        let templateTitle = displayTitle(for: request.templateID)
        let organizationRoot = request.archiveRoot
            .appendingPathComponent("人物整理", isDirectory: true)
        let finalDirectory = organizationRoot
            .appendingPathComponent(
                Self.sanitizePathComponent(request.personID, fallback: "person"),
                isDirectory: true
            )
        let finalURL = finalDirectory.appendingPathComponent(
            "\(Self.timestampFormatter.string(from: createdAt))_\(Self.sanitizePathComponent(templateTitle, fallback: "template"))_\(shortRunID).md"
        )

        do {
            try fileManager.createDirectory(
                at: temporaryDirectory,
                withIntermediateDirectories: true
            )
            try request.preparation.markdown.write(
                to: inputURL,
                atomically: true,
                encoding: .utf8
            )
        } catch {
            cleanupTemporaryFiles(inputURL: inputURL, outputURL: temporaryOutputURL)
            finish(
                version: nil,
                cancelled: false,
                message: "人物整理输入准备失败：\(error.localizedDescription)",
                completion: completion
            )
            return
        }

        let launchedProcess = Process()
        launchedProcess.executableURL = URL(fileURLWithPath: request.pythonPath)
        launchedProcess.arguments = [
            request.scriptPath,
            inputURL.path,
            request.model.id,
            "--api-base", request.model.apiBase,
            "--provider-type", request.model.providerType.rawValue,
            "--summary-prompt", request.prompt,
            "--output-path", temporaryOutputURL.path,
            "--document-title", templateTitle
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["OPENAI_API_KEY"] = request.model.apiKey
        launchedProcess.environment = environment
        launchedProcess.terminationHandler = { [weak self] process in
            Task { @MainActor in
                self?.handleTermination(
                    process,
                    request: request,
                    createdAt: createdAt,
                    inputURL: inputURL,
                    temporaryOutputURL: temporaryOutputURL,
                    finalDirectory: finalDirectory,
                    finalURL: finalURL,
                    completion: completion
                )
            }
        }

        process = launchedProcess
        progressText = "正在调用摘要脚本"

        do {
            try launchedProcess.run()
        } catch {
            process = nil
            cleanupTemporaryFiles(inputURL: inputURL, outputURL: temporaryOutputURL)
            finish(
                version: nil,
                cancelled: false,
                message: "人物整理脚本启动失败：\(error.localizedDescription)",
                completion: completion
            )
        }
    }

    func cancel() {
        guard isRunning else { return }
        guard let process, process.isRunning else { return }
        didCancel = true
        progressText = "正在取消人物整理"
        process.terminate()
    }

    private func handleTermination(
        _ terminatedProcess: Process,
        request: PersonOrganizationRequest,
        createdAt: Date,
        inputURL: URL,
        temporaryOutputURL: URL,
        finalDirectory: URL,
        finalURL: URL,
        completion: @escaping (PersonOrganizationRunResult) -> Void
    ) {
        guard process === terminatedProcess else { return }
        process = nil

        if didCancel {
            cleanupTemporaryFiles(inputURL: inputURL, outputURL: temporaryOutputURL)
            finish(version: nil, cancelled: true, message: nil, completion: completion)
            return
        }

        guard terminatedProcess.terminationStatus == 0 else {
            cleanupTemporaryFiles(inputURL: inputURL, outputURL: temporaryOutputURL)
            finish(
                version: nil,
                cancelled: false,
                message: "人物整理失败（退出码 \(terminatedProcess.terminationStatus)）",
                completion: completion
            )
            return
        }

        guard FileManager.default.fileExists(atPath: temporaryOutputURL.path) else {
            cleanupTemporaryFiles(inputURL: inputURL, outputURL: temporaryOutputURL)
            finish(
                version: nil,
                cancelled: false,
                message: "人物整理失败：未生成输出文件",
                completion: completion
            )
            return
        }

        do {
            try FileManager.default.createDirectory(
                at: finalDirectory,
                withIntermediateDirectories: true
            )
            let resultURL = try moveTemporaryOutput(from: temporaryOutputURL, to: finalURL)
            cleanupTemporaryFiles(inputURL: inputURL, outputURL: temporaryOutputURL)
            let version = PersonOrganizationVersion(
                personID: request.personID,
                personSnapshot: request.preparation.personSnapshot,
                callIDs: request.preparation.callIDs,
                sourceSnapshots: request.preparation.sources,
                modelID: request.model.id,
                templateID: request.templateID,
                customPrompt: request.prompt,
                createdAt: createdAt,
                resultPath: resultURL.path
            )
            finish(version: version, cancelled: false, message: nil, completion: completion)
        } catch {
            cleanupTemporaryFiles(inputURL: inputURL, outputURL: temporaryOutputURL)
            finish(
                version: nil,
                cancelled: false,
                message: "人物整理结果保存失败：\(error.localizedDescription)",
                completion: completion
            )
        }
    }

    private func finish(
        version: PersonOrganizationVersion?,
        cancelled: Bool,
        message: String?,
        completion: @escaping (PersonOrganizationRunResult) -> Void
    ) {
        isRunning = false
        didCancel = false
        errorMessage = message
        if cancelled {
            progressText = "已取消"
        } else if version != nil {
            progressText = "整理完成"
        } else if message != nil {
            progressText = "整理失败"
        } else {
            progressText = ""
        }
        completion(
            PersonOrganizationRunResult(
                version: version,
                cancelled: cancelled,
                errorMessage: message
            )
        )
    }

    private func cleanupTemporaryFiles(inputURL: URL, outputURL: URL) {
        try? FileManager.default.removeItem(at: inputURL)
        try? FileManager.default.removeItem(at: outputURL)
    }

    private func moveTemporaryOutput(
        from temporaryOutputURL: URL,
        to preferredFinalURL: URL
    ) throws -> URL {
        var candidateURL = preferredFinalURL
        for attempt in 0..<10 {
            if attempt > 0 {
                candidateURL = Self.collisionAvoidingURL(for: preferredFinalURL)
            }
            if FileManager.default.fileExists(atPath: candidateURL.path) {
                continue
            }
            do {
                try FileManager.default.moveItem(at: temporaryOutputURL, to: candidateURL)
                return candidateURL
            } catch {
                if FileManager.default.fileExists(atPath: candidateURL.path) {
                    continue
                }
                throw error
            }
        }
        throw CocoaError(
            .fileWriteFileExists,
            userInfo: [NSFilePathErrorKey: preferredFinalURL.path]
        )
    }

    private func displayTitle(for templateID: String) -> String {
        let trimmed = templateID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "人物整理" : trimmed
    }

    private static func sanitizePathComponent(
        _ value: String,
        fallback: String
    ) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
            .union(.newlines)
            .union(.controlCharacters)
        let sanitized = value
            .components(separatedBy: invalid)
            .joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty,
              sanitized != ".",
              sanitized != ".." else {
            return fallback
        }
        return sanitized
    }

    private static func collisionAvoidingURL(for preferredURL: URL) -> URL {
        let directory = preferredURL.deletingLastPathComponent()
        let baseName = preferredURL.deletingPathExtension().lastPathComponent
        let pathExtension = preferredURL.pathExtension
        let suffix = String(UUID().uuidString.prefix(8))
        let fileName = pathExtension.isEmpty
            ? "\(baseName)_\(suffix)"
            : "\(baseName)_\(suffix).\(pathExtension)"
        return directory.appendingPathComponent(fileName)
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}
