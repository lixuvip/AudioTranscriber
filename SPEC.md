# VoiceScribe - 项目规格

## 1. 项目概述

**名称:** VoiceScribe
**Bundle Identifier:** com.voicescribe.app
**Core Functionality:** 本地优先音频转写工具，支持 FunASR / VibeVoice MLX / Whisper MLX / Qwen3-ASR 多引擎、自动说话人分离、通话记录批量队列、LLM 摘要、AI 洞察，以及可选 Mac mini VoiceScribe Server / AllServes relay 远程执行
**Target Users:** 需要转录会议、访谈、播客的用户
**macOS Version:** macOS 13.0+
**Architecture:** SwiftUI (View) + Python (Backend via Process) + optional FastAPI-style VoiceScribe Server

---

## 2. UI/UX 规格

### Window 结构
- **Main Window**: 三栏布局，左侧导航栏 + 主工作区
- **Window Style**: NSWindow 带标题栏，可缩放

### 导航

侧边栏 `SidebarView` 支持五个标签页：
| 标签 | 功能 |
|------|------|
| 工作区 (workspace) | 文件拖拽、转写、波形可视化、AI 洞察 |
| 批量队列 (batchQueue) | 通话记录文件批量导入、过滤、排队转写与归档 |
| 编辑器 (editor) | 转写结果文本编辑 |
| 历史 (history) | 转写历史记录搜索与查看 |
| 设置 (settings) | 引擎/Python/LLM 模型配置 |

### 视觉设计

**配色方案:**
- Background: `#1E1E2E` (深色主背景)
- Surface: `#2A2A3C` (卡片/面板)
- Primary: `#7C6FE3` / `#8E81F6` (主色调，按钮高亮)
- Secondary: `#4EC9B0` (成功/进度)
- Accent: `#F5A623` (警告/下载)
- Text Primary: `#FFFFFF`
- Text Secondary: `#A0A0B0`
- Border: `#3A3A4C`

**字体:**
- 标题: SF Pro Display Bold 18pt
- 正文: SF Pro Text Regular 13pt
- 代码/路径: SF Mono Regular 12pt

**间距:**
- 页面边距: 24pt
- 卡片内边距: 16pt
- 元素间距: 12pt
- 圆角: 12pt (卡片), 8pt (按钮)

### 视图层级

```
┌────────────┬──────────────────────────────────────┐
│  Sidebar   │        Main Workspace                │
│            │                                      │
│  🎙 徽标   │  ┌─ 标签页切换 ───────────────────┐  │
│  VoiceScribe│  │ [工作区] [队列] [编辑器] [历史] [设置] │  │
│  V1.0-BETA │  └────────────────────────────────┘  │
│            │                                      │
│  ▶ 新转写  │  ┌─ 文件拖拽区 ──────────────────┐  │
│            │  │  拖入音频文件 或 点击选择       │  │
│  ────────  │  └────────────────────────────────┘  │
│  导航      │                                      │
│  📝 工作区 │  ┌─ 波形可视化 ──────────────────┐  │
│  📦 队列   │  │  ▁▃▅▇▆▄▂▁▃▅▇▆▄▂ (动画)      │  │
│  ✏️ 编辑器 │  └────────────────────────────────┘  │
│  📋 历史   │                                      │
│  ⚙️ 设置   │  ┌─ AI 洞察面板 ─────────────────┐  │
│            │  │ [会议纪要] [行动项] [宣发文案]  │  │
│  ────────  │  └────────────────────────────────┘  │
│  状态      │                                      │
│  ● 就绪    │  ┌─ 转写日志/进度 ───────────────┐  │
│  CPU 32%   │  │  实时日志 + 进度条 + ETA      │  │
│  MEM 48%   │  └────────────────────────────────┘  │
└────────────┴──────────────────────────────────────┘
```

---

## 3. 功能规格

### 3.1 引擎与模型

