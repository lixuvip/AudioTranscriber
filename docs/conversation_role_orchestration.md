# VoiceScribe Conversation Orchestration Adapter

**Date:** 2026-06-13
**Project:** VoiceScribe / VibeVoiceSTT
**Source of truth:** `docs/agent_orchestration_kit/`

This document adapts the generic Agent Orchestration Kit to this repository. The generic role protocol, reply format, workflow rules, task board format, and role definitions live in `docs/agent_orchestration_kit/`. Do not maintain a second competing protocol here.

## How To Use This Project Adapter

1. Read `docs/agent_orchestration_kit/README.md`.
2. Fill project-specific copies from the kit templates:
   - `PROJECT_CONTEXT.template.md` -> `PROJECT_CONTEXT.md`
   - `ROLE_REGISTRY.template.md` -> `ROLE_REGISTRY.md`
   - `TASK_BOARD.template.md` -> `TASK_BOARD.md`
3. Use `templates/task_dispatch.template.md` for each role assignment.
4. Require role replies to follow `templates/role_reply.template.md`.
5. Use this file only for VoiceScribe-specific constraints and verification commands.

## Project Context

| Field | Value |
| --- | --- |
| Project name | VoiceScribe / VibeVoiceSTT |
| Repository path | `/Users/sirius/Documents/Codex_Project/VibeVoiceSTT` |
| Current observed branch | `feat/relay-api-client` |
| App type | macOS SwiftUI app with Python transcription backend and optional server components |
| Main risk areas | local model setup, Python environment detection, Swift/XcodeGen project sync, audio transcription workflow, API keys and tokens |

## Role Registry Seed

Use this as the initial content for `ROLE_REGISTRY.md`, then replace placeholders with real thread IDs.

| Role | Thread ID | Working mode | Responsibilities | Boundaries | Current status |
| --- | --- | --- | --- | --- | --- |
| Coordinator / PM | current thread | Main control thread | Break down work, assign role tasks, inspect replies, route next steps, final acceptance. | Do not publish unverified role output. Do not merge unknown changes. | Active |
| Product Designer | `<PRODUCT_THREAD_ID>` | Read-only or design branch | Clarify UX, user flow, visible states, acceptance criteria. | No production code changes. No backend/API contract changes. | `<ACTIVE_OR_INACTIVE>` |
| Technical Engineer | `<ENGINEER_THREAD_ID>` | Separate worktree / feature branch | Implement scoped changes, update tests/docs, run verification. | Only edit assigned files. Do not download models or change product scope without approval. | `<ACTIVE_OR_INACTIVE>` |
| QA Tester | `<QA_THREAD_ID>` | Read-only checkout or QA worktree | Run validation, reproduce issues, report blockers. | Do not silently fix code unless assigned a QA-fix task. | `<ACTIVE_OR_INACTIVE>` |
| Code Reviewer | `<REVIEW_THREAD_ID>` | Read-only checkout | Review diffs for correctness, regressions, maintainability, and test gaps. | Review by default; do not rewrite implementation unless reassigned. | `<ACTIVE_OR_INACTIVE>` |
| Release / Docs | `<RELEASE_THREAD_ID>` | Docs or release branch | Update user docs, changelog, packaging notes, release checklist. | Do not modify feature implementation. | `<ACTIVE_OR_INACTIVE>` |

## VoiceScribe-Specific Boundaries

These rules should be copied into task dispatches when relevant.

- Do not paste or request API keys, Hugging Face tokens, private certificates, or production credentials.
- Do not auto-download large, gated, or paid models unless the user explicitly approves it.
- Model-related work should default to check/report/manual-install documentation.
- If new Swift source files are added or removed, update `project.yml` and regenerate the Xcode project.
- Avoid unrelated refactors in `Sources/App/` because UI and transcription state are tightly coupled.
- Use separate worktrees/branches for implementation roles when more than one role may inspect or test code.
- QA and Code Reviewer roles are read-only by default.
- Existing uncommitted user changes must not be reverted.

## Common Verification Commands

Use the smallest verification that matches the task.

```bash
python3 -m unittest Tests/test_voiceprint.py -v
```

```bash
xcodebuild \
  -project VoiceScribe.xcodeproj \
  -scheme VoiceScribe \
  -configuration Debug \
  -derivedDataPath ./build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

If Swift files are added or removed:

```bash
xcodegen generate
```

For server work, choose focused tests under `Server/tests/` before broader validation.

## Recommended Workflow For This Repository

Default to the kit's sequential gate mode for user-facing behavior:

```text
User request
-> Coordinator scope review
-> Product Designer acceptance criteria when UX is unclear
-> Technical Engineer implementation
-> Coordinator scope/diff review
-> QA validation
-> Code Reviewer final risk review
-> Coordinator final delivery
```

Use parallel preparation only when roles are not editing the same files:

- Product Designer can draft acceptance criteria.
- QA Tester can draft a test matrix.
- Technical Engineer can investigate implementation options without code edits.

Do not use parallel role execution for the same SwiftUI or transcription-state files unless each role has isolated worktree state and explicit scope.

## Dispatch Reminder

Every role task should use the generic dispatch template and include this project context where relevant:

```text
Project: VoiceScribe / VibeVoiceSTT
Repository: /Users/sirius/Documents/Codex_Project/VibeVoiceSTT
Project-specific constraints:
- Do not download large/gated models without explicit approval.
- Do not expose API keys or tokens.
- Preserve existing uncommitted user changes.
- If Swift source files change, keep project.yml and XcodeGen output in sync.
```

