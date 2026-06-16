# Call Record Manual Selection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users manually select arbitrary call-record jobs, quickly select all or the first 20 pending jobs, process only that frozen selection, and automatically pause when the selected run finishes.

**Architecture:** Keep selection state in `CallRecordQueueStore` without changing `CallRecordBatchJob` serialization. Persist editable `selectedJobIDs` separately, snapshot them into in-memory `activeRunJobIDs` when a run starts, and make queue scheduling filter against that snapshot. The SwiftUI view renders checkboxes and selection shortcuts while `ContentView` continues to own transcription and summarization orchestration.

**Tech Stack:** Swift 5.9, SwiftUI, Combine, Foundation, AVFoundation, standalone `swiftc` checks, XcodeGen/Xcode.

---

## File Map

- Modify `Sources/App/CallRecords/CallRecordQueueStore.swift`: selection persistence, first-20 selection, run snapshot, automatic end-state.
- Modify `Sources/App/CallRecords/CallRecordBatchQueueView.swift`: selection toolbar, row checkboxes, selected count, run-state messaging.
- Modify `Sources/App/ContentView.swift`: start only selected jobs and finish the selected run when no snapshot jobs remain.
- Modify `Tests/CallRecordQueueCheck.swift`: selection, ordering, persistence, snapshot isolation, and auto-pause checks.
- Modify `README.md`: explain partial queue selection.
- Modify `SPEC.md`: record selection and scheduling contract.
- No new Swift source file is required, so `xcodegen generate` should not be needed unless project membership changes for another reason.

### Task 1: Specify Selection and Ordering in Queue Tests

**Files:**
- Modify: `Tests/CallRecordQueueCheck.swift`
- Test: `Tests/CallRecordQueueCheck.swift`

- [ ] **Step 1: Add a fixture helper that creates 25 valid call recordings**

Add a loop after the existing short/long assertions. Use increasing timestamps so chronological order is deterministic:

```swift
var selectionFiles: [URL] = []
for index in 0..<25 {
    let timestamp = String(format: "20250101%02d0000", index)
    let file = root.appendingPathComponent(
        "联系人\(index)@138 0000 \(String(format: "%04d", index))_\(timestamp).wav"
    )
    try writeSilentWav(to: file, durationSeconds: 12)
    selectionFiles.append(file)
}

let selectionKey = "CallRecordSelectionCheck-\(UUID().uuidString)"
let selectionStore = await MainActor.run {
    CallRecordQueueStore(storageKey: selectionKey)
}
await selectionStore.importFiles(
    selectionFiles.reversed(),
    outputRoot: outputRoot,
    engine: "whisperMLX",
    modelID: "mlx-community/whisper-large-v3-turbo"
)
```

- [ ] **Step 2: Add failing assertions for first-20 and manual selection**

```swift
await MainActor.run {
    selectionStore.selectFirstPending(20)
}

let orderedJobs = await MainActor.run { selectionStore.pendingJobsInRunOrder }
assertEqual(
    await MainActor.run { selectionStore.selectedPendingCount },
    20,
    "first 20 selection count"
)
for job in orderedJobs.prefix(20) {
    assertEqual(
        await MainActor.run { selectionStore.isSelected(job.id) },
        true,
        "first 20 selected"
    )
}
assertEqual(
    await MainActor.run { selectionStore.isSelected(orderedJobs[20].id) },
    false,
    "21st job remains unselected"
)

await MainActor.run {
    selectionStore.toggleSelection(id: orderedJobs[0].id)
    selectionStore.toggleSelection(id: orderedJobs[20].id)
}
assertEqual(
    await MainActor.run { selectionStore.selectedPendingCount },
    20,
    "manual selection replaces one selected job"
)
```

- [ ] **Step 3: Add failing assertions for all/none shortcuts**

