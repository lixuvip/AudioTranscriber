# Changelog

## v1.0.0-beta.2 (unreleased)

三引擎支持、UI 重构为三栏布局、音频播放与波形可视化。

### 新增

**Qwen3-ASR 引擎**
- 新增 Qwen3-ASR 转写引擎（`TranscriptionEngine.qwen3ASR`），Apple Silicon MLX 原生加速
- 支持两个模型变体：`Qwen/Qwen3-ASR-0.6B`（默认）和 `Qwen/Qwen3-ASR-1.7B`
- 每个引擎添加 `availableModelIDs` 列表，方便未来扩展模型选择 UI
- FunASR 新增模型：`iic/speech_SenseVoiceSmall`、`FunAudioLLM/Fun-ASR-Nano-2512`

**三栏布局 UI**
- 新增左侧导航栏 `SidebarView`，支持工作区 / 批量队列 / 编辑器 / 历史 / 设置五个标签页
- 侧边栏显示环境就绪状态、CPU/内存使用率监控
- 新增 `WaveformVisualizer` 波形可视化组件，支持动画效果
- 新增 `AIInsightsPanel`，提供会议纪要 / 行动项 / 宣发文案三个 Tab

**音频播放**
- `Transcriber` 新增音频播放能力（`AVAudioPlayer`），支持播放/暂停/速度调节
- 播放进度与波形动画联动

**转写增强**
- 转写前内存预检，不足时自动降级性能档位并提示用户
- `transcribe.py` 新增结构化进度输出（JSON），支持实时百分比和 ETA
- 转写完成摘要卡片，显示引擎/模型/耗时/说话人数等统计
- 转写错误结构化解析，Swift 端可区分错误类型

### 优化

**SettingsManager**
- 新增 `hfToken` 持久化（HuggingFace 门控模型下载）
- 新增 `lastSummaryModelID` 持久化，记住上次摘要使用的模型
- 模型 ID 初始化时按引擎前缀校验，无效时回退默认值
- `LLMProviderType` 扩展为 OpenAI Compatible / OpenAI Responses / Anthropic Messages

**EnvironmentChecker**
- 新增 Qwen3-ASR 依赖检测和模型缓存检查
- 新增 `checkAvailableMemory` 内存预检方法
- 性能档位根据引擎类型动态调整内存阈值

**打包脚本**
- `package_macos_app.sh` 更新为 VoiceScribe 项目名
- 新增 `package_pkg.sh`，支持本地 `.pkg` 打包

**Whisper MLX 引擎**
- 新增 `TranscriptionEngine.whisperMLX`，基于 `mlx-whisper` 的 Apple Silicon 本地 Whisper 转写
- `mlx-whisper` 依赖与模型缓存接入 App 安装/下载流程；检测阶段只查缓存，不下载大模型

**通话记录批量队列**
- 新增「批量任务」标签页与独立的通话记录队列模块，支持导入多个文件或整个文件夹
- 文件名解析支持 `联系人@号码_yyyyMMddHHmmss` 与 `号码_yyyyMMddHHmmss`
- 导入时读取时长，少于 10 秒的录音自动标记为「已忽略」，不进入队列
- 队列逐条执行 `转写 → AI 整理 → 归档`，当前条目完成后再开始下一条
- 维护全局 `call_index.json`、`通话记录索引.md` 与按号码分组的 `Contacts/*.md`

**人物归档与时间线工作区**
- 新增三栏「人物归档」标签页：人物列表 / 通话时间线 / AI 整理
- 支持手动合并、拆分联系人，合并可撤销
- 通话选择草稿持久化（`selection_drafts.json`），可按全选 / 近 30 天等批量勾选
- 版本化的人物 AI 整理（`organization_versions.json`），支持失败后幂等修复
- 归档数据采用原子写入 + `.backup` 回退（`AtomicJSONFileStore`），损坏时进入只读保护

