import Foundation

enum LLMProviderType: String, Codable {
    case openAICompatible
    case openAIResponses
    case anthropicMessages
}

struct LLMModel: Codable, Identifiable {
    var id: String
    var name: String
    var apiBase: String
    var apiKey: String
    var providerType: LLMProviderType
}

@main
struct PersonOrganizationVersionCheck {
    static func main() async throws {
        try checkAppendReloadAndOrdering()
        try checkMissingResultPathDoesNotSave()
        try checkTemporaryOutputAloneIsNotAVersion()
        try checkVersionsBackupRecoveryRestoresPrimary()
        try checkVersionsCorruptionMakesRepositoryReadOnlyWithoutBootstrap()
        try await checkRunnerSuccessCreatesVersionAndCleansTemporaryFiles()
        try await checkRunnerFailureDoesNotCreateVersionOrResult()
        print("PersonOrganizationVersionCheck passed")
    }

    private static func checkAppendReloadAndOrdering() throws {
        try withTemporaryDirectory("append-reload-ordering") { root in
            let firstResult = root.appendingPathComponent("first.md")
            let secondResult = root.appendingPathComponent("second.md")
            let sameTimeResult = root.appendingPathComponent("same-time.md")
            try "first".write(to: firstResult, atomically: true, encoding: .utf8)
            try "second".write(to: secondResult, atomically: true, encoding: .utf8)
            try "same".write(to: sameTimeResult, atomically: true, encoding: .utf8)

            let repository = PersonArchiveRepository(archiveRoot: root)
            try repository.load(indexEntries: [])

            try repository.appendOrganizationVersion(
                makeVersion(
                    id: "version-b",
                    personID: "person-a",
                    createdAt: Date(timeIntervalSince1970: 20),
                    resultPath: secondResult.path
                )
            )
            try repository.appendOrganizationVersion(
                makeVersion(
                    id: "version-c",
                    personID: "person-a",
                    createdAt: Date(timeIntervalSince1970: 20),
                    resultPath: sameTimeResult.path
                )
            )
            try repository.appendOrganizationVersion(
                makeVersion(
                    id: "version-a",
                    personID: "person-a",
                    createdAt: Date(timeIntervalSince1970: 10),
                    resultPath: firstResult.path
                )
            )
            try repository.appendOrganizationVersion(
                makeVersion(
                    id: "other-person",
                    personID: "person-b",
                    createdAt: Date(timeIntervalSince1970: 30),
                    resultPath: secondResult.path
                )
            )

            assertEqual(
                repository.versions(for: "person-a").map(\.id),
                ["version-b", "version-c", "version-a"],
                "versions are sorted by createdAt descending, then id"
            )

            let reloaded = PersonArchiveRepository(archiveRoot: root)
            try reloaded.load(indexEntries: [])
            assertEqual(
                reloaded.versions(for: "person-a").map(\.id),
                ["version-b", "version-c", "version-a"],
                "versions reload from organization_versions.json"
            )
            assertEqual(
                reloaded.versions(for: "person-b").map(\.id),
                ["other-person"],
                "versions query filters by person ID"
            )
        }
    }

    private static func checkMissingResultPathDoesNotSave() throws {
        try withTemporaryDirectory("missing-result-path") { root in
            let repository = PersonArchiveRepository(archiveRoot: root)
            try repository.load(indexEntries: [])

            do {
                try repository.appendOrganizationVersion(
                    makeVersion(
                        id: "missing-result",
                        personID: "person-a",
                        createdAt: Date(timeIntervalSince1970: 10),
                        resultPath: root.appendingPathComponent("missing.md").path
                    )
                )
                fatalError("append should reject a missing result file")
            } catch let error as CocoaError {
                assertEqual(
                    error.code,
                    CocoaError.Code.fileNoSuchFile,
                    "missing result path throws fileNoSuchFile"
                )
            } catch {
                fatalError("append should throw CocoaError.fileNoSuchFile, got \(error)")
            }

            assertEqual(
                repository.versions(for: "person-a"),
                [],
                "missing result append does not mutate in-memory versions"
            )
            assertEqual(
                FileManager.default.fileExists(
                    atPath: root.appendingPathComponent("organization_versions.json").path
                ),
                false,
                "missing result append does not save organization_versions.json"
            )
        }
    }