```swift
await MainActor.run { selectionStore.selectAllPending() }
assertEqual(
    await MainActor.run { selectionStore.selectedPendingCount },
    25,
    "select all pending"
)

await MainActor.run { selectionStore.clearSelection() }
assertEqual(
    await MainActor.run { selectionStore.selectedPendingCount },
    0,
    "clear selection"
)
```

- [ ] **Step 4: Run the test and verify RED**

Run:

```bash
swiftc -module-cache-path /tmp/voicescribe-swift-module-cache \
  Sources/App/CallRecords/CallRecordModels.swift \
  Sources/App/CallRecords/CallRecordQueueStore.swift \
  Tests/CallRecordQueueCheck.swift \
  -framework AVFoundation \
  -o /tmp/call-record-queue-check &&
/tmp/call-record-queue-check
```

Expected: compilation fails because `selectFirstPending`, `pendingJobsInRunOrder`, `selectedPendingCount`, `isSelected`, `toggleSelection`, `selectAllPending`, and `clearSelection` do not exist.

- [ ] **Step 5: Commit the failing test**

```bash
git add Tests/CallRecordQueueCheck.swift
git commit -m "test: define call record queue selection behavior"
```

### Task 2: Implement Persistent Editable Selection

**Files:**
- Modify: `Sources/App/CallRecords/CallRecordQueueStore.swift`
- Test: `Tests/CallRecordQueueCheck.swift`

- [ ] **Step 1: Add published selection state and storage keys**

Add these properties:

```swift
@Published private(set) var selectedJobIDs: Set<String> = []
@Published private(set) var didCompleteSelectedRun = false

private var activeRunJobIDs: Set<String> = []
private let selectionStorageKey: String
```

Initialize and load them:

```swift
init(storageKey: String = "callRecordBatchJobs") {
    self.storageKey = storageKey
    self.selectionStorageKey = "\(storageKey).selectedJobIDs"
    load()
    loadSelection()
    pruneSelection()
}
```

- [ ] **Step 2: Add deterministic pending ordering and selection APIs**

```swift
var pendingJobsInRunOrder: [CallRecordBatchJob] {
    jobs
        .filter { $0.status == .pending }
        .sorted(by: Self.sortByCallDate)
}

var selectedPendingCount: Int {
    pendingJobsInRunOrder.filter { selectedJobIDs.contains($0.id) }.count
}

func isSelected(_ id: String) -> Bool {
    selectedJobIDs.contains(id)
}

func toggleSelection(id: String) {
    guard !isActive,
          jobs.contains(where: { $0.id == id && $0.status == .pending }) else {
        return
    }
    if selectedJobIDs.contains(id) {
        selectedJobIDs.remove(id)
    } else {
        selectedJobIDs.insert(id)
    }
    didCompleteSelectedRun = false
    saveSelection()
}

func selectAllPending() {
    guard !isActive else { return }
    selectedJobIDs = Set(pendingJobsInRunOrder.map(\.id))
    didCompleteSelectedRun = false
    saveSelection()
}

func selectFirstPending(_ count: Int) {
    guard !isActive else { return }
    selectedJobIDs = Set(pendingJobsInRunOrder.prefix(max(0, count)).map(\.id))
    didCompleteSelectedRun = false
    saveSelection()
}

func clearSelection() {
    guard !isActive else { return }
    selectedJobIDs.removeAll()
    didCompleteSelectedRun = false
    saveSelection()
}

private static func sortByCallDate(
    _ lhs: CallRecordBatchJob,
    _ rhs: CallRecordBatchJob
) -> Bool {
    let leftDate = lhs.metadata?.callDate ?? lhs.createdAt
    let rightDate = rhs.metadata?.callDate ?? rhs.createdAt
    if leftDate == rightDate {
        return lhs.id < rhs.id
    }
    return leftDate < rightDate
}
```

- [ ] **Step 3: Persist selection separately and prune stale IDs**