**声纹库**
- 转写完成后可将角色「加入声纹库」，后续转写自动匹配已知人物
- 声纹依赖（pyannote 等）安装到独立 Python 环境，模型按需下载

### 稳定性与性能

- 转写子进程与定时器生命周期加固：定时器幂等启动避免叠加；App 退出时清理仍在运行的 Python 子进程，避免遗留孤儿进程；远程轮询容错，单次网络抖动不再使整单失败
- `transcribe.py` 预处理临时目录改由 `atexit` 清理，覆盖正常结束、`sys.exit` 与异常退出，杜绝临时文件泄漏
- 通话队列改为持久化到 `~/Library/Application Support/VoiceScribe/call_record_queue.json`（原子写 + 备份），替代有 ~1MB 上限且非原子的 `UserDefaults`，并自动迁移旧数据
- 人物归档按电话号码建立通话索引，`calls(for:)` 由每次 O(全部通话) 降为 O(人物电话数)
- 人物时间线在勾选/全选/清空时不再重建整份通话列表，消除每次点击对全部通话文件的可用性 stat
- `ContentView` 拆分出自包含 UI 组件文件（`ContentViewComponents.swift`），降低单文件体量
- `AtomicJSONFileStore` 在键名无法往返时显式报错并附修复指引，避免「驼峰缩写属性」静默丢键

### 安全

- `.claude/` 目录加入 `.gitignore`，防止隐私泄露

---

## v1.0.0-beta (2026-05-06)

首个公开测试版本。macOS 本地音频转写工具，支持双引擎转写、说话人分离和 LLM 摘要。

### 功能

**转写引擎**
- 双引擎支持：FunASR + cam++（中文 ASR + 说话人区分）和 VibeVoice MLX（Apple Silicon 加速）
- 自动将非 WAV 音频（m4a/mp3/mp4/mov/aac/flac）转为 16kHz 单声道 WAV 再转写
- 中文语言显式指定，确保转写准确性
- 转写输出：原始 JSON、通话记录 Markdown、整理版文本、说话人映射 JSON

**环境管理**
- 启动后进入设置页面，先选引擎再预热，不阻塞 App 启动
- 自动检测 ffmpeg、Python、转写引擎依赖和模型缓存
- 自动选择已安装引擎依赖的 Python 解释器，支持手动指定
- 缺少依赖时可从界面安装，MLX 路线自动创建独立虚拟环境

**性能调优**
- 根据 CPU 核心数和内存自动推荐性能档位（低 / 中 / 高）
- 限制 PyTorch 线程数，避免 CPU 占满
- 默认 batch size 60s，降低内存峰值
- 档位选择持久化，下次启动自动恢复

**说话人管理**
- 多角色场景自动分配 `角色A / 角色B / 角色C`
- 支持在界面中重命名角色，整理版文本和摘要使用新名称

**LLM 摘要**
- 用户自行添加 LLM 模型，支持多个模型并切换选择
- 接口形态：OpenAI Compatible、OpenAI Responses、Anthropic Messages
- 支持自定义摘要提示词

**转写历史**
- 转写完成后自动记录到历史（最多 200 条）
- 标签页切换查看，支持搜索
- 展开查看输出文件，可单独打开或打开目录

**交互**
- 拖拽或选择音频文件
- 支持中途停止转写
- 实时日志输出和进度显示

### 安全

- 所有处理均在本地完成，不上传音频到第三方服务
- API Key 通过参数传入，不硬编码
- 子进程设置 `standardInput = .nullDevice`，防止 stdin 卡死
- Process 执行使用 `do/try/catch`，不静默吞错

### 系统要求

- macOS 13.0+
- Python 3 + ffmpeg
- FunASR 路线：`funasr`、`modelscope`
- MLX 路线：`mlx-audio`、`huggingface_hub`

### 已知限制

- 未做正式签名和 notarization，首次打开需右键选择"打开"
- MLX 引擎仅支持 Apple Silicon Mac
- 摘要功能需要网络连接（调用 LLM API）
