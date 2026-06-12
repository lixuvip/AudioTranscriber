# VoiceScribe 声纹库与模型安装说明

本文档记录“转写 + 多说话人识别 + 声纹库逐步学习”的落地路线。当前开发只加入声纹库和样本提取能力，不会自动下载任何模型。

## 目标

VoiceScribe 的声纹库分两阶段工作：

1. 转写模型先完成 ASR 和未知说话人分离，生成 `角色A / 角色B / 角色C`。
2. 用户确认角色真实姓名后，系统从该角色的高质量片段中提取样本，写入本地声纹库。后续安装 embedding 模型后，可把新录音里的角色自动匹配到已有人员。

声纹库提升的是“谁在说话”的识别效率，不直接提升“说了什么”的 ASR 准确率。

## 什么时候会读取声纹库

普通转写引擎不会读取声纹库：

- `VibeVoice MLX`：只做本地 ASR 和时间戳解析。
- `Qwen3-ASR`：做 ASR，可选 pyannote 区分未知说话人。
- `FunASR + cam++`：做 ASR，可选 cam++ 区分未知说话人。

只有选择 `Qwen3-ASR + 声纹库` 组合引擎时，VoiceScribe 才会在转写成功后读取本地声纹库：

1. `Qwen3-ASR + pyannote` 先把新录音分成 `角色A / 角色B / 角色C`。
2. `voiceprint.py match` 从这些角色片段中裁出短样本。
3. `speechbrain/spkrec-ecapa-voxceleb` 生成 embedding。
4. 系统把新角色 embedding 与 `~/Library/Application Support/VoiceScribe/Voiceprints` 中的已知人物 profile 对比。
5. 达到阈值的角色会自动写回 `*_speaker_map.json`，整理版正文会显示已匹配的人名。

如果声纹依赖或 ECAPA 模型缺失，组合引擎仍会保留 Qwen3-ASR 转写结果，只在日志里提示声纹匹配未执行。

## 当前开发内容

- 新增 `Scripts/voiceprint.py`。
- 新增本地声纹库目录：`~/Library/Application Support/VoiceScribe/Voiceprints`。
- 转写完成后，在角色命名卡中可以点击“加入声纹库”。
- 侧边栏新增独立“声纹库”模块，可检查缺失依赖、逐个安装依赖、直接录制或导入样本、查看 profile 和打开声纹库目录。
- 引擎选择新增 `Qwen3-ASR + 声纹库`，用于“转写 + 多说话人分离 + 已知人物声纹匹配”的组合流程。
- 缺少模型时只记录 `embeddingStatus = missing_model`，不会触发下载。

## 需要手动安装的依赖

### 1. 基础依赖

```bash
brew install ffmpeg
```

### 2. 声纹 embedding 依赖

建议安装到 VoiceScribe 独立虚拟环境，避免写入 Homebrew 管理的系统 Python：

```bash
BASE_PYTHON="$(command -v python3)"
"$BASE_PYTHON" -m venv "$HOME/.voicescribe/venv"
"$HOME/.voicescribe/venv/bin/python3" -m pip install -U pip setuptools wheel
"$HOME/.voicescribe/venv/bin/python3" -m pip install -U speechbrain torch torchaudio huggingface_hub
```

### 3. 手动下载声纹模型

VoiceScribe 计划使用以下模型生成已知说话人的 embedding：

- `speechbrain/spkrec-ecapa-voxceleb`

手动下载命令：

```bash
"$HOME/.voicescribe/venv/bin/python3" - <<'PY'
from huggingface_hub import snapshot_download

snapshot_download(
    repo_id="speechbrain/spkrec-ecapa-voxceleb",
    local_dir="models/speechbrain-spkrec-ecapa-voxceleb",
    local_dir_use_symlinks=False,
)
PY
```

下载后可以用环境变量显式告诉 VoiceScribe 模型位置：

```bash
export VOICESCRIBE_ECAPA_MODEL_DIR="$PWD/models/speechbrain-spkrec-ecapa-voxceleb"
```

如果不设置该变量，检查脚本会查看 Hugging Face 默认缓存：

```text
~/.cache/huggingface/hub/models--speechbrain--spkrec-ecapa-voxceleb
```

## 检查命令

只检查，不下载：

```bash
"$HOME/.voicescribe/venv/bin/python3" Scripts/voiceprint.py check --json
```

如果依赖缺失，输出中的 `missing` 会列出缺少项，例如：

```json
{
  "ready": false,
  "missing": ["speechbrain", "torch", "torchaudio", "speechbrain/spkrec-ecapa-voxceleb"]
}
```

## 样本提取命令

完成一次转写后，可以手动测试样本提取：

```bash
"$HOME/.voicescribe/venv/bin/python3" Scripts/voiceprint.py enroll \
  --audio "/path/to/audio.m4a" \
  --speaker-map "/path/to/audio_speaker_map.json" \
  --speaker-key "0" \
  --speaker-name "张三" \
  --library-dir "$HOME/Library/Application Support/VoiceScribe/Voiceprints"
```

该命令只裁剪音频样本并写入 profile，不会下载模型。

## 后续模型策略

建议保留三个执行档位：

- 快速多人转写：`VibeVoice-ASR MLX`。
- 高准确率中文/方言：`Qwen3-ASR + pyannote Community-1`。
- 已知说话人自动命名：选择 `Qwen3-ASR + 声纹库`，在 diarization 之后使用 `speechbrain/spkrec-ecapa-voxceleb` 生成 embedding 并匹配声纹库。

`Qwen3-ASR + pyannote` 通常不是更快路线，而是更准确路线。声纹库是长期效率提升路线：用户确认越多，后续角色命名和校对成本越低。