```swift
private func loadSelection() {
    guard let values = UserDefaults.standard.array(
        forKey: selectionStorageKey
    ) as? [String] else {
        selectedJobIDs = []
        return
    }
    selectedJobIDs = Set(values)
}

private func saveSelection() {
    UserDefaults.standard.set(
        Array(selectedJobIDs).sorted(),
        forKey: selectionStorageKey
    )
}

private func pruneSelection() {
    let existingIDs = Set(jobs.map(\.id))
    selectedJobIDs.formIntersection(existingIDs)
    saveSelection()
}
```

Call `pruneSelection()` after `clearCompletedAndIgnored()`, and clear both sets in `clearAll()`:

```swift
selectedJobIDs.removeAll()
activeRunJobIDs.removeAll()
didCompleteSelectedRun = false
saveSelection()
```

- [ ] **Step 4: Run the queue test and verify GREEN**

Run the Task 1 command.

Expected: the first-20, manual, all, and clear selection assertions pass.

- [ ] **Step 5: Commit selection storage**

```bash
git add Sources/App/CallRecords/CallRecordQueueStore.swift Tests/CallRecordQueueCheck.swift
git commit -m "feat: add persistent call record queue selection"
```

### Task 3: Freeze the Selected Run and Auto-Pause

**Files:**
- Modify: `Sources/App/CallRecords/CallRecordQueueStore.swift`
- Modify: `Tests/CallRecordQueueCheck.swift`

- [ ] **Step 1: Add failing tests for snapshot isolation**

After selecting the first 20:

```swift
let started = await MainActor.run { selectionStore.startSelected() }
assertEqual(started, true, "selected run starts")

let firstRunJob = try require(
    await MainActor.run { selectionStore.nextPendingJob() },
    "first selected run job"
)
assertEqual(
    await MainActor.run { selectionStore.isSelected(firstRunJob.id) },
    true,
    "scheduler only returns selected jobs"
)

await MainActor.run {
    selectionStore.toggleSelection(id: orderedJobs[24].id)
}
assertEqual(
    await MainActor.run { selectionStore.isSelected(orderedJobs[24].id) },
    false,
    "selection cannot change while running"
)
```

- [ ] **Step 2: Add failing tests for selected-run completion**

```swift
let selectedIDs = await MainActor.run { selectionStore.selectedJobIDs }
for id in selectedIDs {
    await MainActor.run { selectionStore.markCompleted(id: id) }
}

let remaining = await MainActor.run { selectionStore.nextPendingJob() }
assertEqual(remaining, nil, "selected run has no remaining job")
await MainActor.run { selectionStore.finishSelectedRun() }

assertEqual(
    await MainActor.run { selectionStore.isActive },
    false,
    "selected run stops"
)
assertEqual(
    await MainActor.run { selectionStore.isPaused },
    true,
    "selected run auto pauses"
)
assertEqual(
    await MainActor.run { selectionStore.didCompleteSelectedRun },
    true,
    "selected run completion is visible"
)
assertEqual(
    await MainActor.run {
        selectionStore.jobs.filter { $0.status == .pending }.count
    },
    5,
    "unselected jobs remain pending"
)
```

- [ ] **Step 3: Run the test and verify RED**

Run the Task 1 command.

Expected: compilation fails because `startSelected()` and `finishSelectedRun()` do not exist.

- [ ] **Step 4: Implement selected-run lifecycle**

Replace unrestricted `start()` scheduling with:

```swift
@discardableResult
func startSelected() -> Bool {
    let runnableIDs = Set(
        pendingJobsInRunOrder
            .filter { selectedJobIDs.contains($0.id) }
            .map(\.id)
    )
    guard !runnableIDs.isEmpty else { return false }
    activeRunJobIDs = runnableIDs
    isActive = true
    isPaused = false
    didCompleteSelectedRun = false
    return true
}

var canResumeSelectedRun: Bool {
    isActive
        && isPaused
        && jobs.contains {
            activeRunJobIDs.contains($0.id) && $0.status == .pending
        }
}

func finishSelectedRun() {
    isActive = false
    isPaused = true
    activeRunJobIDs.removeAll()
    didCompleteSelectedRun = true
}
```

