# VoiceScribe Remote Service And AllServes Relay Contract

本文档是 VoiceScribe App 对接 Mac mini VoiceScribe Server 和 All Service / AllServes relay 的接口契约。后续 UI 或功能优化不得擅自修改这里定义的远程接口；如果必须改请求、响应、结果文件或错误语义，必须同步更新本文档、相关 Swift/Python 代码和测试。

## 接入模式

### 直连 Mac mini VoiceScribe Server

App 设置页选择「远程 Mac mini」后，使用 `remoteServiceURL` 访问 VoiceScribe Server，例如：

```text
http://192.168.x.x:8766
```

如果局域网地址不可用且配置了 `remoteTailscaleURL`，App 会尝试 Tailscale 地址。直连模式调用原生 VoiceScribe Server 路径：

```text
GET    /v1/health
POST   /v1/uploads
POST   /v1/tasks
GET    /v1/tasks/{task_id}
GET    /v1/tasks/{task_id}/result/{index}
DELETE /v1/tasks/{task_id}
```

### All Service / AllServes relay

App 设置页选择「中转服务」后，使用 `relayServiceURL`，默认示例为：

```text
https://all-serves.openclaw-mini.cn
```

relay 模式仍保持 VoiceScribe Server 的 `/v1/*` 语义。服务路由字段只用于 AllServes 找到 VoiceScribe 后端：

- 上传音频：`POST /v1/uploads?service=voicescribe`
- 创建任务：`POST /v1/tasks`，body 顶层包含 `service: "voicescribe"`
- 转写参数必须放在 `arguments` 内，不依赖顶层 `engine`、`model_id`、`speaker_diarization` 等字段。

## 鉴权与密钥边界

所有远程请求使用 Bearer Token：

```http
Authorization: Bearer <REMOTE_OR_RELAY_ACCESS_TOKEN>
```

`hf_token` 是 Hugging Face 运行参数，只用于 Qwen3-ASR / pyannote 说话人区分依赖。App 创建任务时可把它放入 `arguments.hf_token`；VoiceScribe Server worker 启动 `Scripts/transcribe.py` 子进程时会把它透传为：

```text
HF_TOKEN=<HF_TOKEN>
HUGGING_FACE_HUB_TOKEN=<HF_TOKEN>
```

要求：

- 不要在日志、文档、提交信息、截图或错误消息中写入真实 token。
- 不要把 `hf_token` 作为模型配置真值记录在文档中；文档只能使用占位符。
- 不要把 `hf_token` 放入 CLI 参数，避免被进程列表或转写日志暴露。
- 不要自动下载大模型、门控模型或付费资源；模型、pyannote 和 HF token 依赖由用户手动配置和验证。

## 请求字段

### 上传音频

```http
POST /v1/uploads
Content-Type: multipart/form-data
Authorization: Bearer <TOKEN>
```

relay 模式路径为：

```http
POST /v1/uploads?service=voicescribe
```

字段：

| 字段 | 位置 | 说明 |
| --- | --- | --- |
| `file` | multipart form | 原始音频文件。支持 `.wav`, `.mp3`, `.m4a`, `.aac`, `.flac`, `.mp4`, `.mov`。 |

### 创建转写任务

```http
POST /v1/tasks
Content-Type: application/json
Authorization: Bearer <TOKEN>
```

直连 body：

```json
{
  "command": "transcribe",
  "upload_id": "<UPLOAD_ID>",
  "arguments": {
    "engine": "qwen3ASR",
    "model_id": "Qwen/Qwen3-ASR-0.6B",
    "device": "cpu",
    "threads": "4",
    "batch_size_s": "60",
    "merge_length_s": "15",
    "speaker_diarization": "1",
    "hf_token": "<HF_TOKEN>"
  }
}
```

relay body：

```json
{
  "service": "voicescribe",
  "command": "transcribe",
  "upload_id": "<UPLOAD_ID>",
  "arguments": {
    "engine": "qwen3ASR",
    "model_id": "Qwen/Qwen3-ASR-0.6B",
    "device": "cpu",
    "threads": "4",
    "batch_size_s": "60",
    "merge_length_s": "15",
    "speaker_diarization": "1",
    "hf_token": "<HF_TOKEN>"
  }
}
```