    private static func checkTemporaryOutputAloneIsNotAVersion() throws {
        try withTemporaryDirectory("temporary-output-not-version") { root in
            let temporaryDirectory = root.appendingPathComponent(".tmp", isDirectory: true)
            try FileManager.default.createDirectory(
                at: temporaryDirectory,
                withIntermediateDirectories: true
            )
            try "draft output".write(
                to: temporaryDirectory.appendingPathComponent("person-organization-draft.md"),
                atomically: true,
                encoding: .utf8
            )

            let repository = PersonArchiveRepository(archiveRoot: root)
            try repository.load(indexEntries: [])
            assertEqual(
                repository.versions(for: "person-a"),
                [],
                "temporary output files are not treated as versions"
            )
        }
    }

    private static func checkVersionsBackupRecoveryRestoresPrimary() throws {
        try withTemporaryDirectory("backup-recovery") { root in
            let versionsURL = root.appendingPathComponent("organization_versions.json")
            let backupVersion = makeVersion(
                id: "backup-version",
                personID: "person-a",
                createdAt: Date(timeIntervalSince1970: 10),
                resultPath: root.appendingPathComponent("backup.md").path
            )
            try AtomicJSONFileStore.save(
                OrganizationVersionsFile(versions: [backupVersion]),
                to: versionsURL
            )
            try FileManager.default.moveItem(
                at: versionsURL,
                to: versionsURL.appendingPathExtension("backup")
            )
            try Data("{broken-primary".utf8).write(to: versionsURL)

            let repository = PersonArchiveRepository(archiveRoot: root)
            try repository.load(indexEntries: [])
            assertWritable(repository.access, "versions backup recovery access")
            assertEqual(
                repository.versions(for: "person-a").map(\.id),
                ["backup-version"],
                "versions backup recovery loads valid backup"
            )

            let restored = AtomicJSONFileStore.load(
                OrganizationVersionsFile.self,
                from: versionsURL,
                defaultValue: OrganizationVersionsFile()
            )
            assertEqual(
                restored.value.versions.map(\.id),
                ["backup-version"],
                "versions backup recovery restores primary file"
            )
            assertEqual(restored.access, .writable, "restored versions primary is readable")
        }
    }

    private static func checkVersionsCorruptionMakesRepositoryReadOnlyWithoutBootstrap() throws {
        try withTemporaryDirectory("versions-corruption-read-only") { root in
            let call = try makeAvailableCall(
                root: root,
                id: "call-a",
                name: "章文",
                phone: "15397111188",
                time: 100
            )
            let versionsURL = root.appendingPathComponent("organization_versions.json")
            try Data("{broken-primary".utf8).write(to: versionsURL)
            try Data("{broken-backup".utf8).write(
                to: versionsURL.appendingPathExtension("backup")
            )

            let repository = PersonArchiveRepository(archiveRoot: root)
            try repository.load(indexEntries: [call])
            switch repository.access {
            case .readOnly(let reason):
                assertEqual(reason.isEmpty, false, "versions corruption read-only reason")
            default:
                fatalError("versions corruption should make repository read-only")
            }

            assertEqual(repository.people, [], "read-only load does not bootstrap people")
            assertEqual(
                FileManager.default.fileExists(
                    atPath: root.appendingPathComponent("people.json").path
                ),
                false,
                "read-only load does not save bootstrapped people"
            )
            assertThrowsReadOnly("appendOrganizationVersion") {
                try repository.appendOrganizationVersion(
                    makeVersion(
                        id: "blocked",
                        personID: "person-a",
                        createdAt: Date(timeIntervalSince1970: 10),
                        resultPath: call.speakerTextPath
                    )
                )
            }
        }
    }

