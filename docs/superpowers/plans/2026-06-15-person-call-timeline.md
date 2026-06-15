# Person Call Timeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a three-column person workspace that groups archived calls by phone number, supports reversible manual contact merges, preserves per-person call selections, and creates versioned AI organization results from only the selected calls.

**Architecture:** Keep `call_index.json` as the immutable call fact source and add focused JSON repositories for people, drafts, and organization versions under the selected archive root. A `PersonTimelineStore` composes those repositories for SwiftUI, while `PersonOrganizationRunner` freezes selected source files, invokes the existing summarization script with a version-specific output path, and commits metadata only after the result file exists. The batch queue and `HistoryManager` remain separate.

**Tech Stack:** Swift 5.9, SwiftUI, Combine, Foundation, CryptoKit, Python 3, `unittest`, XcodeGen, Xcode 15/macOS 13.

---

## Scope Guards

- The UI is the approved three-column person workspace.
- A newly opened person has no selected calls unless a saved draft exists.
- Contact merging remains manual and reversible; same-name matches are suggestions only.
- Do not modify AllServes request/response contracts, relay fields, or HF token handling.
- Do not download transcription, diarization, pyannote, or LLM models.
- Do not move, rename, overwrite, or delete original recordings and existing transcript files.

## File Map

### New domain and storage files

- Create `Sources/App/CallRecords/PersonArchiveModels.swift`: Codable people, merge history, selection draft, organization version, timeline call, and input snapshot types.
- Create `Sources/App/CallRecords/AtomicJSONFileStore.swift`: typed JSON load/save with ISO-8601 dates, backup recovery, atomic replacement, and read-only failure reporting.
- Create `Sources/App/CallRecords/PersonArchiveRepository.swift`: load `call_index.json`, bootstrap phone-based people, merge/split/revert contacts, and persist drafts/versions.
- Create `Sources/App/CallRecords/PersonOrganizationInputBuilder.swift`: select proofread or raw transcript sources, calculate SHA-256 hashes, and build frozen combined Markdown.
- Create `Sources/App/CallRecords/PersonOrganizationRunner.swift`: run `summarize.py` without logging secrets and finalize version files atomically.
- Create `Sources/App/CallRecords/PersonTimelineStore.swift`: observable UI state, archive loading, search, selection shortcuts, merge actions, and organization lifecycle.

### New UI files

- Create `Sources/App/CallRecords/PersonTimelineView.swift`: top-level three-column workspace and archive-root empty/error states.
- Create `Sources/App/CallRecords/PersonListPane.swift`: searchable people and unassigned-number list.
- Create `Sources/App/CallRecords/PersonCallsPane.swift`: call timeline, whole-call checkboxes, and selection shortcuts.
- Create `Sources/App/CallRecords/PersonOrganizationPane.swift`: model/template controls, run state, result preview, and version list.
- Create `Sources/App/CallRecords/PersonMergeSheet.swift`: merge confirmation, target name, affected calls, split, and revert controls.

### Existing files to modify

- Modify `Sources/App/CallRecords/CallRecordArchiveWriter.swift`: expose index loading and archive-root derivation helpers without changing the existing index contract.
- Modify `Scripts/summarize.py`: accept explicit output path/title, stop silently truncating combined input, and write results atomically.
- Modify `Sources/App/ContentView.swift`: own the person store/runner, add the person tab, and connect archive-root selection.
- Modify `Sources/App/Components/SidebarView.swift`: add the “人物归档” navigation item.
- Modify `README.md`: document the user workflow and local files.
- Modify `SPEC.md`: document person identity, selection, and version contracts.
- Regenerate `VoiceScribe.xcodeproj/project.pbxproj` after all new Swift files exist.

### New tests

- Create `Tests/PersonArchiveRepositoryCheck.swift`: people bootstrap, same-name isolation, merge conflict, split, and revert.
- Create `Tests/PersonSelectionDraftCheck.swift`: draft persistence, pruning, and shortcuts.
- Create `Tests/PersonOrganizationInputCheck.swift`: proofread priority, raw fallback, unavailable calls, hashes, and frozen input.
- Create `Tests/PersonOrganizationVersionCheck.swift`: successful version append, failure preservation, and historical snapshots.
- Create `Tests/test_summarize_output.py`: explicit output path, no silent truncation, atomic write, and secret-redaction behavior.

## Task 1: Define Person Archive Models and Atomic JSON Storage

**Files:**
- Create: `Sources/App/CallRecords/PersonArchiveModels.swift`
- Create: `Sources/App/CallRecords/AtomicJSONFileStore.swift`
- Create: `Tests/PersonArchiveRepositoryCheck.swift`

- [ ] **Step 1: Write the failing model and storage check**

Create `Tests/PersonArchiveRepositoryCheck.swift` with:

```swift
import Foundation

@main
struct PersonArchiveRepositoryCheck {
    static func main() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PersonArchiveRepositoryCheck-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let person = PersonRecord(
            id: "person-1",
            displayName: "章文",
            phoneNumbers: ["15397111188"],
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2)
        )
        let file = PeopleFile(schemaVersion: 1, people: [person], mergeHistory: [])
        let url = root.appendingPathComponent("people.json")

        try AtomicJSONFileStore.save(file, to: url)
        let loaded: JSONLoadResult<PeopleFile> = AtomicJSONFileStore.load(
            PeopleFile.self,
            from: url,
            defaultValue: PeopleFile()
        )

        assertEqual(loaded.value, file, "people round trip")
        assertEqual(loaded.access, .writable, "new file remains writable")
    }

    private static func assertEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ message: String) {
        if lhs != rhs {
            fatalError("\(message): expected \(rhs), got \(lhs)")
        }
    }
}
```

- [ ] **Step 2: Run the check and verify RED**

Run:

```bash
swiftc \
  Sources/App/CallRecords/PersonArchiveModels.swift \
  Sources/App/CallRecords/AtomicJSONFileStore.swift \
  Tests/PersonArchiveRepositoryCheck.swift \
  -o /tmp/person-archive-repository-check
```

Expected: compilation fails because the two source files and their types do not exist.

- [ ] **Step 3: Add the complete Codable model surface**

Create `PersonArchiveModels.swift`:

```swift
import Foundation

struct PeopleFile: Codable, Equatable {
    var schemaVersion: Int = 1
    var people: [PersonRecord] = []
    var mergeHistory: [PersonMergeRecord] = []
    var unassignedPhoneNumbers: [String] = []
}

struct PersonRecord: Codable, Equatable, Identifiable {
    let id: String
    var displayName: String
    var phoneNumbers: [String]
    let createdAt: Date
    var updatedAt: Date
}

struct PersonMergeRecord: Codable, Equatable, Identifiable {
    let id: String
    let targetPersonID: String
    let beforePeople: [PersonRecord]
    let createdAt: Date
    var revertedAt: Date?
}

struct SelectionDraftsFile: Codable, Equatable {
    var schemaVersion: Int = 1
    var drafts: [String: PersonSelectionDraft] = [:]
}

struct PersonSelectionDraft: Codable, Equatable {
    var callIDs: [String]
    var updatedAt: Date
}

enum PersonOrganizationSourceKind: String, Codable, Equatable {
    case proofread
    case transcript
}

struct PersonOrganizationSourceSnapshot: Codable, Equatable {
    let callID: String
    let sourceKind: PersonOrganizationSourceKind
    let sourcePath: String
    let contentHash: String
}

struct PersonSnapshot: Codable, Equatable {
    let displayName: String
    let phoneNumbers: [String]
}

struct PersonOrganizationVersion: Codable, Equatable, Identifiable {
    let id: String
    let personID: String
    let personSnapshot: PersonSnapshot
    let callIDs: [String]
    let sourceSnapshots: [PersonOrganizationSourceSnapshot]
    let modelID: String
    let templateID: String
    let customPrompt: String
    let createdAt: Date
    let resultPath: String
}

struct OrganizationVersionsFile: Codable, Equatable {
    var schemaVersion: Int = 1
    var versions: [PersonOrganizationVersion] = []
}

enum PersonArchiveAccess: Equatable {
    case writable
    case recoveredFromBackup
    case readOnly(reason: String)
}

struct JSONLoadResult<Value> {
    let value: Value
    let access: PersonArchiveAccess
}
```