字段语义：

| 字段 | 位置 | 必填 | 说明 |
| --- | --- | --- | --- |
| `service` | body top-level | relay 必填 | AllServes 路由字段。直连 VoiceScribe Server 不需要。 |
| `command` | body top-level | 是 | 当前只支持 `transcribe`。 |
| `upload_id` | body top-level | 是 | `/v1/uploads` 返回的上传 ID。 |
| `arguments.engine` | arguments | 是 | App 转换后的脚本引擎名，例如 `funASR`, `vibeVoiceMLX`, `qwen3ASR`。 |
| `arguments.model_id` | arguments | 是 | 转写模型 ID。Qwen3 可带 dtype 后缀，例如 `Qwen/Qwen3-ASR-0.6B:dtype=float16`。 |
| `arguments.device` | arguments | 是 | 运行设备，当前常用 `cpu` 或 `mps`。 |
| `arguments.threads` | arguments | 是 | 子进程线程上限。 |
| `arguments.batch_size_s` | arguments | 是 | 批处理音频秒数。 |
| `arguments.merge_length_s` | arguments | 是 | 合并片段秒数。 |
| `arguments.speaker_diarization` | arguments | 是 | `1` 开启说话人区分，`0` 关闭。 |
| `arguments.hf_token` | arguments | 否 | Qwen3-ASR / pyannote 运行时 token。只能用占位符记录，真实值不得提交。 |

禁止字段：

```text
voxcpm_root
output_directory
reference_audio_path
audio_path
out_dir
```

VoiceScribe Server 会拒绝这些路径字段，避免远程调用越过服务器存储边界。

## 响应字段

### Health

```json
{
  "api_version": "1",
  "service_version": "0.1.0",
  "runtime_state": "idle",
  "queue_depth": 0,
  "active_task_id": null,
  "available_disk_bytes": 1234567890,
  "available_engines": ["funASR", "vibeVoiceMLX", "qwen3ASR"]
}
```

App 只接受 `api_version == "1"`。

### Upload

```json
{
  "upload_id": "<UPLOAD_ID>",
  "filename": "meeting.m4a",
  "size_bytes": 123456,
  "sha256": "<SHA256>"
}
```

### Task status

```json
{
  "task_id": "<TASK_ID>",
  "status": "running",
  "progress": 0.42,
  "estimated_time_remaining": null,
  "current_stage": "Qwen3-ASR 转写音频块 2/8",
  "error": null,
  "results": []
}
```

兼容 AllServes relay 时，App 也能读取可选字段：

```json
{
  "phase": "uploading_results",
  "details": {
    "message": "Worker 正在上传结果"
  },
  "output_count": 3
}
```

`current_stage` 优先；缺失时 App 会依次从 `details.current_stage`、`details.stage`、`details.message`、`phase` 中推导显示文案。

状态值：

| status | App 文案 |
| --- | --- |
| `queued` | 排队中 |
| `claimed` | Worker 已接单 |
| `downloading_input` | Worker 正在下载输入 |
| `uploading_to_local` | Worker 正在上传到本地服务 |
| `preparing` | 准备中 |
| `running` | 转写中 |
| `uploading_results` | Worker 正在上传结果 |
| `completed` | 完成 |
| `failed` | 失败 |
| `cancelled` | 已取消 |

### Completed task results

完成后 `results` 至少应包含可下载的 Markdown 和 speaker map：

```json
{
  "task_id": "<TASK_ID>",
  "status": "completed",
  "progress": 1.0,
  "results": [
    {
      "index": 0,
      "filename": "meeting_通话记录.md",
      "category": "transcript",
      "size_bytes": 1000,
      "sha256": "<SHA256>"
    },
    {
      "index": 1,
      "filename": "meeting_整理版.md",
      "category": "speaker_text",
      "size_bytes": 1000,
      "sha256": "<SHA256>"
    },
    {
      "index": 2,
      "filename": "meeting_speaker_map.json",
      "category": "speaker_map",
      "size_bytes": 1000,
      "sha256": "<SHA256>"
    },
    {
      "index": 3,
      "filename": "meeting_funasr.json",
      "category": "raw_json",
      "size_bytes": 1000,
      "sha256": "<SHA256>"
    }
  ]
}
```