**转写引擎:**
| 引擎 | 默认模型 | 可用模型变体 | 平台 |
|------|----------|-------------|------|
| FunASR + cam++ | `paraformer-zh + cam++` | `iic/speech_SenseVoiceSmall`, `FunAudioLLM/Fun-ASR-Nano-2512` | Mac / Windows |
| VibeVoice MLX | `mlx-community/VibeVoice-ASR-4bit` | 同上 | Apple Silicon |
| Whisper MLX | `mlx-community/whisper-large-v3-turbo` | `mlx-community/whisper-large-v3-mlx`, `mlx-community/whisper-medium-mlx-8bit`, `mlx-community/whisper-small-mlx-8bit` | Apple Silicon |
| Qwen3-ASR | `Qwen/Qwen3-ASR-0.6B` | `Qwen/Qwen3-ASR-1.7B` | Apple Silicon |

**LLM 模型:**
- 用户自行添加，支持 OpenAI Compatible / OpenAI Responses / Anthropic Messages 三种接口形态
- 配置包含：名称、Model ID、API Base URL、API Key
- 持久化到 UserDefaults，支持多模型切换
- 记住上次摘要使用的模型 (`lastSummaryModelID`)

### 3.2 环境检测与预热

- 启动时显示 SetupView，可选跳过
- 自动检测: `ffmpeg`, `python3`, 引擎依赖包, 模型缓存
- 三引擎各自有独立的依赖检查：
  - FunASR: `funasr`, `modelscope`
  - VibeVoice MLX: `mlx-audio`, `huggingface_hub`
  - Whisper MLX: `mlx-whisper`, `huggingface_hub`
  - Qwen3-ASR: `mlx-qwen3-asr`, `huggingface_hub`, `pyannote.audio`
- 缺失时显示警告 + 一键安装按钮
- 安装日志实时流式输出
- 环境检测只检查本地包与模型缓存；大模型下载由用户在 App 安装/下载流程中手动触发。
- `hfToken` 持久化用于下载 HuggingFace 门控模型（pyannote）

### 3.3 性能管理

- 根据 CPU 核心数、内存大小自动推荐性能档位（低 / 中 / 高）
- 各引擎在不同档位下的内存阈值动态调整
- 转写前内存预检（`checkAvailableMemory`），不足时自动降级或警告
- 转写中周期性内存监控（`memoryMonitorTimer`）
- 限制 PyTorch 线程数，设置 `OMP_NUM_THREADS`、`MKL_NUM_THREADS` 等
- 档位选择持久化，下次启动自动恢复

### 3.4 转写功能

- 调用 Python 脚本 `Scripts/transcribe.py`，传入引擎/模型/性能参数
- Python 端输出结构化 JSON 进度（`type: "progress"`），Swift 端解析
- 实时读取 stdout 展示日志，显示百分比进度和 ETA
- 支持中途停止转写（`didRequestStop`）
- 转写完成卡片摘要：引擎、模型 ID、耗时、说话人数、segment 数

### 3.4.1 远程执行与 AllServes relay

- 执行目标支持本机、直连 Mac mini VoiceScribe Server、All Service / AllServes relay。
- 远程接口契约以 `docs/remote_allserves_integration.md` 为准。
- 创建远程任务时，`engine`、`model_id`、`device`、`threads`、`batch_size_s`、`merge_length_s`、`speaker_diarization`、`hf_token` 必须放在 `arguments` 中。
- relay 模式可使用顶层 `service: "voicescribe"` 作为路由元数据，但不能把转写参数移到顶层字段。
- `hf_token` 只作为运行参数传递给 Qwen3-ASR / pyannote 子进程，不得在日志、文档、提交或错误消息中暴露真实值。
- 远程完成后 App 优先按结果 manifest 的 `category` 加载 `transcript`、`speaker_text`、`speaker_map`，再回退到 `*_通话记录.md`、`*_整理版.md`、`*_speaker_map.json` 命名。
- 远程和 relay 开发不得在健康检查或普通验证中自动下载大模型、门控模型或付费资源；依赖由用户手动配置，或在 App 明确点击安装/下载流程时触发。

### 3.4.2 通话记录批量队列

- 通话记录批量功能独立放在 `Sources/App/CallRecords/`，不要和普通单文件工作区逻辑混成一个视图。
- 支持导入多个文件或一个文件夹，递归扫描 `m4a`、`mp3`、`wav`、`mp4`、`mov`、`aac`、`flac`。
- 文件名解析规则：
  - `联系人@号码_yyyyMMddHHmmss`
  - `号码_yyyyMMddHHmmss`