Use `.convertToSnakeCase` and `.convertFromSnakeCase` in storage so generated JSON matches the approved schema.

- [ ] **Step 4: Implement atomic JSON save, backup, and recovery**

Create `AtomicJSONFileStore.swift`:

```swift
import Foundation

enum AtomicJSONFileStore {
    static func load<T: Decodable>(
        _ type: T.Type,
        from url: URL,
        defaultValue: @autoclosure () -> T
    ) -> JSONLoadResult<T> {
        let backupURL = url.appendingPathExtension("backup")
        if !FileManager.default.fileExists(atPath: url.path) {
            return JSONLoadResult(value: defaultValue(), access: .writable)
        }
        do {
            return JSONLoadResult(value: try decode(type, from: url), access: .writable)
        } catch {
            do {
                return JSONLoadResult(
                    value: try decode(type, from: backupURL),
                    access: .recoveredFromBackup
                )
            } catch {
                return JSONLoadResult(
                    value: defaultValue(),
                    access: .readOnly(reason: "无法读取 \(url.lastPathComponent)，主文件和备份均已损坏")
                )
            }
        }
    }

    static func save<T: Codable>(_ value: T, to url: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(value)
        _ = try decoder.decode(T.self, from: data)
        let backupURL = url.appendingPathExtension("backup")
        if manager.fileExists(atPath: url.path) {
            try? manager.removeItem(at: backupURL)
            try manager.copyItem(at: url, to: backupURL)
        }
        let temporaryURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temporaryURL, options: .atomic)
        if manager.fileExists(atPath: url.path) {
            _ = try manager.replaceItemAt(url, withItemAt: temporaryURL)
        } else {
            try manager.moveItem(at: temporaryURL, to: url)
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try decoder.decode(type, from: Data(contentsOf: url))
    }

    private static var encoder: JSONEncoder {
        let value = JSONEncoder()
        value.outputFormatting = [.prettyPrinted, .sortedKeys]
        value.dateEncodingStrategy = .iso8601
        value.keyEncodingStrategy = .convertToSnakeCase
        return value
    }

    private static var decoder: JSONDecoder {
        let value = JSONDecoder()
        value.dateDecodingStrategy = .iso8601
        value.keyDecodingStrategy = .convertFromSnakeCase
        return value
    }
}
```

- [ ] **Step 5: Extend the check with backup recovery**

Append:

```swift
try AtomicJSONFileStore.save(file, to: url)
try Data("invalid".utf8).write(to: url)
let recovered: JSONLoadResult<PeopleFile> = AtomicJSONFileStore.load(
    PeopleFile.self,
    from: url,
    defaultValue: PeopleFile()
)
assertEqual(recovered.value, file, "backup recovery")
assertEqual(recovered.access, .recoveredFromBackup, "backup recovery status")

try Data("invalid-backup".utf8).write(to: url.appendingPathExtension("backup"))
let readOnly: JSONLoadResult<PeopleFile> = AtomicJSONFileStore.load(
    PeopleFile.self,
    from: url,
    defaultValue: PeopleFile()
)
guard case .readOnly = readOnly.access else {
    fatalError("corrupt main and backup must enter read-only mode")
}
```

- [ ] **Step 6: Run the check and verify GREEN**

```bash
swiftc \
  Sources/App/CallRecords/PersonArchiveModels.swift \
  Sources/App/CallRecords/AtomicJSONFileStore.swift \
  Tests/PersonArchiveRepositoryCheck.swift \
  -o /tmp/person-archive-repository-check &&
/tmp/person-archive-repository-check
```

Expected: exit code 0.

- [ ] **Step 7: Commit the storage foundation**

```bash
git add \
  Sources/App/CallRecords/PersonArchiveModels.swift \
  Sources/App/CallRecords/AtomicJSONFileStore.swift \
  Tests/PersonArchiveRepositoryCheck.swift
git commit -m "feat: add person archive storage foundation"
```

## Task 2: Load Calls and Maintain Reversible People Mappings

**Files:**
- Create: `Sources/App/CallRecords/PersonArchiveRepository.swift`
- Modify: `Sources/App/CallRecords/CallRecordArchiveWriter.swift`
- Modify: `Sources/App/CallRecords/PersonArchiveModels.swift`
- Modify: `Tests/PersonArchiveRepositoryCheck.swift`

- [ ] **Step 1: Add failing people bootstrap and merge tests**

Add:

```swift
let calls = [
    makeCall(id: "call-a", name: "章文", phone: "15397111188", time: 100),
    makeCall(id: "call-b", name: "章文", phone: "13102133750", time: 200),
    makeCall(id: "call-c", name: "章文", phone: "15397111188", time: 300),
]
let repository = PersonArchiveRepository(
    archiveRoot: root,
    now: { Date(timeIntervalSince1970: 500) }
)
try repository.load(indexEntries: calls)

assertEqual(repository.people.count, 2, "same name does not auto merge")
let first = try require(repository.person(containing: "15397111188"), "first phone person")
assertEqual(repository.calls(for: first.id).map(\.id), ["call-c", "call-a"], "timeline descending")

let second = try require(repository.person(containing: "13102133750"), "second phone person")
let merged = try repository.mergePeople(
    personIDs: [first.id, second.id],
    targetPersonID: first.id,
    displayName: "章文"
)
assertEqual(merged.phoneNumbers.sorted(), ["13102133750", "15397111188"], "merged phones")
assertEqual(repository.people.count, 1, "merged people count")

try repository.revertMerge(repository.peopleFile.mergeHistory.last!.id)
assertEqual(repository.people.count, 2, "revert restores both people")

let detached = try repository.splitPhones(
    from: first.id,
    phones: ["15397111188"],
    newDisplayName: nil
)
assertEqual(detached, nil, "split can leave phone unassigned")
assertEqual(
    repository.peopleFile.unassignedPhoneNumbers,
    ["15397111188"],
    "unassigned phone persists explicitly"
)

let reassigned = try repository.createPerson(
    displayName: "章文新档案",
    phones: ["15397111188"]
)
try repository.renamePerson(reassigned.id, displayName: "章文")
assertEqual(
    repository.peopleFile.unassignedPhoneNumbers,
    [],
    "assigning phone removes unassigned marker"
)
```

Define `makeCall` with the current `CallRecordIndexEntry` initializer and add a local `require` helper.

