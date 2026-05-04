# AudioTranscriber

AudioTranscriber 是一个 macOS 本地音频转写工具。它使用 SwiftUI 提供桌面界面，通过 Python 脚本调用 FunASR 完成离线语音识别、标点恢复、VAD 分段和说话人分离，并将结果保存为 JSON 与 Markdown 文件。

项目当前定位是本地自用/私有协作工具，重点是让会议、访谈、播客等音频可以在本机完成转写，尽量避免把原始音频上传到第三方服务。

## 功能概览

- 支持拖拽或手动选择音频文件。
- 自动检测 `ffmpeg`、Python、FunASR 与本地模型缓存。
- 自动优先选择能 `import funasr` 的 Python 解释器，兼容 Homebrew、系统 Python、Anaconda 与常见 Conda 环境。
- 支持手动选择 Python 可执行文件，便于在不同机器上绑定正确环境。
- 缺少依赖时可从界面打开 Terminal 安装 `ffmpeg`、FunASR Python 依赖或下载模型。
- 转写结果输出为 `{音频名}_funasr.json` 与 `{音频名}_通话记录.md`。
- 预留摘要功能入口，可通过 OpenAI-compatible API 生成摘要。

## 技术结构

```text
AudioTranscriber.xcodeproj/   Xcode 工程
Sources/App/                  SwiftUI 桌面应用源码
Sources/App/Components/       UI 组件
Scripts/transcribe.py         FunASR 转写脚本
Scripts/summarize.py          摘要脚本
Resources/Info.plist          macOS App 配置
SPEC.md                       项目规格说明
project.yml                   XcodeGen 项目配置
```

核心链路：

1. 用户在 macOS App 中选择音频文件。
2. App 检测或选择可用 Python 环境。
3. Swift 使用 `Process` 启动 `Scripts/transcribe.py`。
4. Python 调用 FunASR 本地模型执行转写。
5. App 实时展示日志和进度。
6. 转写结果写入输出目录。

## 环境要求

- macOS 13.0 或更高版本。
- Xcode 15 或更高版本用于源码构建。
- Python 3 环境，推荐使用 Conda/Anaconda 管理 FunASR 依赖。
- `ffmpeg`，用于音频处理。
- Python 依赖：`funasr`、`modelscope`。
- 如需摘要功能，还需要 `openai` Python 包以及对应 API 环境变量。

常用依赖安装示例：

```bash
brew install ffmpeg
python3 -m pip install -U funasr modelscope openai
```

如果本机有多套 Python，请优先在 App 内选择安装了 FunASR 的解释器，例如某个 Conda 环境里的 `bin/python3`。

## 构建

Debug 构建：

```bash
xcodebuild \
  -project AudioTranscriber.xcodeproj \
  -scheme AudioTranscriber \
  -configuration Debug \
  -derivedDataPath ./build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Release 构建：

```bash
xcodebuild \
  -project AudioTranscriber.xcodeproj \
  -scheme AudioTranscriber \
  -configuration Release \
  -derivedDataPath ./build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

构建产物默认位于：

```text
build/DerivedData/Build/Products/Release/AudioTranscriber.app
```

## 打包测试

本地测试包可以这样生成：

```bash
rm -rf dist
mkdir -p dist
cp -R build/DerivedData/Build/Products/Release/AudioTranscriber.app dist/AudioTranscriber.app
ditto -c -k --sequesterRsrc --keepParent dist/AudioTranscriber.app dist/AudioTranscriber-macOS-test.zip
```

当前项目未做正式签名和 notarization。测试时如果 macOS 拦截，可以右键 App 后选择“打开”。

## 使用说明

1. 启动 App。
2. 等待环境检测完成。
3. 如 Python 检测不正确，点击 Python 行的选择按钮，手动选择安装了 FunASR 的 `python3`。
4. 如缺少依赖，使用环境卡片中的安装按钮打开 Terminal 安装。
5. 拖入音频文件或点击选择文件。
6. 可选择输出目录；不选择时默认保存到音频同目录。
7. 点击“开始转写”。
8. 完成后在输出目录查看 JSON 与 Markdown 转写结果。

## 隐私与仓库内容

本仓库只保存应用源码、配置和脚本，不应提交以下内容：

- 原始音频、视频或转写结果。
- API Key、访问令牌、Cookie 或账号信息。
- 本机 `build/`、`dist/`、DerivedData 等构建产物。
- Python 虚拟环境、模型缓存和依赖目录。
- 用户个人路径、测试音频文件名或真实会议内容。

相关排除规则已写入 `.gitignore`。

## 当前状态

- macOS App 可构建。
- 本地转写主链路已接入 FunASR。
- Python 环境自动检测和手动选择已增强。
- 缺依赖时支持从界面触发安装/下载入口。
- 摘要功能已有基础脚本和 UI 入口，但 API 配置体验仍可继续完善。