- 号码规范化时只保留数字；联系人不存在时使用原始号码作为展示名。
- 导入阶段读取音频时长，少于 10 秒的录音标记为 `ignored`，不进入转写队列。
- 队列串行执行，每条按 `转写中 -> AI 整理中 -> 归档完成` 推进；当前条目的 `_摘要.md` 成功生成后才调度下一条。
- 批量转写使用独立运行上下文，说话人数据就绪时不得触发自动导航到交互校对；普通单文件转写保留原有自动导航。
- 开始队列前必须存在可用的自定义摘要模型。转写或摘要失败标记当前条目为 `failed` 并继续后续条目；用户停止则暂停队列并将当前条目标记为 `cancelled`。
- 队列状态持久化到 UserDefaults；App 退出时处于 `running` 或 `summarizing` 的任务下次启动恢复为等待中。
- 默认归档根目录为源文件所在目录下的 `VoiceScribe_CallRecords`；若用户设置自定义输出目录，则归档在该目录下。
- 每条已完成通话输出到 `Calls/yyyy/yyyy-MM/yyyyMMdd_HHmmss_<联系人或号码>/`，必须包含转写、speaker map、整理版、AI 摘要和 `metadata.json`。
- 全局索引文件包括 `call_index.json`、`通话记录索引.md` 和按号码分组的 `Contacts/*.md`，Markdown 索引同时链接整理版与 AI 摘要。

### 3.5 音频播放

- `Transcriber` 内置 `AVAudioPlayer`，支持播放/暂停
- 播放速度可调（`playbackSpeed`）
- 播放进度与 `WaveformVisualizer` 波形动画联动
- 转写前自动获取音频时长（`ffprobe`）

### 3.6 AI 洞察面板

`AIInsightsPanel` 提供三个维度的后处理：
| Tab | 功能 |
|-----|------|
| 会议纪要 (Minutes) | 结构化会议纪要生成 |
| 行动项 (Actions) | 待办事项清单 + 勾选 |
| 宣发文案 (Social) | 社交媒体文案生成 |

### 3.7 LLM 模型管理

- 设置面板中 `AddModelSheet` 添加自定义模型
- 模型卡片式展示：名称、ID、提供商类型、选中状态
- 支持删除模型
- 自定义摘要提示词（`summaryPrompt`）

### 3.8 历史管理

- 转写完成后自动记录到历史（最多 200 条）
- 标签页切换查看，支持搜索
- 展开查看输出文件，可单独打开或打开目录

---

## 4. 技术规格

### 前端 (SwiftUI)

| 文件 | 职责 |
|------|------|
| `AudioTranscriberApp.swift` | @main 入口 |
| `ContentView.swift` | 三栏布局 + 标签页路由 + 转写/播放/AI 洞察 |
| `SetupView.swift` | 首次设置向导：引擎选择、环境预热、性能档位 |
| `EnvironmentChecker.swift` | 环境检测、依赖安装、性能推荐、内存预检 |
| `Transcriber.swift` | 转写 Process 管理、音频播放、进度/ETA/内存监控 |
| `SettingsManager.swift` | UserDefaults 持久化：引擎/模型/LLM/HF Token/性能档位 |
| `TranscriptionHistoryEntry.swift` | 历史记录 Codable 模型 |
| `Color+Hex.swift` | 十六进制颜色扩展 |

**通话记录模块 (CallRecords/):**
| 文件 | 职责 |
|------|------|
| `CallRecordModels.swift` | 通话记录元数据、文件名解析、队列任务状态 |
| `CallRecordBatchWorkflow.swift` | 单文件/批量运行上下文和转写后动作策略 |
| `CallRecordQueueStore.swift` | 导入、10 秒过滤、队列状态、持久化、任务调度选择 |
| `CallRecordArchiveWriter.swift` | 每条通话 metadata、全局索引、联系人分组页 |
| `CallRecordBatchQueueView.swift` | 批量任务标签页 UI |