- [ ] **Step 2: Run and verify RED**

```bash
swiftc \
  Sources/App/CallRecords/CallRecordModels.swift \
  Sources/App/CallRecords/CallRecordArchiveWriter.swift \
  Sources/App/CallRecords/PersonArchiveModels.swift \
  Sources/App/CallRecords/AtomicJSONFileStore.swift \
  Sources/App/CallRecords/PersonArchiveRepository.swift \
  Tests/PersonArchiveRepositoryCheck.swift \
  -o /tmp/person-archive-repository-check
```

Expected: compilation fails because `PersonArchiveRepository` does not exist.

- [ ] **Step 3: Add explicit index decoding helpers**

In `CallRecordArchiveWriter.swift` add:

```swift
static func loadIndex(from archiveRoot: URL) throws -> [CallRecordIndexEntry] {
    let data = try Data(contentsOf: archiveRoot.appendingPathComponent("call_index.json"))
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode([CallRecordIndexEntry].self, from: data)
}

static func archiveRoot(forIndexEntry entry: CallRecordIndexEntry) -> URL {
    URL(fileURLWithPath: entry.outputDirectoryPath, isDirectory: true)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}
```

Do not alter `CallRecordIndexEntry` fields or encoding.

- [ ] **Step 4: Add repository errors and timeline call model**

Append to `PersonArchiveModels.swift`:

```swift
enum PersonArchiveError: LocalizedError, Equatable {
    case readOnly(String)
    case personNotFound(String)
    case phoneConflict(phone: String, ownerID: String)
    case invalidMerge
    case mergeNotFound(String)

    var errorDescription: String? {
        switch self {
        case .readOnly(let reason): return reason
        case .personNotFound: return "人物不存在"
        case .phoneConflict(let phone, _): return "号码 \(phone) 已属于其他人物"
        case .invalidMerge: return "至少选择两个不同人物进行合并"
        case .mergeNotFound: return "找不到可撤销的合并记录"
        }
    }
}

struct PersonTimelineCall: Identifiable, Equatable {
    let entry: CallRecordIndexEntry
    var id: String { entry.id }
    var preferredSourcePath: String {
        !entry.speakerTextPath.isEmpty ? entry.speakerTextPath : entry.transcriptPath
    }
    var isAvailable: Bool {
        !preferredSourcePath.isEmpty
            && FileManager.default.fileExists(atPath: preferredSourcePath)
    }
}
```

- [ ] **Step 5: Implement repository loading and phone-based bootstrap**

Create `PersonArchiveRepository.swift`:

```swift
import Foundation

final class PersonArchiveRepository {
    private(set) var peopleFile = PeopleFile()
    private(set) var indexEntries: [CallRecordIndexEntry] = []
    private(set) var access: PersonArchiveAccess = .writable

    var people: [PersonRecord] {
        peopleFile.people.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    private let archiveRoot: URL
    private let now: () -> Date

    init(archiveRoot: URL, now: @escaping () -> Date = Date.init) {
        self.archiveRoot = archiveRoot
        self.now = now
    }

    func load(indexEntries: [CallRecordIndexEntry]? = nil) throws {
        self.indexEntries = try indexEntries ?? CallRecordArchiveWriter.loadIndex(from: archiveRoot)
        let result: JSONLoadResult<PeopleFile> = AtomicJSONFileStore.load(
            PeopleFile.self,
            from: peopleURL,
            defaultValue: PeopleFile()
        )
        peopleFile = result.value
        access = result.access
        if access == .recoveredFromBackup {
            do {
                try AtomicJSONFileStore.save(peopleFile, to: peopleURL)
                access = .writable
            } catch {
                access = .readOnly(reason: "已读取备份，但无法恢复 people.json")
            }
        }
        if case .readOnly = access {
            return
        }
        try bootstrapMissingPhones()
    }

    func person(containing phone: String) -> PersonRecord? {
        peopleFile.people.first { $0.phoneNumbers.contains(phone) }
    }

    func calls(for personID: String) -> [CallRecordIndexEntry] {
        guard let person = peopleFile.people.first(where: { $0.id == personID }) else { return [] }
        let phones = Set(person.phoneNumbers)
        return indexEntries
            .filter { phones.contains($0.normalizedPhone) }
            .sorted { $0.callDate > $1.callDate }
    }
}
```

Add private URLs for `people.json`, `selection_drafts.json`, and `organization_versions.json`, plus `requireWritable()`, `savePeople()`, and `bootstrapMissingPhones()`. Bootstrap one person per previously unseen normalized phone, choose the first non-empty `contactName` as display name, and persist once after processing all phones. Phones in `unassignedPhoneNumbers` must not be bootstrapped again.

- [ ] **Step 6: Implement merge, split, and revert**

Use:

```swift
@discardableResult
func mergePeople(
    personIDs: [String],
    targetPersonID: String,
    displayName: String
) throws -> PersonRecord

@discardableResult
func splitPhones(
    from personID: String,
    phones: [String],
    newDisplayName: String?
) throws -> PersonRecord?

@discardableResult
func createPerson(displayName: String, phones: [String]) throws -> PersonRecord

func renamePerson(_ personID: String, displayName: String) throws

func assignUnassignedPhones(_ phones: [String], to personID: String) throws

func deletePersonKeepingPhonesUnassigned(_ personID: String) throws

func revertMerge(_ mergeID: String) throws
```

Merge validates unique IDs, captures the complete selected people in `PersonMergeRecord.beforePeople`, checks that no unselected person owns a merged phone, removes merged phones from `unassignedPhoneNumbers`, replaces the selected records with the updated target, and saves once. Split removes selected phones and either creates a new person or adds them to `unassignedPhoneNumbers`. `createPerson`, `renamePerson`, and `assignUnassignedPhones` reject empty names and phone conflicts and update the unassigned set atomically. Deleting a person moves all its numbers to the unassigned set and never deletes call files or historical versions. Revert restores `beforePeople`, removes their phones from `unassignedPhoneNumbers`, and proceeds only when the record is not already reverted and the phones have not been assigned to an unrelated person.

- [ ] **Step 7: Run and verify GREEN**

Compile with the Task 2 command and run `/tmp/person-archive-repository-check`.

Expected: exit code 0.

- [ ] **Step 8: Commit people mapping**

```bash
git add \
  Sources/App/CallRecords/CallRecordArchiveWriter.swift \
  Sources/App/CallRecords/PersonArchiveModels.swift \
  Sources/App/CallRecords/PersonArchiveRepository.swift \
  Tests/PersonArchiveRepositoryCheck.swift
git commit -m "feat: add reversible person call mappings"
```

## Task 3: Persist Per-Person Selection Drafts

**Files:**
- Modify: `Sources/App/CallRecords/PersonArchiveRepository.swift`
- Create: `Tests/PersonSelectionDraftCheck.swift`

- [ ] **Step 1: Write the failing draft test**

Create calls belonging to one person, then assert:

```swift
try repository.setDraftCallIDs(
    Set(["call-a", "call-b", "missing-call"]),
    for: person.id
)
assertEqual(
    repository.draftCallIDs(for: person.id),
    Set(["call-a", "call-b"]),
    "draft prunes unknown calls"
)

try repository.selectRecentCalls(
    for: person.id,
    since: Date(timeIntervalSince1970: 150)
)
assertEqual(repository.draftCallIDs(for: person.id), Set(["call-b"]), "recent selection")

try repository.clearDraft(for: person.id)
assertEqual(repository.draftCallIDs(for: person.id), [], "draft clear")
```

