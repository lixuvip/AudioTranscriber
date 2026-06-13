# VoiceScribe 对话角色编排适配说明

**日期：** 2026-06-13
**项目：** VoiceScribe / VibeVoiceSTT
**通用规则来源：** `docs/agent_orchestration_kit/`

本文档只负责说明这套通用编排规则在 VoiceScribe 项目里的具体用法。角色定义、任务下发模板、回复格式、任务看板和工作流，以 `docs/agent_orchestration_kit/` 的新版文档为准。不要在这里维护第二套重复协议。

## 使用方式

1. 先读 `docs/agent_orchestration_kit/README.md`。
2. 从模板复制并填写项目文件：
   - `PROJECT_CONTEXT.template.md` -> `PROJECT_CONTEXT.md`
   - `ROLE_REGISTRY.template.md` -> `ROLE_REGISTRY.md`
   - `TASK_BOARD.template.md` -> `TASK_BOARD.md`
3. 给每个角色对话发送 `roles/*.md` 中对应的角色说明。
4. 每次派发任务时使用 `templates/task_dispatch.template.md`。
5. 要求角色按 `templates/role_reply.template.md` 回复。
6. 本文件只补充 VoiceScribe 项目特有的边界和验证命令。

## 项目上下文

| 字段 | 内容 |
| --- | --- |
| 项目名称 | VoiceScribe / VibeVoiceSTT |
| 仓库路径 | `/Users/sirius/Documents/Codex_Project/VibeVoiceSTT` |
| 当前观察到的分支 | `feat/relay-api-client` |
| 项目类型 | macOS SwiftUI 应用 + Python 转写后端 + 可选服务端组件 |
| 主要风险 | 本地模型配置、Python 环境检测、Swift/XcodeGen 同步、音频转写流程、API Key 和 Token |

## 角色登记表初始内容

正式启用时，把下面内容复制到 `ROLE_REGISTRY.md`，再填入真实对话 ID。

| 角色 | 对话 ID | 工作模式 | 职责 | 边界 | 当前状态 |
| --- | --- | --- | --- | --- | --- |
| Coordinator / PM | 当前对话 | 主控对话 | 拆解任务、分配角色、检查交付、最终验收。 | 不发布未验证结果；不合并不明来源改动。 | Active |
| Product Designer | `<PRODUCT_THREAD_ID>` | 只读或设计分支 | 需求澄清、用户流程、交互状态、验收标准。 | 不直接实现生产代码；不擅自改 API 合约。 | `<ACTIVE_OR_INACTIVE>` |
| Technical Engineer | `<ENGINEER_THREAD_ID>` | 独立 worktree / 功能分支 | 实现代码、补测试、跑验证、提交工程交付。 | 只改任务指定范围；不擅自扩大需求；未经批准不下载模型。 | `<ACTIVE_OR_INACTIVE>` |
| QA Tester | `<QA_THREAD_ID>` | 只读 checkout 或 QA worktree | 执行测试、复现缺陷、报告阻塞。 | 默认不修代码；不改变实现。 | `<ACTIVE_OR_INACTIVE>` |
| Code Reviewer | `<REVIEW_THREAD_ID>` | 只读 checkout | 审查 diff、找风险、评估测试缺口。 | 默认只评论不改代码。 | `<ACTIVE_OR_INACTIVE>` |
| Release / Docs | `<RELEASE_THREAD_ID>` | 发布分支或文档分支 | 更新 changelog、用户文档、发布检查清单。 | 不修改功能实现。 | `<ACTIVE_OR_INACTIVE>` |

## VoiceScribe 特有边界

下发任务时，按需把这些项目约束复制进任务上下文：

- 不要粘贴或请求 API Key、Hugging Face Token、私有证书、生产凭据。
- 未经用户明确批准，不要自动下载大模型、门控模型或付费资源。
- 模型相关任务默认采用“检查 / 报告 / 手动安装文档”的方式。
- 如果新增或删除 Swift 源文件，需要同步 `project.yml` 并重新生成 Xcode 工程。
- `Sources/App/` 里的 UI 和转写状态耦合较多，避免无关重构。
- 多角色并行检查同一批代码时，技术实现角色应使用独立 worktree / 分支。
- QA 和 Code Reviewer 默认只读。
- 不要回滚用户或其他对话已经存在的未提交改动。

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

如果新增或删除 Swift 源文件：

```bash
xcodegen generate
```

如果是服务端相关工作，优先运行 `Server/tests/` 下的聚焦测试，再考虑更大范围验证。

## 推荐流程

对用户可见行为，默认采用新版 kit 中的“顺序门禁模式”：

```text
用户需求
-> 协调者确认范围
-> 产品设计师补充验收标准（当 UX 不清楚时）
-> 技术工程师实现
-> 协调者检查 diff 和范围
-> QA 验证
-> Code Reviewer 最终风险审查
-> 协调者交付用户
```

只有在角色不编辑同一批文件时，才使用并行准备模式：

- 产品设计师写验收标准。
- QA 设计测试矩阵。
- 技术工程师只做实现方案调研，暂不改代码。

不要让多个角色同时改同一批 SwiftUI 或转写状态文件，除非每个角色都有隔离的 worktree 和明确边界。

## 派发任务时的项目上下文提醒

每次给角色下发任务，仍然使用通用模板，但建议加入：

```text
项目：VoiceScribe / VibeVoiceSTT
仓库：/Users/sirius/Documents/Codex_Project/VibeVoiceSTT
项目约束：
- 未经明确批准，不下载大模型或门控模型。
- 不暴露 API Key、Token 或私有凭据。
- 保留已有未提交改动，不要回滚他人工作。
- 如果 Swift 源文件变化，保持 project.yml 和 XcodeGen 输出同步。
```
