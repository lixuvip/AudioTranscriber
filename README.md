# AudioTranscriber

AudioTranscriber 是一个 macOS 本地音频转写工具。它使用 SwiftUI 提供桌面界面，通过 Python 脚本调用不同的本地转写引擎完成语音识别，并将结果保存为 JSON 与 Markdown 文件。

项目当前定位是本地自用/私有协作工具，重点是让会议、访谈、播客等音频可以在本机完成转写，尽量避免把原始音频上传到第三方服务。

## 功能概览

- 支持拖拽或手动选择音频文件。
- 支持音频与常见视频容器输入，MLX 路线会在需要时自动通过 `ffmpeg` 转成临时 WAV。
- 按所选运行环境与转写引擎检测 `ffmpeg`、Python、FunASR/MLX 与本地模型缓存。
- 自动优先选择能匹配当前引擎依赖的 Python 解释器，兼容 Homebrew、系统 Python、Anaconda 与常见 Conda 环境。
- 支持手动选择 Python 可执行文件，便于在不同机器上绑定正确环境。
- 支持双引擎：`FunASR + cam++` 与 `VibeVoice MLX`。
- 支持先选环境、再选引擎、再预热检测，不会在每次打开 App 时立刻做重依赖扫描。
- 缺少依赖时可从界面打开 Terminal 安装 `ffmpeg`、当前引擎 Python 依赖或下载模型。
- MLX 依赖安装会优先创建 App 自己管理的虚拟环境，避免 Homebrew Python 的 `externally-managed-environment` 限制。
- 转写结果会输出原始 JSON、标准通话正文和可继续编辑的整理版文本。
- 多角色场景下会先生成 `角色A/角色B/角色C`，用户可在界面里改成真实姓名或身份。
- 支持中途停止转写，必要时会强制结束后台进程。
- 摘要模型由用户自行添加，支持填写接口形态、Base URL 和 Token。
- 摘要接口形态支持 `OpenAI Compatible`、`OpenAI Responses` 与 `Anthropic Messages`。
- 摘要支持单独输入提示词，提示词只影响摘要生成，不影响转写本身。
- 预热后会根据当前设备自动推荐性能档位，并允许手动切换 `低 / 中 / 高`。
- 界面会直接展示关键参数：设备、线程数、batch 时长、merge 时长、说话人开关。

## 技术结构

```text
AudioTranscriber.xcodeproj/   Xcode 工程
Sources/App/                  SwiftUI 桌面应用源码
Sources/App/Components/       UI 组件
Scripts/transcribe.py         双引擎转写脚本
Scripts/summarize.py          摘要脚本
Resources/Info.plist          macOS App 配置
SPEC.md                       项目规格说明
project.yml                   XcodeGen 项目配置
```

核心链路：

1. 用户在 macOS App 中选择音频文件。
2. 用户先选择运行环境、转写引擎和模型，再检测或选择可用 Python 环境。
3. Swift 使用 `Process` 启动 `Scripts/transcribe.py`。
4. Python 按当前引擎调用 FunASR 或 MLX 模型执行转写。
5. App 实时展示日志和进度。
6. 转写结果写入输出目录。

## 环境要求

- macOS 13.0 或更高版本。
- Xcode 15 或更高版本用于源码构建。
- Python 3 环境，推荐使用 Conda/Anaconda 管理转写依赖。
- `ffmpeg`，用于音频处理。
- Python 依赖：
  - FunASR 路线：`funasr`、`modelscope`
  - MLX 路线：`mlx-audio`、`huggingface_hub`
- 如需摘要功能，还需要 `openai` Python 包以及对应 API 环境变量。

常用依赖安装示例：

```bash
brew install ffmpeg
python3 -m pip install -U funasr modelscope openai
python3 -m pip install -U mlx-audio huggingface_hub openai
```

如果本机有多套 Python，请优先在 App 内选择安装了当前引擎依赖的解释器，例如某个 Conda 环境里的 `bin/python3`。

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

也可以直接运行脚本：

```bash
./Tools/package_macos_app.sh
```

## 使用说明

1. 启动 App。
2. 先选择运行环境、转写引擎和模型，再点击“预热环境”。
3. 如 Python 检测不正确，点击 Python 行的选择按钮，手动选择安装了当前引擎依赖的 `python3`。
4. 如缺少依赖，使用环境卡片中的安装按钮打开 Terminal 安装当前引擎依赖或模型。
5. 预热完成后，可根据推荐结果或手动选择 `低 / 中 / 高` 性能档位。
6. 拖入音频文件或点击选择文件。
7. 可选择输出目录；不选择时默认保存到音频同目录。
8. 点击“开始转写”。
9. 如需中途打断，可点击“停止转写”结束当前进程。
10. 完成后可在界面中给 `角色A/角色B/角色C` 命名，并生成整理版文本。
11. 需要摘要时，选择自己添加的线上模型，摘要会优先基于整理版文本生成。

预热完成后，App 会根据 CPU 核心数、内存、当前引擎和 Python 能力自动推荐转写性能配置，并将线程数、批处理时长等参数传给转写脚本。FunASR 路线继续保留 `cam++` 说话人区分；Mac 上可切换到 `VibeVoice MLX` 作为实验性第二引擎。

## 当前开发完成情况

目前这一版已经完成的核心开发内容包括：

- 双引擎路线已经打通：FunASR 负责稳定会议转写和 `cam++` 说话人区分，VibeVoice MLX 负责 Apple Silicon 下的实验性高效转写。
- 环境检测逻辑已调整为手动预热，不再阻塞 App 启动。
- 依赖安装入口、模型下载入口、外部安装后的重新预热入口都已加入界面。
- MLX 路线已补上输入格式兼容处理，`m4a/mp4/mov` 会自动转成 WAV 再转写。
- 转写结果不再只停留在原始 JSON，而是会输出更适合阅读和后续整理的正文格式。
- 多角色转写已经接入角色占位名和后续重命名流程，方便在生成摘要前完成内容清洗。
- 摘要模型配置改为完全用户自定义，不再内置示例模型。
- 摘要接口形态已覆盖 OpenAI 风格和 Anthropic 风格。
- 性能模式已加入自动推荐和手动三档切换，便于在不同机器上平衡速度、稳定性和资源占用。
- 停止转写按钮已接入，异常占用时可以直接中断后台任务。

## 当前版本说明

- 当前仓库版本是一个可直接测试的阶段性版本，重点覆盖环境选择、双引擎转写、角色整理、摘要模型配置和性能档位控制。
- 最新本地打包脚本为 `Tools/package_macos_app.sh`。
- 最新测试包默认输出到 `dist/AudioTranscriber.app` 和 `dist/AudioTranscriber-macOS-test.zip`。
- 当前仍以 macOS 本地测试为主，尚未包含正式签名和 notarization 流程。

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
- 本地转写主链路已接入双引擎：FunASR + cam++ / VibeVoice MLX。
- Python 环境自动检测和手动选择已增强。
- 缺依赖时支持从界面触发安装/下载入口。
- 启动时不再同步检测重依赖，改为先选环境/引擎，再手动预热。
- 预热后会根据当前设备生成自动性能配置。
- 摘要模型配置已支持用户自填接口形态、Base URL 和 Token。
- 转写后支持角色A/角色B/角色C命名，并基于整理版文本生成摘要。