Recreate the repository from the same root after setting a draft and verify the same IDs reload.

- [ ] **Step 2: Run and verify RED**

```bash
swiftc \
  Sources/App/CallRecords/CallRecordModels.swift \
  Sources/App/CallRecords/CallRecordArchiveWriter.swift \
  Sources/App/CallRecords/PersonArchiveModels.swift \
  Sources/App/CallRecords/AtomicJSONFileStore.swift \
  Sources/App/CallRecords/PersonArchiveRepository.swift \
  Tests/PersonSelectionDraftCheck.swift \
  -o /tmp/person-selection-draft-check
```

Expected: compilation fails because draft APIs do not exist.

- [ ] **Step 3: Load and persist `selection_drafts.json`**

Add:

```swift
private(set) var draftsFile = SelectionDraftsFile()

func draftCallIDs(for personID: String) -> Set<String> {
    Set(draftsFile.drafts[personID]?.callIDs ?? [])
}

func setDraftCallIDs(_ callIDs: Set<String>, for personID: String) throws {
    try requireWritable()
    let allowed = Set(
        calls(for: personID)
            .map { PersonTimelineCall(entry: $0) }
            .filter(\.isAvailable)
            .map(\.id)
    )
    let pruned = callIDs.intersection(allowed)
    if pruned.isEmpty {
        draftsFile.drafts.removeValue(forKey: personID)
    } else {
        draftsFile.drafts[personID] = PersonSelectionDraft(
            callIDs: pruned.sorted(),
            updatedAt: now()
        )
    }
    try AtomicJSONFileStore.save(draftsFile, to: draftsURL)
}

func clearDraft(for personID: String) throws {
    try setDraftCallIDs([], for: personID)
}
```

Load `draftsFile` in `load()` using the same backup-recovery policy as `people.json`; any unrecoverable structured file makes the repository read-only. After merge/split/revert, call `pruneAllDrafts()` so drafts never retain calls no longer belonging to that person.

- [ ] **Step 4: Add selection shortcuts**

```swift
func selectAllAvailableCalls(for personID: String) throws {
    let ids = Set(
        calls(for: personID)
            .map { PersonTimelineCall(entry: $0) }
            .filter(\.isAvailable)
            .map(\.id)
    )
    try setDraftCallIDs(ids, for: personID)
}

func selectRecentCalls(for personID: String, since date: Date) throws {
    let ids = Set(
        calls(for: personID)
            .filter { $0.callDate >= date }
            .map { PersonTimelineCall(entry: $0) }
            .filter(\.isAvailable)
            .map(\.id)
    )
    try setDraftCallIDs(ids, for: personID)
}
```

- [ ] **Step 5: Run and verify GREEN**

Compile and run `/tmp/person-selection-draft-check`.

Expected: exit code 0.

- [ ] **Step 6: Commit draft storage**

```bash
git add \
  Sources/App/CallRecords/PersonArchiveRepository.swift \
  Tests/PersonSelectionDraftCheck.swift
git commit -m "feat: persist person call selection drafts"
```

## Task 4: Build Frozen Organization Inputs

**Files:**
- Create: `Sources/App/CallRecords/PersonOrganizationInputBuilder.swift`
- Modify: `Sources/App/CallRecords/PersonArchiveModels.swift`
- Create: `Tests/PersonOrganizationInputCheck.swift`

- [ ] **Step 1: Write failing proofread/fallback tests**

Create:

- `call-a`: both `_整理版.md` and `_通话记录.md`
- `call-b`: only `_通话记录.md`
- `call-c`: neither file

Assert:

```swift
let preparation = try PersonOrganizationInputBuilder.prepare(
    person: person,
    selectedCallIDs: Set(["call-a", "call-b", "call-c"]),
    calls: calls
)
assertEqual(preparation.sources.map(\.sourceKind), [.proofread, .transcript], "source priority")
assertEqual(preparation.unavailableCallIDs, ["call-c"], "unavailable calls")
assertEqual(preparation.markdown.contains("人工校对内容"), true, "proofread content included")
assertEqual(preparation.markdown.contains("原始转写内容"), true, "fallback content included")
assertEqual(
    preparation.sources.allSatisfy { $0.contentHash.hasPrefix("sha256:") },
    true,
    "hashes"
)
```

Overwrite `call-a` after preparation and verify the prepared Markdown and hashes remain unchanged.

- [ ] **Step 2: Run and verify RED**

```bash
swiftc \
  Sources/App/CallRecords/CallRecordModels.swift \
  Sources/App/CallRecords/CallRecordArchiveWriter.swift \
  Sources/App/CallRecords/PersonArchiveModels.swift \
  Sources/App/CallRecords/PersonOrganizationInputBuilder.swift \
  Tests/PersonOrganizationInputCheck.swift \
  -o /tmp/person-organization-input-check
```

Expected: compilation fails because the input builder does not exist.

- [ ] **Step 3: Add preparation models**

Append:

```swift
struct PersonOrganizationPreparation: Equatable {
    let personSnapshot: PersonSnapshot
    let callIDs: [String]
    let sources: [PersonOrganizationSourceSnapshot]
    let unavailableCallIDs: [String]
    let markdown: String
}

enum PersonOrganizationInputError: LocalizedError {
    case noSelectedCalls
    case noReadableCalls

    var errorDescription: String? {
        switch self {
        case .noSelectedCalls: return "请至少选择一条通话"
        case .noReadableCalls: return "所选通话没有可读取的转写内容"
        }
    }
}
```

- [ ] **Step 4: Implement source selection and SHA-256 hashing**

Create:

```swift
import CryptoKit
import Foundation

enum PersonOrganizationInputBuilder {
    static func prepare(
        person: PersonRecord,
        selectedCallIDs: Set<String>,
        calls: [CallRecordIndexEntry]
    ) throws -> PersonOrganizationPreparation {
        guard !selectedCallIDs.isEmpty else {
            throw PersonOrganizationInputError.noSelectedCalls
        }
        let ordered = calls
            .filter { selectedCallIDs.contains($0.id) }
            .sorted { $0.callDate < $1.callDate }
        var sources: [PersonOrganizationSourceSnapshot] = []
        var unavailable: [String] = []
        var sections: [String] = []

        for call in ordered {
            guard let source = readableSource(for: call),
                  let data = FileManager.default.contents(atPath: source.url.path),
                  let content = String(data: data, encoding: .utf8) else {
                unavailable.append(call.id)
                continue
            }
            let digest = SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined()
            sources.append(
                PersonOrganizationSourceSnapshot(
                    callID: call.id,
                    sourceKind: source.kind,
                    sourcePath: source.url.path,
                    contentHash: "sha256:\(digest)"
                )
            )
            sections.append(
                """
                ## \(call.callDateText) | \(call.rawPhone)

                \(content)
                """
            )
        }

        guard !sources.isEmpty else {
            throw PersonOrganizationInputError.noReadableCalls
        }
        return PersonOrganizationPreparation(
            personSnapshot: PersonSnapshot(
                displayName: person.displayName,
                phoneNumbers: person.phoneNumbers.sorted()
            ),
            callIDs: sources.map(\.callID),
            sources: sources,
            unavailableCallIDs: unavailable,
            markdown: ([
                "# \(person.displayName) 通话合并整理输入",
                "",
                "- 号码: \(person.phoneNumbers.sorted().joined(separator: ", "))",
                "- 通话数量: \(sources.count)",
                "",
            ] + sections).joined(separator: "\n")
        )
    }
}
```