App 下载时优先使用 `category` 绑定：

| category | 文件 |
| --- | --- |
| `transcript` | `*_通话记录.md` |
| `speaker_text` | `*_整理版.md` |
| `speaker_map` | `*_speaker_map.json` |
| `raw_json` | `*_funasr.json`，历史兼容命名，可能包含非 FunASR 引擎的原始结果。 |

如果 relay 或服务端缺失 `category`，App 会按文件名后缀兜底识别前三类。

## 结果文件加载

`Scripts/transcribe.py` 输出：

| 文件 | 说明 |
| --- | --- |
| `*_通话记录.md` | 使用占位角色名的完整转写文本。 |
| `*_整理版.md` | 使用用户改名或声纹匹配结果后的整理文本。 |
| `*_speaker_map.json` | 角色、片段、声纹匹配信息的结构化数据。 |
| `*_funasr.json` | 原始转写结果 JSON，文件名保持历史兼容。 |

App 加载顺序：

1. 远程完成后下载 `results` 中的每个文件。
2. 优先按 `category` 设置当前 transcript、整理版和 speaker map URL。
3. `category` 不存在时，回退到 `*_通话记录.md`、`*_整理版.md`、`*_speaker_map.json` 命名。
4. 读取 `_speaker_map.json` 填充 `speakerRoles` 和 `currentTranscriptSegments`。
5. 若当前引擎启用声纹库，读取本地声纹库并尝试写回 speaker map，然后重建整理版。

## 说话人区分依赖

FunASR + cam++：

- 依赖 `funasr`、`modelscope`、cam++ 相关模型缓存。
- `speaker_diarization=1` 时启用可用的说话人区分能力。

Qwen3-ASR：

- 依赖 `mlx-qwen3-asr`、`huggingface_hub`、`pyannote.audio`。
- pyannote 门控模型可能需要 Hugging Face token。
- App 把 `hf_token` 放入 `arguments`；Server worker 只把它放入子进程环境变量。
- 如果 pyannote 不可用，脚本会尝试降级为无说话人区分转写，并在日志里提示。

声纹库：

- 本地声纹库默认目录为 `~/Library/Application Support/VoiceScribe/Voiceprints`。
- 声纹匹配在 App 侧本地执行，依赖 `Scripts/voiceprint.py` 和用户配置的 Python 环境。
- 缺少 `speechbrain`、`torch`、`torchaudio` 或 ECAPA 模型时，声纹匹配应报告缺失项，不自动下载。

## 错误处理

常见错误：

| HTTP / code | 处理方式 |
| --- | --- |
| `401` | App 显示访问令牌不匹配。 |
| `404 Task not found` | 任务不存在或 relay 映射已过期。 |
| `409 Task result is not ready` | 结果未就绪，继续轮询或提示稍后重试。 |
| `415 Unsupported audio format` | 音频格式不支持。 |
| `422 Unsupported command` | `command` 不是 `transcribe`。 |
| `422 Filesystem paths are not accepted` | 请求含禁止路径字段，必须从 `arguments` 移除。 |
| `507 Low disk space on server` | 服务端磁盘空间不足。 |
| `failed + error.message` | App 显示服务端错误消息，但不得包含真实 token。 |

本地脚本结构化错误：

```json
{
  "type": "error",
  "code": "input_file_missing",
  "message": "输入音频文件不存在",
  "suggestion": "请重新选择音频文件"
}
```

App 会把结构化错误写入实时日志，并保持转写状态可恢复。

## 维护规则

- UI 文案、布局、日志页、历史页和声纹库体验可以迭代，但不能改变 `/v1/*` 远程接口契约。
- relay 模式下新增转写参数时，优先加到 `arguments`。
- 如果确实需要新增顶层字段，只能用于 AllServes 路由或协议元数据，不得替代 `arguments` 中的转写参数。
- 修改请求、响应、状态值、结果文件类别或错误语义时，必须同步更新测试和本文档。
- 不要在自动验证中安装或下载模型；只运行轻量单元测试、server 测试和 Xcode 构建验证。
