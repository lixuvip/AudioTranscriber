# VoiceScribe

macOS 本地音频转写工具。支持 FunASR + cam++ 和 VibeVoice MLX 双引擎，自动说话人分离，LLM 摘要生成，转写历史管理。所有处理均在本地完成，不上传音频到第三方服务。

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

- 双引擎：`FunASR + cam++`（稳定中文转写 + 说话人区分）和 `VibeVoice MLX`（Apple Silicon 加速）。
- 拖拽或选择音频文件，支持 m4a、mp3、wav、mp4、mov、aac、flac。
- 非 WAV 格式自动通过 ffmpeg 转为 16kHz 单声道 WAV 再转写。
- 转写结果输出：原始 JSON、通话记录 Markdown、整理版文本、说话人映射 JSON。
- 多角色场景自动分配 `角色A / 角色B / 角色C`，支持在界面中重命名。
- 支持中途停止转写。

### 摘要

- 用户自行添加 LLM 模型，支持多个模型并切换选择。
- 接口形态：OpenAI Compatible、OpenAI Responses、Anthropic Messages。
- 支持自定义摘要提示词，只影响摘要生成，不影响转写。
- 基于整理版文本生成摘要，输出为 `_摘要.md`。

### 环境管理

- 启动后进入设置页面，先选引擎再预热，不阻塞 App 启动。
- 自动检测 ffmpeg、Python、转写引擎依赖和模型缓存。
- 自动选择已安装引擎依赖的 Python 解释器，支持手动指定。
- 缺少依赖时可从界面安装，MLX 路线会自动创建独立虚拟环境。
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
- **转写引擎**：FunASR（paraformer-zh + cam++）/ VibeVoice MLX（mlx-audio）
- **项目管理**：XcodeGen（project.yml）

## 项目结构

```text
VoiceScribe/
├── VoiceScribe.xcodeproj/                 # Xcode 工程（XcodeGen 生成）
├── Sources/
│   └── App/
│       ├── AudioTranscriberApp.swift      # App 入口
│       ├── ContentView.swift              # 主视图路由（设置页 ↔ 转写页）
│       ├── SetupView.swift                # 设置/预热页面
│       ├── HistoryView.swift              # 转写历史列表
│       ├── EnvironmentChecker.swift       # 环境检测与性能推荐
│       ├── Transcriber.swift              # 转写进程管理
│       ├── SettingsManager.swift          # 用户设置持久化
│       ├── TranscriptionHistoryEntry.swift # 历史记录模型
│       ├── Color+Hex.swift                # 颜色扩展
│       └── Components/
│           ├── StatusCard.swift           # 环境状态卡片
│           ├── FileDropZone.swift         # 文件拖拽区
│           ├── SettingsPanel.swift        # 设置面板（引擎/Python/LLM）
│           ├── LogView.swift              # 日志输出
│           ├── ButtonStyles.swift         # 按钮样式
│           ├── FolderPicker.swift         # 目录选择器
│           └── FolderPickerSheet.swift    # 目录选择 Sheet
├── Scripts/
│   ├── transcribe.py                      # 双引擎转写脚本
│   └── summarize.py                       # LLM 摘要脚本
├── Resources/
│   ├── Info.plist
│   └── Assets.xcassets/                   # App 图标
├── Tools/
│   └── package_macos_app.sh               # 打包脚本
├── project.yml                            # XcodeGen 配置
└── SPEC.md                                # 项目规格
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

## 许可

本项目仅供个人使用。