`readableSource(for:)` must test `speakerTextPath` first and then `transcriptPath`; each path must be non-empty and exist as a regular file.

- [ ] **Step 5: Run and verify GREEN**

Compile and run `/tmp/person-organization-input-check`.

Expected: exit code 0.

- [ ] **Step 6: Commit frozen input preparation**

```bash
git add \
  Sources/App/CallRecords/PersonArchiveModels.swift \
  Sources/App/CallRecords/PersonOrganizationInputBuilder.swift \
  Tests/PersonOrganizationInputCheck.swift
git commit -m "feat: build frozen person organization inputs"
```

## Task 5: Extend the Summarization Script for Versioned Outputs

**Files:**
- Modify: `Scripts/summarize.py`
- Create: `Tests/test_summarize_output.py`

- [ ] **Step 1: Write failing Python argument and output tests**

Use a fake `openai` module on `PYTHONPATH` and record the prompt:

```python
def test_explicit_output_path_and_full_input(self):
    input_path = self.root / "combined.md"
    marker = "END-OF-CONTENT"
    input_path.write_text("A" * 9000 + marker, encoding="utf-8")
    output_path = self.root / "versions" / "v1.md"

    result = self.run_script(
        input_path,
        "--output-path", output_path,
        "--document-title", "关系进展",
    )

    self.assertEqual(result.returncode, 0, result.stdout)
    self.assertTrue(output_path.exists())
    self.assertIn("# 关系进展", output_path.read_text(encoding="utf-8"))
    self.assertIn(marker, self.recorded_prompt())

def test_api_key_is_not_printed(self):
    secret = "secret-value-that-must-not-appear"
    result = self.run_script(self.input_path, env={"OPENAI_API_KEY": secret})
    self.assertNotIn(secret, result.stdout)
```

- [ ] **Step 2: Run and verify RED**

```bash
python3 -m unittest Tests/test_summarize_output.py -v
```

Expected: failures because `--output-path` and `--document-title` are unknown and content after 8,000 characters is absent.

- [ ] **Step 3: Add explicit output and title arguments**

Add:

```python
parser.add_argument("--output-path", default="")
parser.add_argument("--document-title", default="摘要")
```

Resolve output:

```python
if args.output_path:
    out_path = os.path.abspath(args.output_path)
else:
    out_path = os.path.join(os.path.dirname(text_path), f"{summary_base}_摘要.md")
```

Replace `content[:8000]` with `content`. Do not silently truncate; provider context errors must fail without creating a final output.

- [ ] **Step 4: Write output atomically**

```python
os.makedirs(os.path.dirname(out_path), exist_ok=True)
temp_path = f"{out_path}.{os.getpid()}.tmp"
try:
    with open(temp_path, "w", encoding="utf-8") as handle:
        handle.write(
            f"# {args.document_title}\n\n"
            f"{summary.strip()}\n\n"
            "---\n"
            f"输入文件: {os.path.basename(text_path)}\n"
        )
    os.replace(temp_path, out_path)
finally:
    if os.path.exists(temp_path):
        os.remove(temp_path)
```

Continue printing only input path, model ID, progress, and final output path. Never print API keys, authorization headers, or request bodies.

- [ ] **Step 5: Run and verify GREEN**

```bash
python3 -m unittest Tests/test_summarize_output.py -v
```

Expected: all tests pass.

- [ ] **Step 6: Run existing Python checks**

```bash
python3 -m unittest Tests/test_transcribe_input.py Tests/test_voiceprint.py -v
```

Expected: pass without model downloads.

- [ ] **Step 7: Commit script support**

```bash
git add Scripts/summarize.py Tests/test_summarize_output.py
git commit -m "feat: support versioned summary output paths"
```

## Task 6: Run Organization Jobs and Append Versions

**Files:**
- Create: `Sources/App/CallRecords/PersonOrganizationRunner.swift`
- Modify: `Sources/App/CallRecords/PersonArchiveRepository.swift`
- Modify: `Sources/App/CallRecords/PersonArchiveModels.swift`
- Create: `Tests/PersonOrganizationVersionCheck.swift`

- [ ] **Step 1: Write failing version repository tests**

Append and reload a version:

```swift
try repository.appendOrganizationVersion(version)
let restored = PersonArchiveRepository(archiveRoot: root)
try restored.load(indexEntries: calls)
assertEqual(restored.versions(for: person.id), [version], "version persists")
```

Also create a temporary output without calling `appendOrganizationVersion` and assert the versions list remains empty.

- [ ] **Step 2: Run and verify RED**

```bash
swiftc \
  Sources/App/CallRecords/CallRecordModels.swift \
  Sources/App/CallRecords/CallRecordArchiveWriter.swift \
  Sources/App/CallRecords/PersonArchiveModels.swift \
  Sources/App/CallRecords/AtomicJSONFileStore.swift \
  Sources/App/CallRecords/PersonArchiveRepository.swift \
  Tests/PersonOrganizationVersionCheck.swift \
  -o /tmp/person-organization-version-check
```

Expected: compilation fails because version APIs do not exist.

- [ ] **Step 3: Add version repository APIs**

Load `organization_versions.json` in `load()` using the same backup-recovery policy; an unrecoverable versions file makes the workspace read-only. Then implement:

```swift
private(set) var versionsFile = OrganizationVersionsFile()

func versions(for personID: String) -> [PersonOrganizationVersion] {
    versionsFile.versions
        .filter { $0.personID == personID }
        .sorted { $0.createdAt > $1.createdAt }
}

func appendOrganizationVersion(_ version: PersonOrganizationVersion) throws {
    try requireWritable()
    guard FileManager.default.fileExists(atPath: version.resultPath) else {
        throw CocoaError(.fileNoSuchFile)
    }
    versionsFile.versions.append(version)
    try AtomicJSONFileStore.save(versionsFile, to: versionsURL)
}
```

- [ ] **Step 4: Add runner request/result types**

Append:

```swift
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
```

Create `PersonOrganizationRunner` as an `@MainActor ObservableObject`:

```swift
@Published private(set) var isRunning = false
@Published private(set) var progressText = ""
@Published private(set) var errorMessage: String?
private var process: Process?

func start(
    request: PersonOrganizationRequest,
    completion: @escaping (PersonOrganizationRunResult) -> Void
)

func cancel()
```

- [ ] **Step 5: Implement secret-safe process execution**

Write preparation Markdown to `<archiveRoot>/.tmp/person-organization-<UUID>.md`. Create a final path under `<archiveRoot>/人物整理/<personID>/<yyyyMMdd-HHmmss>_<template>.md`. Put the API key in the child environment:

```swift
var environment = ProcessInfo.processInfo.environment
environment["OPENAI_API_KEY"] = request.model.apiKey
process.environment = environment
process.arguments = [
    request.scriptPath,
    inputURL.path,
    request.model.id,
    "--api-base", request.model.apiBase,
    "--provider-type", request.model.providerType.rawValue,
    "--summary-prompt", request.prompt,
    "--output-path", temporaryOutputURL.path,
    "--document-title", templateTitle,
]
```

