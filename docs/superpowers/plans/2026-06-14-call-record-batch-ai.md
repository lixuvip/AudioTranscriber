# Call Record Batch AI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make call-record batches transcribe, summarize, and archive each item sequentially without navigating away from the batch page.

**Architecture:** A small workflow policy distinguishes interactive and batch runs. `Transcriber` publishes separate transcription and summarization results, while `ContentView` advances the persisted call-record queue only after the current phase finishes. The queue owns visible states and recovery; the archive writer records only fully summarized items.

**Tech Stack:** Swift, SwiftUI, Combine, AVFoundation, Foundation process execution, Xcode.

---

### Task 1: Batch Workflow Policy

**Files:**
- Create: `Sources/App/CallRecords/CallRecordBatchWorkflow.swift`
- Create: `Tests/CallRecordBatchWorkflowCheck.swift`

- [ ] Write checks proving interactive runs may open the editor, batch runs may not, successful transcription requires summarization, and missing summary configuration blocks the workflow.
- [ ] Compile the check before implementation and confirm it fails because the workflow types do not exist.
- [ ] Implement the minimal policy types and rerun the check.

### Task 2: Queue State Transitions

**Files:**
- Modify: `Sources/App/CallRecords/CallRecordModels.swift`
- Modify: `Sources/App/CallRecords/CallRecordQueueStore.swift`
- Modify: `Tests/CallRecordQueueCheck.swift`

- [ ] Add a failing check for `running -> summarizing -> completed`.
- [ ] Add the `summarizing` status, transition method, active-job lookup, and restart recovery.
- [ ] Rerun the queue check and confirm all duration-filter behavior remains unchanged.

### Task 3: Transcription and Summary Results

**Files:**
- Modify: `Sources/App/Transcriber.swift`
- Modify: `Sources/App/ContentView.swift`

- [ ] Add an explicit run context to transcription starts.
- [ ] Publish summarization success, failure, and cancellation separately from transcription results.
- [ ] Route batch transcription success into summary generation and route summary completion into archive writing.
- [ ] Keep interactive navigation limited to interactive runs.

### Task 4: Batch UI and Archive

**Files:**
- Modify: `Sources/App/CallRecords/CallRecordBatchQueueView.swift`
- Modify: `Sources/App/CallRecords/CallRecordArchiveWriter.swift`
- Modify: `Tests/CallRecordArchiveCheck.swift`

- [ ] Show the selected summary model and `AI 整理中` state.
- [ ] Disable queue start when no summary model is configured.
- [ ] Link `_摘要.md` from the global index and contact pages.
- [ ] Run the archive check and confirm summary metadata and links are present.

### Task 5: Documentation and Verification

**Files:**
- Modify: `README.md`
- Modify: `SPEC.md`
- Modify: `VoiceScribe.xcodeproj/project.pbxproj`

- [ ] Document the serial transcription-plus-summary workflow and no-navigation behavior.
- [ ] Add new Swift sources to the Xcode project.
- [ ] Run all standalone Swift checks, `git diff --check`, and a clean Debug build.
- [ ] Re-run the real directory import check against `/Users/sirius/Desktop/test` without downloading models.