    private static func checkRunnerSuccessCreatesVersionAndCleansTemporaryFiles() async throws {
        try await withTemporaryDirectory("runner-success") { root in
            let captureURL = root.appendingPathComponent("capture.txt")
            let capturedInputURL = root.appendingPathComponent("captured-input.md")
            let scriptURL = root.appendingPathComponent("fake-summarize.sh")
            try makeSuccessScript(
                scriptURL: scriptURL,
                captureURL: captureURL,
                capturedInputURL: capturedInputURL
            )

            let preparation = makePreparation(markdown: "# Prepared\n\nsecret-free input\n")
            let secret = "sk-test-secret-runner"
            let request = PersonOrganizationRequest(
                personID: "person/a:?bad",
                preparation: preparation,
                model: LLMModel(
                    id: "gpt-test",
                    name: "Test Model",
                    apiBase: "https://example.test/v1",
                    apiKey: secret,
                    providerType: .openAICompatible
                ),
                templateID: "weekly/template:?bad",
                prompt: "整理成周报",
                archiveRoot: root,
                pythonPath: "/bin/sh",
                scriptPath: scriptURL.path
            )

            let runner = await MainActor.run { PersonOrganizationRunner() }
            let runResult = await run(request: request, with: runner)

            guard let version = runResult.version else {
                fatalError("runner success should return a version: \(runResult)")
            }
            assertEqual(runResult.cancelled, false, "runner success is not cancelled")
            assertEqual(runResult.errorMessage, nil, "runner success has no error")

            assertEqual(version.personID, request.personID, "version personID")
            assertEqual(version.personSnapshot, preparation.personSnapshot, "version person snapshot")
            assertEqual(version.callIDs, preparation.callIDs, "version call IDs")
            assertEqual(version.sourceSnapshots, preparation.sources, "version source snapshots")
            assertEqual(version.modelID, "gpt-test", "version model ID")
            assertEqual(version.templateID, "weekly/template:?bad", "version template ID")
            assertEqual(version.customPrompt, "整理成周报", "version custom prompt")
            assertEqual(
                FileManager.default.fileExists(atPath: version.resultPath),
                true,
                "final result file exists"
            )
            assertEqual(
                URL(fileURLWithPath: version.resultPath).path.contains("/.tmp/"),
                false,
                "version result path is final, not temporary"
            )
            assertEqual(
                try String(contentsOfFile: version.resultPath, encoding: .utf8)
                    .contains("secret-free input"),
                true,
                "fake script received preparation markdown and wrote final output"
            )
            assertEqual(
                try String(contentsOf: capturedInputURL, encoding: .utf8),
                preparation.markdown,
                "runner writes preparation markdown to script input"
            )

            let capture = try String(contentsOf: captureURL, encoding: .utf8)
            assertEqual(capture.contains("ENV_KEY=\(secret)"), true, "API key is in env")
            assertEqual(capture.contains("ARG=\(secret)"), false, "API key is not in argv")
            assertEqual(
                await MainActor.run { runner.progressText.contains(secret) },
                false,
                "progress text does not expose API key"
            )
            assertEqual(
                await MainActor.run { runner.errorMessage?.contains(secret) ?? false },
                false,
                "error message does not expose API key"
            )
            assertEqual(
                temporaryOrganizationFiles(in: root),
                [],
                "temporary input/output files are cleaned after success"
            )
        }
    }