Never expose `process.arguments` or `process.environment` in logs. On exit 0, verify output, move it atomically to the final path, create a `PersonOrganizationVersion`, and return it. On failure/cancel, remove temporary files and return no version.

- [ ] **Step 6: Run checks and build**

Run `/tmp/person-organization-version-check`, then:

```bash
xcodegen generate
xcodebuild \
  -project VoiceScribe.xcodeproj \
  -scheme VoiceScribe \
  -configuration Debug \
  -derivedDataPath ./build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Expected: repository check exits 0 and build succeeds.

- [ ] **Step 7: Commit runner and version storage**

```bash
git add \
  Sources/App/CallRecords/PersonArchiveModels.swift \
  Sources/App/CallRecords/PersonArchiveRepository.swift \
  Sources/App/CallRecords/PersonOrganizationRunner.swift \
  Tests/PersonOrganizationVersionCheck.swift \
  VoiceScribe.xcodeproj/project.pbxproj
git commit -m "feat: add versioned person organization runner"
```

## Task 7: Add the Observable Person Timeline Store

**Files:**
- Create: `Sources/App/CallRecords/PersonTimelineStore.swift`
- Modify: `Tests/PersonSelectionDraftCheck.swift`

- [ ] **Step 1: Add failing store behavior tests**

Add:

```swift
let store = await MainActor.run { PersonTimelineStore() }
try await MainActor.run {
    try store.openArchive(root)
    store.selectPerson(person.id)
    try store.toggleCall("call-a")
}
assertEqual(
    await MainActor.run { store.selectedCallIDs },
    Set(["call-a"]),
    "store toggles whole call"
)
```

Also verify `selectRecent30Days(referenceDate:)` chooses only recent available calls.

- [ ] **Step 2: Run and verify RED**

Run:

```bash
swiftc \
  Sources/App/CallRecords/CallRecordModels.swift \
  Sources/App/CallRecords/CallRecordArchiveWriter.swift \
  Sources/App/CallRecords/PersonArchiveModels.swift \
  Sources/App/CallRecords/AtomicJSONFileStore.swift \
  Sources/App/CallRecords/PersonArchiveRepository.swift \
  Sources/App/CallRecords/PersonOrganizationInputBuilder.swift \
  Sources/App/CallRecords/PersonTimelineStore.swift \
  Tests/PersonSelectionDraftCheck.swift \
  -framework Combine \
  -o /tmp/person-selection-draft-check
```

Expected: compilation fails because the store does not exist.

- [ ] **Step 3: Implement store state**

Create:

```swift
import Combine
import Foundation

@MainActor
final class PersonTimelineStore: ObservableObject {
    @Published private(set) var archiveRoot: URL?
    @Published private(set) var people: [PersonRecord] = []
    @Published private(set) var selectedPersonID: String?
    @Published private(set) var calls: [PersonTimelineCall] = []
    @Published private(set) var selectedCallIDs: Set<String> = []
    @Published private(set) var versions: [PersonOrganizationVersion] = []
    @Published private(set) var access: PersonArchiveAccess = .writable
    @Published var searchText = ""
    @Published var errorMessage: String?

    private var repository: PersonArchiveRepository?

    func openArchive(_ root: URL) throws
    func reload() throws
    func selectPerson(_ id: String)
    func toggleCall(_ id: String) throws
    func selectAll() throws
    func clearSelection() throws
    func selectRecent30Days(referenceDate: Date = Date()) throws
    func createPerson(displayName: String, phones: [String]) throws
    func renamePerson(_ id: String, displayName: String) throws
    func assignUnassignedPhones(_ phones: [String], to personID: String) throws
    func deletePersonKeepingPhonesUnassigned(_ id: String) throws
    func mergePeople(personIDs: [String], targetID: String, displayName: String) throws
    func splitPhones(personID: String, phones: [String], newDisplayName: String?) throws
    func revertMerge(_ id: String) throws
}
```

`selectPerson` reloads calls, draft IDs, and versions. `toggleCall` rejects unavailable calls. Add `filteredPeople` to search display names and phone numbers without mutating repository state. Expose `unassignedPhoneNumbers` from the repository so the left pane can show intentionally unassigned numbers without recreating people for them.

- [ ] **Step 4: Add organization methods**

```swift
func prepareOrganization() throws -> PersonOrganizationPreparation

func commitOrganizationVersion(_ version: PersonOrganizationVersion) throws {
    do {
        try repository?.appendOrganizationVersion(version)
    } catch {
        pendingVersionRepair = version
        throw error
    }
    pendingVersionRepair = nil
    try repository?.clearDraft(for: version.personID)
    selectPerson(version.personID)
}

func preserveDraftAfterFailedRun() {
    // No mutation; persisted draft remains authoritative.
}

func present(_ error: Error) {
    errorMessage = error.localizedDescription
}

func present(_ message: String) {
    errorMessage = message
}
```

Add `@Published private(set) var pendingVersionRepair: PersonOrganizationVersion?` and:

```swift
func repairVersionIndex() throws {
    guard let version = pendingVersionRepair else { return }
    try repository?.appendOrganizationVersion(version)
    try repository?.clearDraft(for: version.personID)
    pendingVersionRepair = nil
    selectPerson(version.personID)
}
```

Use a 250 ms `DispatchWorkItem` debounce for checkbox changes. Flush the pending draft synchronously before switching people, opening another archive, starting organization, or deinitializing the store.

- [ ] **Step 5: Run and verify GREEN**

Recompile and run `/tmp/person-selection-draft-check` and `/tmp/person-organization-input-check`.

Expected: both exit 0.

- [ ] **Step 6: Commit the observable store**

```bash
git add \
  Sources/App/CallRecords/PersonTimelineStore.swift \
  Tests/PersonSelectionDraftCheck.swift
git commit -m "feat: add person timeline workspace state"
```

## Task 8: Build the Three-Column Workspace

**Files:**
- Create: `Sources/App/CallRecords/PersonTimelineView.swift`
- Create: `Sources/App/CallRecords/PersonListPane.swift`
- Create: `Sources/App/CallRecords/PersonCallsPane.swift`
- Create: `Sources/App/CallRecords/PersonOrganizationPane.swift`

- [ ] **Step 1: Create the top-level split layout**

```swift
struct PersonTimelineView: View {
    @ObservedObject var store: PersonTimelineStore
    @ObservedObject var runner: PersonOrganizationRunner
    @ObservedObject var settingsManager: SettingsManager
    let pythonPath: String
    let summarizeScriptPath: String
    var onChooseArchive: () -> Void