Update scheduling:

```swift
func nextPendingJob() -> CallRecordBatchJob? {
    guard isActive, !isPaused else { return nil }
    return pendingJobsInRunOrder.first {
        activeRunJobIDs.contains($0.id)
    }
}
```

Update pause/resume:

```swift
func pause() {
    guard isActive else { return }
    isPaused = true
}

func resume() {
    guard canResumeSelectedRun else { return }
    isPaused = false
}
```

- [ ] **Step 5: Verify GREEN**

Run the Task 1 command.

Expected: all queue checks pass and five unselected jobs remain pending.

- [ ] **Step 6: Commit run snapshot behavior**

```bash
git add Sources/App/CallRecords/CallRecordQueueStore.swift Tests/CallRecordQueueCheck.swift
git commit -m "feat: run only selected call record jobs"
```

### Task 4: Connect Selected Scheduling to ContentView

**Files:**
- Modify: `Sources/App/ContentView.swift`
- Test: `Tests/CallRecordQueueCheck.swift`

- [ ] **Step 1: Start only the selected snapshot**

Replace `startCallRecordQueue()` with:

```swift
private func startCallRecordQueue() {
    guard callRecordSummaryModel != nil else { return }
    guard callRecordQueue.startSelected() else { return }
    runNextCallRecordJobIfNeeded()
}
```

- [ ] **Step 2: Finish instead of clearing the entire queue state**

Update the no-job branch:

```swift
guard let job = callRecordQueue.nextPendingJob() else {
    if callRecordQueue.isActive && !callRecordQueue.isPaused {
        callRecordQueue.finishSelectedRun()
    }
    return
}
```

This branch executes only after the selected snapshot has no remaining pending jobs. Manual pause returns earlier because `isPaused` is true.

- [ ] **Step 3: Keep retry explicit**

Update retry so it does not unexpectedly start an idle queue:

```swift
private func retryCallRecordJob(_ job: CallRecordBatchJob) {
    callRecordQueue.retry(job)
    if callRecordQueue.isActive && !callRecordQueue.isPaused {
        runNextCallRecordJobIfNeeded()
    }
}
```

- [ ] **Step 4: Build to catch integration errors**

Run:

```bash
xcodebuild \
  -project VoiceScribe.xcodeproj \
  -scheme VoiceScribe \
  -configuration Debug \
  -derivedDataPath ./build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit orchestration changes**

```bash
git add Sources/App/ContentView.swift
git commit -m "feat: orchestrate selected call record runs"
```

### Task 5: Add Selection Controls and Manual Checkboxes

**Files:**
- Modify: `Sources/App/CallRecords/CallRecordBatchQueueView.swift`

- [ ] **Step 1: Add the selection bar**

Place it between `workflowBanner` and `statsRow`:

```swift
private var selectionBar: some View {
    HStack(spacing: 8) {
        Button("全选") {
            store.selectAllPending()
        }
        .buttonStyle(.bordered)

        Button("取消全选") {
            store.clearSelection()
        }
        .buttonStyle(.bordered)

        Button("选择前 20 条") {
            store.selectFirstPending(20)
        }
        .buttonStyle(.borderedProminent)

        Spacer()

        Text("已选 \(store.selectedPendingCount) 条")
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(Color(hex: "A0A0B0"))
    }
    .disabled(store.isActive)
}
```

Use it in the body:

```swift
VStack(spacing: 12) {
    workflowBanner
    selectionBar
    statsRow
    queueList
}
```

- [ ] **Step 2: Change the start/resume button conditions**

```swift
if store.isActive && !store.isPaused {
    Button(action: onPause) {
        Label("暂停本轮", systemImage: "pause.fill")
    }
    .buttonStyle(.bordered)
} else if store.canResumeSelectedRun {
    Button(action: onResume) {
        Label("继续本轮", systemImage: "play.fill")
    }
    .buttonStyle(.borderedProminent)
} else {
    Button(action: onStart) {
        Label(
            "开始所选 (\(store.selectedPendingCount))",
            systemImage: "play.fill"
        )
    }
    .buttonStyle(.borderedProminent)
    .disabled(
        store.selectedPendingCount == 0
            || isProcessing
            || summaryModelName == nil
    )
}
```

- [ ] **Step 3: Add a checkbox to every row**

Pass selection state and callback:

```swift
CallRecordJobRow(
    job: job,
    isCurrent: currentAudioPath == job.sourcePath,
    isSelected: store.isSelected(job.id),
    selectionDisabled: store.isActive || job.status != .pending,
    progress: currentAudioPath == job.sourcePath ? progress : job.progress,
    onToggleSelection: { store.toggleSelection(id: job.id) },
    onRetry: { onRetry(job) }
)
```

Add row properties:

```swift
let isSelected: Bool
let selectionDisabled: Bool
var onToggleSelection: () -> Void
```

Render the checkbox before the status icon:

```swift
Button(action: onToggleSelection) {
    Image(
        systemName: isSelected
            ? "checkmark.square.fill"
            : "square"
    )
    .foregroundColor(
        isSelected
            ? Color(hex: "8E81F6")
            : Color(hex: "6E6E82")
    )
}
.buttonStyle(.plain)
.disabled(selectionDisabled)
.help(selectionDisabled ? "当前任务不可选择" : "选择本轮处理")
```

- [ ] **Step 4: Show automatic-pause status**

Add to `workflowBanner`:

```swift
if store.didCompleteSelectedRun {
    Text("本轮所选任务已处理完成，队列已自动暂停")
        .font(.system(size: 11, weight: .semibold))
        .foregroundColor(Color(hex: "4EC9B0"))
}
```

- [ ] **Step 5: Build and inspect the UI**

Run the Task 4 build command, launch the built app, import a folder, and verify:

- the three shortcuts are visible;
- every pending row has a working checkbox;
- selecting first 20 can be manually adjusted;
- controls are disabled while a run is active;
- the start label shows the selected count.

- [ ] **Step 6: Commit the UI**

```bash
git add Sources/App/CallRecords/CallRecordBatchQueueView.swift
git commit -m "feat: add call record queue selection controls"
```

### Task 6: Verify Persistence and Backward Compatibility

**Files:**
- Modify: `Tests/CallRecordQueueCheck.swift`
- Modify: `Sources/App/CallRecords/CallRecordQueueStore.swift` only if the test exposes a defect

- [ ] **Step 1: Add a persistence check**

```swift
await MainActor.run {
    selectionStore.clearSelection()
    selectionStore.selectFirstPending(3)
}
let persistedIDs = await MainActor.run { selectionStore.selectedJobIDs }

let restoredStore = await MainActor.run {
    CallRecordQueueStore(storageKey: selectionKey)
}
assertEqual(
    await MainActor.run { restoredStore.selectedJobIDs },
    persistedIDs,
    "selection persists across store recreation"
)
assertEqual(
    await MainActor.run { restoredStore.isActive },
    false,
    "restored selection does not auto start"
)
```

- [ ] **Step 2: Verify RED or GREEN appropriately**

Run the Task 1 command.

Expected: PASS if Task 2 persistence is correct. If it fails, change only `loadSelection`, `saveSelection`, or `pruneSelection` until the restored set matches.

- [ ] **Step 3: Run all standalone call-record checks**

```bash
swiftc Sources/App/CallRecords/CallRecordModels.swift \
  Tests/CallRecordParserCheck.swift \
  -o /tmp/call-record-parser-check &&
