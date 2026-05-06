# Changelog

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