    var body: some View {
        Group {
            if store.archiveRoot == nil {
                archiveEmptyState
            } else {
                HSplitView {
                    PersonListPane(store: store)
                        .frame(minWidth: 220, idealWidth: 250, maxWidth: 320)
                    PersonCallsPane(store: store)
                        .frame(minWidth: 420, idealWidth: 560)
                    PersonOrganizationPane(
                        store: store,
                        runner: runner,
                        settingsManager: settingsManager,
                        pythonPath: pythonPath,
                        summarizeScriptPath: summarizeScriptPath
                    )
                    .frame(minWidth: 300, idealWidth: 360, maxWidth: 460)
                }
            }
        }
    }
}
```

The empty state contains one “选择通话归档目录” folder button. A read-only banner appears above the panes when the JSON store cannot be recovered.

- [ ] **Step 2: Build the people pane**

`PersonListPane` includes:

- Search field bound to `store.searchText`.
- One row per `store.filteredPeople`.
- Display name, phone count, call count, and latest call date.
- A distinct “未归档号码” section.
- A toolbar menu for create, rename, assign-number, merge, split, delete, and revert.

Use a `List` or `ScrollView`/`LazyVStack`; do not nest decorative cards.

- [ ] **Step 3: Build the timeline pane**

Add toolbar actions:

```swift
Button { try? store.selectAll() } label: {
    Label("全选", systemImage: "checkmark.square")
}
Button { try? store.clearSelection() } label: {
    Label("清空", systemImage: "square")
}
Button { try? store.selectRecent30Days() } label: {
    Label("最近 30 天", systemImage: "calendar")
}
```

Each call uses:

```swift
Button {
    try? store.toggleCall(call.id)
} label: {
    Image(systemName: store.selectedCallIDs.contains(call.id)
        ? "checkmark.square.fill"
        : "square")
}
.buttonStyle(.plain)
.disabled(!call.isAvailable)
```

Show call time, raw phone, duration, source type, the first 120 non-empty characters from `summaryPath` when readable, and a visible missing-file reason.

- [ ] **Step 4: Build organization controls and versions**

`PersonOrganizationPane`:

- Initializes model selection from `lastSummaryModelID`.
- Uses stable templates `relationship-progress`, `action-items`, `requirements-changes`, and `custom`.
- Shows selected count and date coverage.
- Disables start for no selection, no model, read-only mode, or an active run.
- Shows confirmation when preparation contains unavailable call IDs.
- Displays runner progress/errors without process arguments or secrets.
- Lists versions with model, template, date, input count, and result-open action.
- Shows “修复版本索引” when `store.pendingVersionRepair` is non-nil; the action calls `store.repairVersionIndex()` without regenerating model output.

- [ ] **Step 5: Generate and build**

```bash
xcodegen generate
xcodebuild \
  -project VoiceScribe.xcodeproj \
  -scheme VoiceScribe \
  -configuration Debug \
  -derivedDataPath ./build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit the initial UI**

```bash
git add \
  Sources/App/CallRecords/PersonTimelineView.swift \
  Sources/App/CallRecords/PersonListPane.swift \
  Sources/App/CallRecords/PersonCallsPane.swift \
  Sources/App/CallRecords/PersonOrganizationPane.swift \
  VoiceScribe.xcodeproj/project.pbxproj
git commit -m "feat: add three-column person timeline workspace"
```

## Task 9: Add Manual Merge, Split, and Revert UI

**Files:**
- Create: `Sources/App/CallRecords/PersonMergeSheet.swift`
- Modify: `Sources/App/CallRecords/PersonListPane.swift`
- Modify: `Sources/App/CallRecords/PersonTimelineView.swift`
- Modify: `Sources/App/CallRecords/PersonTimelineStore.swift`

- [ ] **Step 1: Add merge sheet**

```swift
struct PersonMergeSheet: View {
    let candidates: [PersonRecord]
    let callCounts: [String: Int]
    @State var targetPersonID: String
    @State var displayName: String
    var onConfirm: (_ personIDs: [String], _ targetID: String, _ displayName: String) -> Void
    var onCancel: () -> Void
}
```

Show affected names, numbers, and call counts. Disable confirmation unless at least two people are selected, the target is selected, and the display name is non-empty.

- [ ] **Step 2: Add same-name suggestions without automatic merge**

```swift
var mergeSuggestions: [[PersonRecord]] {
    Dictionary(grouping: people) {
        $0.displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
    .values
    .filter { $0.count > 1 }
    .map { $0.sorted { $0.displayName < $1.displayName } }
}
```

Render “可能是同一人” as an action that opens the sheet; it must not mutate data.

- [ ] **Step 3: Add split and revert controls**

The split UI allows:

- “恢复为未归档号码” → `newDisplayName: nil`
- “创建新人物” → require a non-empty name

List only merge records with `revertedAt == nil`, newest first, and show affected mappings before revert confirmation.

- [ ] **Step 4: Verify conflict behavior**

Create a temporary `people.json` where a third person owns one target phone. Attempt a merge and verify:

- no JSON file changes;
- the conflict alert identifies the phone;
- the sheet remains open.

- [ ] **Step 5: Build and commit**

Run the Task 8 build, then:

```bash
git add \
  Sources/App/CallRecords/PersonMergeSheet.swift \
  Sources/App/CallRecords/PersonListPane.swift \
  Sources/App/CallRecords/PersonTimelineView.swift \
  Sources/App/CallRecords/PersonTimelineStore.swift \
  VoiceScribe.xcodeproj/project.pbxproj
git commit -m "feat: add manual contact merge controls"
```

## Task 10: Integrate Navigation, Archive Selection, and Run Completion

**Files:**
- Modify: `Sources/App/ContentView.swift`
- Modify: `Sources/App/Components/SidebarView.swift`
- Modify: `Sources/App/CallRecords/PersonOrganizationPane.swift`

- [ ] **Step 1: Add state and navigation**

In `ContentView`:

```swift
@StateObject private var personTimelineStore = PersonTimelineStore()
@StateObject private var personOrganizationRunner = PersonOrganizationRunner()
```

Add `.people` to `MainTab` between `.batchQueue` and `.editor`, and render:

```swift
case .people:
    PersonTimelineView(
        store: personTimelineStore,
        runner: personOrganizationRunner,
        settingsManager: settingsManager,
        pythonPath: envChecker.pythonPath,
        summarizeScriptPath: Bundle.main.url(
            forResource: "summarize",
            withExtension: "py"
        )?.path ?? "",
        onChooseArchive: choosePersonArchiveRoot
    )
```

Add to `SidebarView`:

```swift
SidebarTabButton(
    title: "人物归档",
    icon: "person.2.fill",
    tab: .people,
    activeTab: $activeTab
)
```

- [ ] **Step 2: Add explicit archive selection**

```swift
private func choosePersonArchiveRoot() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = "打开归档"
    if panel.runModal() == .OK, let root = panel.url {
        do {
            try personTimelineStore.openArchive(root)
            UserDefaults.standard.set(root.path, forKey: "lastPersonArchiveRoot")
        } catch {
            personTimelineStore.present(error)
        }
    }
}
```

On appear, load `lastPersonArchiveRoot` only when its `call_index.json` exists.

- [ ] **Step 3: Connect organization completion**

```swift
if let version = result.version {
    do {
        try store.commitOrganizationVersion(version)
    } catch {
        store.present(error)
    }
} else if let message = result.errorMessage {
    store.present(message)
    store.preserveDraftAfterFailedRun()
}
```

Clear the draft only after both result and version index commit.

- [ ] **Step 4: Refresh after batch archive writes**

After `CallRecordArchiveWriter.write(...)` succeeds:

```swift
if personTimelineStore.archiveRoot == callRecordArchiveRoot() {
    try? personTimelineStore.reload()
}
```

Do not silently switch roots when batch output differs.

- [ ] **Step 5: Build and manually verify**

Run:

```bash
xcodegen generate
xcodebuild \
  -project VoiceScribe.xcodeproj \
  -scheme VoiceScribe \
  -configuration Debug \
  -derivedDataPath ./build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Verify:

1. “人物归档” is separate from “历史记录”.
2. Switching people restores each draft.
3. Provider failure preserves selection.
4. Success appends a version and clears only the active person’s draft.

- [ ] **Step 6: Commit integration**

```bash
git add \
  Sources/App/ContentView.swift \
  Sources/App/Components/SidebarView.swift \
  Sources/App/CallRecords/PersonOrganizationPane.swift \
  VoiceScribe.xcodeproj/project.pbxproj
git commit -m "feat: integrate person archive workspace"
```

## Task 11: Complete Verification, Documentation, and Packaging

**Files:**
- Modify: `README.md`
- Modify: `SPEC.md`
- Create: `dist/VoiceScribe-1.0.0-beta-person-timeline-20260615.pkg`

- [ ] **Step 1: Document the workflow**

Add:

```markdown
### 人物归档与跨通话整理

- 人物归档直接读取通话归档目录中的 `call_index.json`，不依赖历史任务。
- 相同标准化号码自动归入同一人物；同名不同号码只提示手动合并。
- 在人物时间轴中按整次通话勾选，可全选、清空或选择最近 30 天。
- 勾选草稿自动保存；成功整理后清空，失败或取消时保留。
- 整理优先使用 `_整理版.md`，不存在时回退到 `_通话记录.md`。
- 每次整理生成新版本，并记录模型、模板、所选通话和输入文件摘要。
```

State that API keys are runtime-only and the app does not download models.

- [ ] **Step 2: Update SPEC contracts**

Document `people.json`, `selection_drafts.json`, `organization_versions.json`, result directory naming, phone uniqueness, atomic backup behavior, and independence from batch selection.

- [ ] **Step 3: Run standalone Swift checks**

```bash
swiftc Sources/App/CallRecords/CallRecordModels.swift \
  Tests/CallRecordParserCheck.swift \
  -o /tmp/call-record-parser-check &&
/tmp/call-record-parser-check

swiftc Sources/App/CallRecords/CallRecordModels.swift \
  Sources/App/CallRecords/CallRecordArchiveWriter.swift \
  Sources/App/CallRecords/PersonArchiveModels.swift \
  Sources/App/CallRecords/AtomicJSONFileStore.swift \
  Sources/App/CallRecords/PersonArchiveRepository.swift \
  Tests/PersonArchiveRepositoryCheck.swift \
  -o /tmp/person-archive-repository-check &&
/tmp/person-archive-repository-check

swiftc Sources/App/CallRecords/CallRecordModels.swift \
  Sources/App/CallRecords/CallRecordArchiveWriter.swift \
  Sources/App/CallRecords/PersonArchiveModels.swift \
  Sources/App/CallRecords/AtomicJSONFileStore.swift \
  Sources/App/CallRecords/PersonArchiveRepository.swift \
  Tests/PersonSelectionDraftCheck.swift \
  -o /tmp/person-selection-draft-check &&
/tmp/person-selection-draft-check

swiftc Sources/App/CallRecords/CallRecordModels.swift \
  Sources/App/CallRecords/CallRecordArchiveWriter.swift \
  Sources/App/CallRecords/PersonArchiveModels.swift \
  Sources/App/CallRecords/PersonOrganizationInputBuilder.swift \
  Tests/PersonOrganizationInputCheck.swift \
  -o /tmp/person-organization-input-check &&
/tmp/person-organization-input-check

swiftc Sources/App/CallRecords/CallRecordModels.swift \
  Sources/App/CallRecords/CallRecordArchiveWriter.swift \
  Sources/App/CallRecords/PersonArchiveModels.swift \
  Sources/App/CallRecords/AtomicJSONFileStore.swift \
  Sources/App/CallRecords/PersonArchiveRepository.swift \
  Tests/PersonOrganizationVersionCheck.swift \
  -o /tmp/person-organization-version-check &&
/tmp/person-organization-version-check
```

Expected: all exit 0.

- [ ] **Step 4: Run Python and server tests**

```bash
python3 -m unittest \
  Tests/test_summarize_output.py \
  Tests/test_transcribe_input.py \
  Tests/test_voiceprint.py \
  -v

uv run --project Server --dev python -m pytest Server/tests -q
```

Expected: pass without downloading models or deploying services.

- [ ] **Step 5: Regenerate and build Release**

Inspect the project diff before generation:

```bash
git diff -- VoiceScribe.xcodeproj/project.pbxproj
xcodegen generate
git diff --check
xcodebuild \
  -project VoiceScribe.xcodeproj \
  -scheme VoiceScribe \
  -configuration Release \
  -derivedDataPath ./build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Expected: only intended file references change and build succeeds.

- [ ] **Step 6: Verify with `/Users/sirius/Desktop/test`**

Do not delete or rename fixtures:

1. Import the directory.
2. Confirm recordings shorter than 10 seconds stay ignored.
3. Open its generated `VoiceScribe_CallRecords`.
4. Confirm same-number grouping.
5. Select two readable calls and prepare organization.
6. If a configured provider is available, run it and confirm a new version.

If the model/API is unavailable, stop after input preparation and report the external dependency. Do not download a model.

- [ ] **Step 7: Package without installing**

```bash
codesign --force --deep --sign - \
  build/DerivedData/Build/Products/Release/VoiceScribe.app
codesign --verify --deep --strict --verbose=2 \
  build/DerivedData/Build/Products/Release/VoiceScribe.app
pkgbuild \
  --component build/DerivedData/Build/Products/Release/VoiceScribe.app \
  --install-location /Applications \
  --identifier com.voicescribe.app.pkg \
  --version 1.0.0-beta \
  dist/VoiceScribe-1.0.0-beta-person-timeline-20260615.pkg
```

Inspect:

```bash
pkgutil --payload-files \
  dist/VoiceScribe-1.0.0-beta-person-timeline-20260615.pkg |
rg 'VoiceScribe.app/Contents/(MacOS/VoiceScribe|Resources/summarize.py|Resources/transcribe.py|Info.plist)'

shasum -a 256 \
  dist/VoiceScribe-1.0.0-beta-person-timeline-20260615.pkg
```

- [ ] **Step 8: Commit documentation**

Do not commit the generated package unless release packages are already tracked:

```bash
git add README.md SPEC.md
git commit -m "docs: document person call organization workflow"
```

- [ ] **Step 9: Final status audit**

```bash
git status --short --branch
git log --oneline -12
```

Expected: no uncommitted files from this implementation. List and retain preexisting unrelated items.

## Manual Acceptance Scenario

1. Open “人物归档” and choose an archive containing `call_index.json`.
2. Verify calls with the same normalized number appear under one person.
3. Verify two people with the same name but different numbers remain separate and only show a merge suggestion.
4. Merge them manually and verify both numbers’ calls appear in one timeline.
5. Revert the merge and verify original mappings return without moving files.
6. Select two whole calls, leave one unselected, switch pages, and return.
7. Verify the selected calls restore.
8. Run organization and inspect metadata.
9. Verify only selected call IDs appear and proofread files take priority.
10. Verify success creates a new version and clears the draft.
11. Run again with a different selection and verify the first version remains.
12. Force a provider failure and verify no version is added and selection remains.