/tmp/call-record-parser-check

swiftc -parse-as-library \
  Sources/App/CallRecords/CallRecordBatchWorkflow.swift \
  Tests/CallRecordBatchWorkflowCheck.swift \
  -o /tmp/call-record-batch-workflow-check &&
/tmp/call-record-batch-workflow-check

swiftc Sources/App/CallRecords/CallRecordModels.swift \
  Sources/App/CallRecords/CallRecordArchiveWriter.swift \
  Tests/CallRecordArchiveCheck.swift \
  -o /tmp/call-record-archive-check &&
/tmp/call-record-archive-check
```

Expected: all commands exit 0.

- [ ] **Step 4: Commit persistence coverage**

```bash
git add Tests/CallRecordQueueCheck.swift Sources/App/CallRecords/CallRecordQueueStore.swift
git commit -m "test: cover call record selection persistence"
```

### Task 7: Update Documentation and Package the App

**Files:**
- Modify: `README.md`
- Modify: `SPEC.md`
- Create: `dist/VoiceScribe-1.0.0-beta-selected-batch-20260615.pkg`

- [ ] **Step 1: Document the user workflow**

Add this behavior to the batch section:

```markdown
- 导入大量录音后，可使用“全选”“取消全选”“选择前 20 条”，也可逐条勾选。
- 点击“开始所选”后只处理本轮所选任务；运行期间选择范围被冻结。
- 所选任务全部完成、失败或取消后队列自动暂停，未选择任务保持等待。
```

- [ ] **Step 2: Document the scheduling contract in SPEC**

Record that selection is persisted separately, active snapshots do not survive restart, and `nextPendingJob()` may only return IDs from the active snapshot.

- [ ] **Step 3: Run final verification**

```bash
git diff --check
python3 -m unittest Tests/test_voiceprint.py -v
uv run --project Server --dev python -m pytest Server/tests -q
xcodebuild \
  -project VoiceScribe.xcodeproj \
  -scheme VoiceScribe \
  -configuration Release \
  -derivedDataPath ./build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Expected: diff check passes, Python tests pass, Server tests pass, and Release build succeeds.

- [ ] **Step 4: Sign and package without installing**

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
  dist/VoiceScribe-1.0.0-beta-selected-batch-20260615.pkg
```

- [ ] **Step 5: Inspect package contents**

```bash
pkgutil --payload-files \
  dist/VoiceScribe-1.0.0-beta-selected-batch-20260615.pkg |
rg 'VoiceScribe.app/Contents/(MacOS/VoiceScribe|Resources/transcribe.py|Resources/summarize.py|Info.plist)'
shasum -a 256 \
  dist/VoiceScribe-1.0.0-beta-selected-batch-20260615.pkg
```

Expected: all four required paths are present and a SHA-256 digest is printed.

- [ ] **Step 6: Commit docs separately**

```bash
git add README.md SPEC.md \
  docs/superpowers/specs/2026-06-15-call-record-manual-selection-design.md \
  docs/superpowers/plans/2026-06-15-call-record-manual-selection.md
git commit -m "docs: specify selected call record batch runs"
```

## Manual Acceptance Scenario

1. Import at least 25 valid recordings and several recordings shorter than 10 seconds.
2. Confirm none are selected automatically.
3. Click `选择前 20 条`; verify exactly 20 pending jobs are checked.
4. Uncheck the first job and check the twenty-first pending job; verify count remains 20.
5. Click `开始所选 (20)`.
6. Confirm selection controls and row checkboxes are disabled.
7. Confirm each selected job follows `转写 → AI 整理 → 归档`.
8. Confirm unselected jobs never leave `等待中`.
9. Allow all selected jobs to reach completed/failed/cancelled terminal states.
10. Confirm the banner says the selected run is complete and automatically paused.
11. Click `选择前 20 条` again; verify it replaces the old selection with the earliest remaining pending jobs.