**组件 (Components/):**
| 文件 | 职责 |
|------|------|
| `SidebarView.swift` | 左侧导航栏：徽标、标签页切换、环境状态、系统监控 |
| `WaveformVisualizer.swift` | 波形可视化：动画 Capsule 柱状图 |
| `AIInsightsPanel.swift` | AI 洞察：纪要/行动项/宣发三 Tab |
| `StatusCard.swift` | 环境依赖状态徽章 + 性能档位选择器 |
| `SettingsPanel.swift` | 设置面板：引擎/模型 ID/Python/LLM 管理/摘要提示 |
| `FileDropZone.swift` | 文件拖拽区域 |
| `LogView.swift` | 实时日志输出 |
| `ButtonStyles.swift` | 统一样式按钮 |
| `FolderPicker.swift` / `FolderPickerSheet.swift` | 目录选择器 |

### 后端脚本 (Python)

| 脚本 | 职责 |
|------|------|
| `Scripts/transcribe.py` | 三引擎转写核心：FunASR (paraformer-zh + cam++), VibeVoice MLX, Qwen3-ASR。结构化进度输出。 |
| `Scripts/summarize.py` | LLM 摘要生成，支持 OpenAI Compatible / Anthropic Messages 协议 |

### 远程接口

| 文档 | 职责 |
|------|------|
| `docs/remote_allserves_integration.md` | Mac mini VoiceScribe Server 与 AllServes relay 的请求字段、响应字段、结果文件、错误处理、说话人区分依赖和安全边界 |

### 数据流

1. 用户选择音频 → Swift 传路径 + 引擎 + 模型 ID + 性能参数给 Python
2. Python 执行转写 → stdout 输出结构化 JSON 进度 + 日志
3. Swift 解析进度 → 更新进度条、ETA、波形动画
4. 转写完成 → 写 JSON + Markdown + 说话人映射文件
5. 普通单文件由用户点摘要 / AI 洞察；批量通话由队列在每条转写后自动调用已配置 LLM
6. 批量摘要成功后写入归档索引并调度下一条，结果同时录入历史

### SettingsManager 持久化键

| UserDefaults 键 | 类型 | 说明 |
|-----------------|------|------|
| `transcriptionEngine` | String | 引擎 rawValue |
| `transcriptionModelID` | String | 模型 ID |
| `runtimeEnvironment` | String | 环境 rawValue |
| `pythonPath` | String | Python 路径 |
| `hfToken` | String | HuggingFace Token |
| `customModels` | JSON Data | LLM 模型数组 |
| `selectedModel` | String | 当前选中的 LLM 模型 ID |
| `lastSummaryModelID` | String | 上次摘要使用的模型 |
| `summaryPrompt` | String | 自定义摘要提示词 |
| `performanceTier` | String | 性能档位 rawValue |

### 性能档位对照

| 档位 | 线程 | batch | merge | FunASR 内存 | VibeVoice 内存 | Qwen3 内存 |
|------|------|-------|-------|------------|---------------|-----------|
| 低   | 1-2  | 60s   | 10s   | 2.5 GB     | 4.0 GB        | 2.5 GB    |
| 中   | 2-4  | 90s   | 12s   | 4.0 GB     | 6.0 GB        | 4.0 GB    |
| 高   | 2-6  | 120s  | 15s   | 6.0 GB     | 10.0 GB       | 8.0 GB    |

---

## 5. 验收标准

- [ ] 启动后自动检测三引擎依赖，缺失项明确提示
- [ ] 拖拽音频文件到窗口能正确识别
- [ ] 转写过程有实时进度日志和百分比输出
- [ ] 转写结果保存为 JSON + Markdown + 说话人映射文件
- [ ] 音频播放器可播放/暂停/调速，波形动画联动
- [ ] AI 洞察面板三个 Tab 内容正确生成
- [ ] 摘要功能使用自定义 LLM 模型
- [ ] 侧边栏标签页切换正常，环境状态实时更新
- [ ] 设置中的引擎/模型选择正确联动
- [ ] 远程模式和 AllServes relay 创建任务时转写参数保持在 `arguments`，结果文件能按 `category` 或标准命名加载
- [ ] 通话记录批量队列能解析 `联系人@号码_yyyyMMddHHmmss` 和 `号码_yyyyMMddHHmmss`，少于 10 秒录音自动忽略
- [ ] 通话记录队列按通话时间串行执行，每条依次完成转写、AI 摘要和归档，批量期间不自动跳转交互校对
- [ ] 转写前内存预检在低内存时自动降级并提示
- [ ] UI 符合深色主题规格
- [ ] 可打包为 .app 分发
