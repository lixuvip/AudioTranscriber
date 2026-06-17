# VoiceScribe

macOS 本地优先音频转写工具。支持 FunASR + cam++、VibeVoice MLX、Whisper MLX 和 Qwen3-ASR 多引擎，自动说话人分离，LLM 摘要生成，转写历史管理。默认在本机处理音频；也可以显式切换到自有 Mac mini VoiceScribe Server 或 All Service / AllServes relay。

## 依赖的开源项目

本项目的核心转写能力来自以下开源项目，感谢它们的作者和社区：

| 项目 | 说明 | 链接 |
|------|------|------|
| **FunASR** | 通义语音团队出品的端到端语音识别工具包，本项目使用的 `paraformer-zh` 中文 ASR 模型来自这里 | [GitHub](https://github.com/modelscope/FunASR) |
| **cam++** | FunASR 生态下的说话人验证/区分模型，用于自动识别不同说话人 | [GitHub](https://github.com/modelscope/FunASR) |
| **VibeVoice** | 基于 Apple Silicon MLX 框架的语音识别模型，提供本地高效转写能力 | [GitHub](https://github.com/VibeVoiceAI/VibeVoice) |
| **Qwen3-ASR** | 阿里通义千问团队发布的语音识别模型，支持多语言转写和说话人区分，Apple Silicon MLX 原生加速 | [ModelScope](https://www.modelscope.cn/models/Qwen/Qwen3-ASR-0.6B) |
| **mlx-audio** | Apple MLX 生态下的音频处理库，用于加载和运行 MLX 格式的语音模型 | [GitHub](https://github.com/lucasnewman/mlx-audio) |
| **mlx-whisper** | Apple MLX 官方示例生态中的 Whisper 实现，适合 Apple Silicon 本地 Whisper 转写 | [GitHub](https://github.com/ml-explore/mlx-examples/tree/main/whisper) |
| **huggingface_hub** | Hugging Face 模型下载与缓存管理 | [GitHub](https://github.com/huggingface/huggingface_hub) |

`stt` `asr` `speech-to-text` `audio-transcription` `funasr` `mlx` `cam++` `speaker-diarization` `macos` `swiftui` `python` `offline` `local` `meeting-notes` `chinese`

## 截图

启动后进入设置页面，选择引擎并预热环境：

```
┌──────────────────────────────────────────┐
│                                          │
│       🎧 VoiceScribe                │
│       本地离线音频转写 · 支持说话人识别    │
│                                          │
│  ┌────────────────────────────────────┐  │
│  │ 转写引擎                            │  │
│  │ ● VibeVoice MLX     ○ FunASR + cam++│  │
│  └────────────────────────────────────┘  │
│  ┌────────────────────────────────────┐  │
│  │ 环境预热               [预热]       │  │
│  │ ✓ ffmpeg  ✓ python  ✓ mlx-audio  ⚠ │  │
│  │ 性能档位: [低] [中] [高]             │  │
│  └────────────────────────────────────┘  │
│                                          │
│  [跳过，直接使用]          [开始使用 →]   │
└──────────────────────────────────────────┘
```

## 功能

### 转写

- 多引擎：`FunASR + cam++`（稳定中文转写 + 说话人区分）、`VibeVoice MLX`（Apple Silicon 加速）、`Whisper MLX`（Apple Silicon 上的 Whisper 中文转写）、`Qwen3-ASR`（中文方言之王，8/4-bit 量化）。
- 执行目标：本机、直连 Mac mini VoiceScribe Server、All Service / AllServes relay。远程接口契约见 `docs/remote_allserves_integration.md`。
- 拖拽或选择音频文件，支持 m4a、mp3、wav、mp4、mov、aac、flac。
- 非 WAV 格式自动通过 ffmpeg 转为 16kHz 单声道 WAV 再转写。
- 转写结果输出：原始 JSON、通话记录 Markdown、整理版文本、说话人映射 JSON。
- 多角色场景自动分配 `角色A / 角色B / 角色C`，支持在界面中重命名。
- 支持中途停止转写。
- 转写前内存预检，不足时自动降级性能档位。
- 音频播放器，支持播放速度调节和波形可视化。

### 通话记录批量队列

- 「批量任务」标签页提供独立的通话记录队列模块，支持导入多个录音文件或整个文件夹。
- 文件名格式支持 `联系人@号码_yyyyMMddHHmmss` 和 `号码_yyyyMMddHHmmss`，例如 `章文@153 9711 1188_20240826172813.m4a`、`131 0213 3750_20250813175323.m4a`。
- 导入时会读取音频时长，少于 10 秒的录音自动标记为「已忽略」，不会进入转写队列。
- 队列按通话时间执行 `转写 → AI 整理 → 归档`，当前条目生成 `_摘要.md` 后才开始下一条，避免一次性占满本机、远程服务或 LLM 配额。
- 批量运行不会自动跳转到交互校对；历史记录保留查看入口，但不需要再进入历史逐条触发 AI 整理。
- 开始队列前必须先在设置中配置摘要模型。单条转写或 AI 整理失败会记录在当前队列条目中，后续条目继续执行。
- 每条通话会写入独立输出目录，并维护全局 `call_index.json`、`通话记录索引.md` 和按号码分组的 `Contacts/*.md`；索引同时链接整理版和 AI 摘要。

### 摘要与 AI 洞察

- 用户自行添加 LLM 模型，支持多个模型并切换选择。
- 接口形态：OpenAI Compatible、OpenAI Responses、Anthropic Messages。
- 支持自定义摘要提示词，只影响摘要生成，不影响转写。
- 基于整理版文本生成摘要，输出为 `_摘要.md`。
- AI 洞察面板：会议纪要、行动项、宣发文案三个维度。

### 环境管理

- 启动后进入设置页面，先选引擎再预热，不阻塞 App 启动。
- 自动检测 ffmpeg、Python、转写引擎依赖和模型缓存。
- 自动选择已安装引擎依赖的 Python 解释器，支持手动指定。
- 缺少依赖时可从界面安装，MLX 路线会自动创建独立虚拟环境。
- Whisper MLX 的 `mlx-whisper` 依赖和模型缓存接入 App 安装/下载流程；环境检测只检查缓存，不在检测阶段下载大模型。
- 预热后根据 CPU 核心数和内存自动推荐性能档位（低 / 中 / 高）。
- 档位选择持久化，下次启动自动恢复。

### 转写历史

- 转写完成后自动记录到历史。
- 标签页切换查看历史记录，支持搜索。
- 展开查看输出文件列表，可单独打开文件或打开输出目录。
- 最多保留 200 条记录。

## 技术栈

- **前端**：SwiftUI + AppKit，macOS 13.0+，Swift 5.9
- **后端**：Python 3 脚本，通过 `Process` 子进程调用
- **转写引擎**：FunASR（paraformer-zh + cam++）/ VibeVoice MLX（mlx-audio）/ Whisper MLX（mlx-whisper）/ Qwen3-ASR
- **项目管理**：XcodeGen（project.yml）

## 项目结构

```text
VoiceScribe/
├── VoiceScribe.xcodeproj/                 # Xcode 工程（XcodeGen 生成）
├── Sources/
│   └── App/
│       ├── AudioTranscriberApp.swift      # App 入口
│       ├── ContentView.swift              # 主视图（三栏布局 + 标签页路由）
│       ├── ContentViewComponents.swift    # ContentView 抽出的自包含 UI 组件
│       ├── SetupView.swift                # 首次设置/预热页面
│       ├── EnvironmentChecker.swift       # 环境检测、性能推荐、内存预检
│       ├── Transcriber.swift              # 转写进程管理 + 音频播放
│       ├── SettingsManager.swift          # 用户设置持久化（引擎/模型/LLM/HF Token）
│       ├── HistoryView.swift              # 转写历史列表
│       ├── TranscriptionHistoryEntry.swift # 历史记录模型
│       ├── RemoteTranscriberClient.swift  # 远程/中转转写客户端
│       ├── RemoteModels.swift             # 远程接口数据模型
│       ├── VoiceprintStore.swift          # 声纹库采集/匹配/管理
│       ├── KeychainStore.swift            # 令牌等敏感信息的钥匙串存储
│       ├── Color+Hex.swift                # 颜色扩展
│       ├── CallRecords/                   # 批量队列 + 人物归档/时间线 + 原子文件存储
│       │   ├── CallRecordQueueStore.swift     # 批量队列状态与持久化
│       │   ├── CallRecordBatchWorkflow.swift  # 转写→AI整理→归档工作流
│       │   ├── PersonArchiveRepository.swift  # 人物归档读写（含电话索引）
│       │   ├── PersonTimelineStore.swift      # 人物时间线/选择草稿状态
│       │   └── AtomicJSONFileStore.swift      # 原子写入 + .backup 回退
│       └── Components/
│           ├── StatusCard.swift           # 环境状态卡片 + 性能档位选择器
│           ├── FileDropZone.swift         # 文件拖拽区
│           ├── SettingsPanel.swift        # 设置面板（引擎/Python/LLM/摘要提示）
│           ├── LogView.swift              # 日志输出
│           ├── SidebarView.swift          # 侧边导航栏（环境状态/系统监控）
│           ├── WaveformVisualizer.swift   # 波形可视化组件
│           ├── TranscriptionTimelineView.swift # 转写阶段时间线
│           ├── SilentInstallProgressCapsule.swift # 静默安装进度条
│           ├── AIInsightsPanel.swift      # AI 洞察面板（纪要/行动项/宣发）
│           └── ButtonStyles / FolderPicker*.swift # 按钮样式 / 目录选择器
├── Scripts/
│   ├── transcribe.py                      # 多引擎转写脚本（FunASR/VibeVoice MLX/Whisper MLX/Qwen3）
│   ├── voiceprint.py                      # 声纹采集/匹配脚本（pyannote 等）
│   └── summarize.py                       # LLM 摘要脚本
├── Resources/
│   ├── Info.plist
│   └── Assets.xcassets/                   # App 图标
├── Tools/
│   ├── package_macos_app.sh               # DMG/zip 打包脚本
│   └── package_pkg.sh                     # 本地 .pkg 打包脚本
├── project.yml                            # XcodeGen 配置
├── SPEC.md                                # 项目规格
└── CHANGELOG.md                           # 变更日志
```

## 环境要求

- macOS 13.0 或更高版本
- Xcode 15 或更高版本（源码构建）
- Python 3 环境（推荐 Conda/Anaconda）
- `ffmpeg`

### Python 依赖

```bash
# FunASR 路线
pip install -U funasr modelscope openai

# VibeVoice MLX 路线（Apple Silicon）
pip install -U mlx-audio huggingface_hub openai

# Whisper MLX 路线（Apple Silicon）
pip install -U mlx-whisper huggingface_hub openai

# Qwen3-ASR 路线（Apple Silicon）
pip install -U mlx-qwen3-asr huggingface_hub openai pyannote.audio
```

如果本机有多套 Python，优先在 App 内选择安装了对应引擎依赖的解释器。

## 构建

```bash
# Debug
xcodebuild \
  -project VoiceScribe.xcodeproj \
  -scheme VoiceScribe \
  -configuration Debug \
  -derivedDataPath ./build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build

# Release
xcodebuild \
  -project VoiceScribe.xcodeproj \
  -scheme VoiceScribe \
  -configuration Release \
  -derivedDataPath ./build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

## 打包

```bash
# 方式一：脚本
./Tools/package_macos_app.sh

# 方式二：手动
rm -rf dist
mkdir -p dist
cp -R build/DerivedData/Build/Products/Release/VoiceScribe.app dist/VoiceScribe.app
ditto -c -k --sequesterRsrc --keepParent dist/VoiceScribe.app dist/VoiceScribe-macOS-test.zip
```

产物：`dist/VoiceScribe.app`

未做正式签名和 notarization。测试时 macOS 拦截可右键选择"打开"。

## 使用流程

1. 启动 App，进入设置页面。
2. 选择转写引擎（VibeVoice MLX 或 FunASR）。
3. 点击「预热环境」，等待依赖检测完成。
4. 如缺少依赖，按提示安装。
5. 预热完成后选择性能档位，点击「开始使用」。
6. 拖入音频文件或点击选择。
7. 点击「开始转写」。
8. 转写完成后可重命名角色、生成摘要。
9. 切换到「历史」标签页查看所有转写记录。

批量处理通话录音时，先在设置中配置摘要模型，再切换到「批量任务」标签页导入文件或文件夹并点击「开始队列」。通话记录队列会解析联系人、号码和通话时间，自动忽略少于 10 秒的录音，并逐条完成转写、AI 整理和归档，全程停留在批量页面。

## 资源管理

转写脚本会自动限制 CPU 和内存使用：

- 限制 PyTorch 线程数（`torch.set_num_threads`）
- 设置 `OMP_NUM_THREADS`、`MKL_NUM_THREADS` 等环境变量
- 默认 batch size 60s，避免大音频导致内存峰值
- 所有音频统一转为 16kHz 单声道 WAV 再转写

性能档位对照：

| 档位 | 线程 | batch | merge |
|------|------|-------|-------|
| 低   | 1-2  | 60s   | 10s   |
| 中   | 2-4  | 90s   | 12s   |
| 高   | 2-6  | 120s  | 15s   |

## 隐私

本仓库只保存源码、配置和脚本，不包含：

- 原始音频、视频或转写结果
- API Key、访问令牌或账号信息
- 构建产物（`build/`、`dist/`）
- Python 虚拟环境或模型缓存

排除规则已写入 `.gitignore`。

远程模式仅在用户显式选择远程 Mac mini 或 AllServes relay 时上传音频到对应自有服务。Hugging Face token 只作为运行参数传递给本机或服务端子进程，不应写入日志、文档或提交；模型、pyannote 和声纹模型依赖保持用户手动配置与验证，不由自动测试下载。

## 许可

本项目仅供个人使用。