    private static func checkRunnerFailureDoesNotCreateVersionOrResult() async throws {
        try await withTemporaryDirectory("runner-failure") { root in
            let scriptURL = root.appendingPathComponent("fake-failing-summarize.sh")
            try makeFailureScript(scriptURL: scriptURL)

            let request = PersonOrganizationRequest(
                personID: "person-a",
                preparation: makePreparation(markdown: "# Prepared\n"),
                model: LLMModel(
                    id: "gpt-test",
                    name: "Test Model",
                    apiBase: "https://example.test/v1",
                    apiKey: "sk-failure-secret",
                    providerType: .openAICompatible
                ),
                templateID: "failure-template",
                prompt: "prompt",
                archiveRoot: root,
                pythonPath: "/bin/sh",
                scriptPath: scriptURL.path
            )

            let runner = await MainActor.run { PersonOrganizationRunner() }
            let runResult = await run(request: request, with: runner)
            assertEqual(runResult.version, nil, "runner failure does not return version")
            assertEqual(runResult.cancelled, false, "runner failure is not cancel")
            assertEqual(runResult.errorMessage?.isEmpty, false, "runner failure returns error")
            assertEqual(
                await MainActor.run { runner.errorMessage?.contains("sk-failure-secret") ?? false },
                false,
                "failure error message does not expose API key"
            )
            assertEqual(
                temporaryOrganizationFiles(in: root),
                [],
                "temporary files are cleaned after failure"
            )
            assertEqual(finalMarkdownFiles(in: root), [], "runner failure creates no final result")

            let repository = PersonArchiveRepository(archiveRoot: root)
            try repository.load(indexEntries: [])
            assertEqual(
                repository.versions(for: "person-a"),
                [],
                "runner failure does not append repository versions"
            )
        }
    }

    @MainActor
    private static func run(
        request: PersonOrganizationRequest,
        with runner: PersonOrganizationRunner
    ) async -> PersonOrganizationRunResult {
        await withCheckedContinuation { continuation in
            runner.start(request: request) { result in
                continuation.resume(returning: result)
            }
        }
    }

    private static func makeVersion(
        id: String,
        personID: String,
        createdAt: Date,
        resultPath: String
    ) -> PersonOrganizationVersion {
        PersonOrganizationVersion(
            id: id,
            personID: personID,
            personSnapshot: PersonSnapshot(
                displayName: "章文",
                phoneNumbers: ["15397111188"]
            ),
            callIDs: ["call-a"],
            sourceSnapshots: [
                PersonOrganizationSourceSnapshot(
                    callID: "call-a",
                    sourceKind: .proofread,
                    sourcePath: "/tmp/call-a.md",
                    contentHash: "sha256:abc"
                )
            ],
            modelID: "gpt-test",
            templateID: "template-a",
            customPrompt: "prompt",
            createdAt: createdAt,
            resultPath: resultPath
        )
    }

    private static func makePreparation(markdown: String) -> PersonOrganizationPreparation {
        PersonOrganizationPreparation(
            personSnapshot: PersonSnapshot(
                displayName: "章文",
                phoneNumbers: ["15397111188"]
            ),
            callIDs: ["call-a", "call-b"],
            sources: [
                PersonOrganizationSourceSnapshot(
                    callID: "call-a",
                    sourceKind: .proofread,
                    sourcePath: "/tmp/call-a.md",
                    contentHash: "sha256:aaa"
                ),
                PersonOrganizationSourceSnapshot(
                    callID: "call-b",
                    sourceKind: .transcript,
                    sourcePath: "/tmp/call-b.md",
                    contentHash: "sha256:bbb"
                )
            ],
            unavailableCallIDs: ["call-c"],
            markdown: markdown
        )
    }

