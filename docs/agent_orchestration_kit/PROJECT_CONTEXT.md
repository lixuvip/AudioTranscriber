# Project Context

## 基本信息

| 字段 | 内容 |
| --- | --- |
| 项目名称 | VoiceScribe / VibeVoiceSTT |
| 仓库路径 | `/Users/sirius/Documents/Codex_Project/VibeVoiceSTT` |
| 默认主分支 | `main` |
| 当前工作分支 | `feat/relay-api-client` |
| 项目负责人 | Coordinator / PM |
| 主要用户 | 需要本地转录会议、访谈、播客、语音资料的 macOS 用户 |
| 产品目标 | 提供本地优先的音频转写、说话人识别、历史管理和 AI 摘要工作流 |

## 技术栈

| 层级 | 技术 |
| --- | --- |
| 前端 | SwiftUI + AppKit, macOS 13+ |
| 后端 | Python scripts via `Process`, optional FastAPI-style server components |
| 数据库 | Server-side storage modules under `Server/voicescribe_server/` when server mode is involved |
| 测试 | Python `unittest`, Xcode build verification |
| 构建 / 打包 | XcodeGen, `xcodebuild`, `Tools/package_macos_app.sh` |
| 部署 | Local macOS app packaging; optional server deploy scripts under `Server/deploy/` |

## 目录边界

| 路径 | 用途 | 默认角色权限 |
| --- | --- | --- |
| `Sources/App/` | macOS SwiftUI app, settings, transcription state, UI components | Engineer editable only when assigned; QA/Reviewer read-only |
| `Scripts/` | Python transcription, summarization, voiceprint tooling | Engineer editable only when assigned |
| `Server/` | Optional server application, worker, tests, deploy assets | Engineer editable only for server-scoped tasks |
| `Tests/` | Python tests for local scripts | Engineer editable for test-scoped tasks |
| `docs/` | Project docs and orchestration docs | Release/Docs editable when assigned |
| `project.yml` | XcodeGen project definition | Engineer editable only when Swift source layout changes |
| `VoiceScribe.xcodeproj/` | Generated Xcode project | Regenerate through XcodeGen when needed; avoid manual edits |

## 分支与工作区策略

| 场景 | 策略 |
| --- | --- |
| 产品设计 | Read-only or design branch |
| 技术开发 | Prefer feature branch or isolated worktree |
| QA 测试 | Read-only checkout or QA worktree |
| 代码审查 | Read-only |
| 发布准备 | Release/docs branch when packaging or docs updates are needed |

## 常用验证命令

按任务范围选择最小必要验证。

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

```bash
xcodegen generate
```

For server-specific work, choose focused tests under `Server/tests/`.

## 禁止事项

未经用户明确批准，任何角色都不能执行：

- 粘贴、读取、外传 API Key、Hugging Face Token、私有证书、生产凭据。
- 下载大模型、门控模型、付费资源或高成本资源。
- 生产部署、强推、仓库重置、批量清理文件。
- 回滚用户或其他对话已有的未提交改动。
- 修改任务范围之外的业务规则、API 合约或数据结构。

## 项目特有注意事项

- 模型相关工作默认采用检查、报告、手动安装文档，不自动下载。
- 新增或删除 Swift 源文件时，必须同步 `project.yml` 并运行 `xcodegen generate`。
- `Sources/App/` 中 UI、设置和转写状态耦合较多，避免无关重构。
- QA 和 Code Reviewer 默认只读。