    private static func makeAvailableCall(
        root: URL,
        id: String,
        name: String,
        phone: String,
        time: TimeInterval
    ) throws -> CallRecordIndexEntry {
        let outputDir = root
            .appendingPathComponent("Calls", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(
            at: outputDir,
            withIntermediateDirectories: true
        )
        let transcriptURL = outputDir.appendingPathComponent("\(id)_通话记录.md")
        let speakerURL = outputDir.appendingPathComponent("\(id)_整理版.md")
        try "transcript".write(to: transcriptURL, atomically: true, encoding: .utf8)
        try "speaker".write(to: speakerURL, atomically: true, encoding: .utf8)
        return CallRecordIndexEntry(
            id: id,
            displayName: name,
            contactName: name,
            rawPhone: phone,
            normalizedPhone: phone.filter(\.isNumber),
            callDate: Date(timeIntervalSince1970: time),
            callDateText: "time\(Int(time))",
            durationSeconds: nil,
            outputDirectoryPath: outputDir.path,
            transcriptPath: transcriptURL.path,
            speakerTextPath: speakerURL.path,
            summaryPath: "",
            engine: "test-engine",
            modelID: "test-model"
        )
    }

    private static func makeSuccessScript(
        scriptURL: URL,
        captureURL: URL,
        capturedInputURL: URL
    ) throws {
        let script = """
        set -eu
        input="$1"
        shift
        model="$1"
        shift
        output=""
        title=""
        {
          printf 'MODEL=%s\\n' "$model"
          printf 'ENV_KEY=%s\\n' "${OPENAI_API_KEY:-}"
          while [ "$#" -gt 0 ]; do
            printf 'ARG=%s\\n' "$1"
            if [ "$1" = "--output-path" ]; then
              shift
              output="$1"
              printf 'ARG=%s\\n' "$1"
            elif [ "$1" = "--document-title" ]; then
              shift
              title="$1"
              printf 'ARG=%s\\n' "$1"
            elif [ "$1" = "--summary-prompt" ]; then
              shift
              printf 'ARG=%s\\n' "$1"
            elif [ "$1" = "--api-base" ]; then
              shift
              printf 'ARG=%s\\n' "$1"
            elif [ "$1" = "--provider-type" ]; then
              shift
              printf 'ARG=%s\\n' "$1"
            fi
            shift
          done
        } > \(shellQuote(captureURL.path))
        cp "$input" \(shellQuote(capturedInputURL.path))
        mkdir -p "$(dirname "$output")"
        {
          printf '# %s\\n\\n' "$title"
          cat "$input"
        } > "$output"
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )
    }

    private static func makeFailureScript(scriptURL: URL) throws {
        let script = """
        set -eu
        exit 7
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )
    }

    private static func temporaryOrganizationFiles(in root: URL) -> [String] {
        let temporaryDirectory = root.appendingPathComponent(".tmp", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(
            atPath: temporaryDirectory.path
        ) else {
            return []
        }
        return names
            .filter { $0.hasPrefix("person-organization-") }
            .sorted()
    }

    private static func finalMarkdownFiles(in root: URL) -> [String] {
        let finalRoot = root.appendingPathComponent("人物整理", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: finalRoot,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        return enumerator.compactMap { item in
            guard let url = item as? URL, url.pathExtension == "md" else { return nil }
            return url.path
        }.sorted()
    }

    private static func withTemporaryDirectory(
        _ label: String,
        body: (URL) throws -> Void
    ) throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(
                "PersonOrganizationVersionCheck-\(label)-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private static func withTemporaryDirectory(
        _ label: String,
        body: (URL) async throws -> Void
    ) async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(
                "PersonOrganizationVersionCheck-\(label)-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(root)
    }

    private static func assertThrowsReadOnly(
        _ message: String,
        operation: () throws -> Void
    ) {
        do {
            try operation()
            fatalError("\(message) should throw readOnly")
        } catch PersonArchiveError.readOnly(let reason) {
            assertEqual(reason.isEmpty, false, "\(message) read-only reason")
        } catch {
            fatalError("\(message) expected readOnly, got \(error)")
        }
    }

    private static func assertWritable(
        _ access: PersonArchiveAccess,
        _ message: String
    ) {
        if access != .writable {
            fatalError("\(message): expected writable, got \(access)")
        }
    }

    private static func assertEqual<T: Equatable>(
        _ lhs: T,
        _ rhs: T,
        _ message: String
    ) {
        if lhs != rhs {
            fatalError("\(message): expected \(rhs), got \(lhs)")
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
