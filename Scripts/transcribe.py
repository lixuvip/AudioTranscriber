#!/usr/bin/env python3
"""
VoiceScribe - 转写脚本
用法: python3 transcribe.py <音频路径> <输出目录>
"""
import os, sys, json, time, gc, socket
os.environ["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + os.environ.get("PATH", "")
import argparse
import subprocess
import tempfile
import shutil
import threading
import importlib
import inspect

parser = argparse.ArgumentParser()
parser.add_argument("audio_path")
parser.add_argument("out_dir")
parser.add_argument("--engine", default="funASR")
parser.add_argument("--model-id", default="paraformer-zh + cam++")
parser.add_argument("--device", default="cpu")
parser.add_argument("--threads", type=int, default=4)
parser.add_argument("--batch-size-s", type=int, default=60)
parser.add_argument("--merge-length-s", type=int, default=15)
parser.add_argument("--speaker-diarization", default="1")
parser.add_argument("--language", default="zh")
parser.add_argument("--ipc-port", type=int, default=None)
args = parser.parse_args()

audio_path = args.audio_path
out_dir = args.out_dir
os.makedirs(out_dir, exist_ok=True)

base = os.path.splitext(os.path.basename(audio_path))[0]
out_json = os.path.join(out_dir, f"{base}_funasr.json")
out_md = os.path.join(out_dir, f"{base}_通话记录.md")
out_speaker_map = os.path.join(out_dir, f"{base}_speaker_map.json")

# ---- 资源限制：必须在任何模型 import 之前设置 ----
threads = max(1, min(args.threads, os.cpu_count() or 4))
os.environ["OMP_NUM_THREADS"] = str(threads)
os.environ["MKL_NUM_THREADS"] = str(threads)
os.environ["OPENBLAS_NUM_THREADS"] = str(threads)
os.environ["VECLIB_MAXIMUM_THREADS"] = str(threads)
os.environ["NUMEXPR_NUM_THREADS"] = str(threads)
os.environ["TOKENIZERS_PARALLELISM"] = "false"
os.environ["PYTHONUNBUFFERED"] = "1"

# ---- 结构化进度输出 ----
import atexit

ipc_socket = None

def init_ipc():
    global ipc_socket
    if args.ipc_port is not None:
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.settimeout(5.0)
            s.connect(("127.0.0.1", args.ipc_port))
            ipc_socket = s
        except Exception as e:
            print(f"[IPC Error] Failed to connect to IPC port {args.ipc_port}: {e}", file=sys.stderr, flush=True)

def close_ipc():
    global ipc_socket
    if ipc_socket is not None:
        try:
            ipc_socket.close()
        except Exception:
            pass
        ipc_socket = None

init_ipc()
atexit.register(close_ipc)

def send_ipc_payload(payload):
    print(json.dumps(payload, ensure_ascii=False), flush=True)
    global ipc_socket
    if args.ipc_port is not None:
        if ipc_socket is None:
            try:
                s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                s.settimeout(2.0)
                s.connect(("127.0.0.1", args.ipc_port))
                ipc_socket = s
            except Exception:
                pass

        if ipc_socket is not None:
            try:
                data = json.dumps(payload, ensure_ascii=False) + "\n"
                ipc_socket.sendall(data.encode('utf-8'))
            except Exception as e:
                print(f"[IPC Error] Failed to send TCP payload to port {args.ipc_port}: {e}", file=sys.stderr, flush=True)
                try:
                    ipc_socket.close()
                except Exception:
                    pass
                ipc_socket = None


def emit_progress(stage, percent, processed_seconds=0, total_seconds=0):
    """输出 JSON 格式的进度信息供 Swift 端解析"""
    payload = {
        "type": "progress",
        "stage": stage,
        "percent": round(percent, 1),
        "processed_seconds": round(processed_seconds, 1),
        "total_seconds": round(total_seconds, 1),
    }
    send_ipc_payload(payload)


def emit_duration(total_seconds):
    """输出音频总时长"""
    payload = {"type": "duration", "total_seconds": round(total_seconds, 1)}
    send_ipc_payload(payload)


def emit_error(code, message, suggestion=""):
    """输出结构化错误信息"""
    payload = {
        "type": "error",
        "code": code,
        "message": message,
        "suggestion": suggestion,
    }
    send_ipc_payload(payload)


def emit_log(message, level="info"):
    """输出结构化日志信息供 Swift 端实时显示"""
    payload = {
        "type": "log",
        "level": level,
        "message": message,
    }
    send_ipc_payload(payload)


def format_seconds(seconds):
    seconds = max(0, int(seconds))
    minutes, sec = divmod(seconds, 60)
    if minutes:
        return f"{minutes}分{sec:02d}秒"
    return f"{sec}秒"


_qwen3_chunk_start_times = {}

def emit_qwen3_progress(event):
    """把 mlx-qwen3-asr 的内部进度转换为 VoiceScribe 进度与日志。"""
    global _qwen3_chunk_start_times
    name = str(event.get("event", "progress"))
    total_chunks = int(event.get("total_chunks") or event.get("file_total") or 1)
    chunk_index = int(event.get("chunk_index") or event.get("file_index") or 0)
    audio_total = float(event.get("audio_duration_sec") or audio_duration or 0)
    processed = float(event.get("processed_audio_sec") or 0)
    raw_progress = float(event.get("progress") or 0)
    percent = 25 + min(max(raw_progress, 0), 1) * 63

    if name == "batch_file_started":
        emit_log(f"Qwen3-ASR 开始处理音频文件 {chunk_index}/{total_chunks}")
    elif name == "chunks_prepared":
        emit_progress(f"Qwen3-ASR 已切分 {total_chunks} 个音频块", 28, 0, audio_total)
        emit_log(f"Qwen3-ASR 已切分为 {total_chunks} 个音频块，开始 MLX 转写")
    elif name == "chunk_started":
        _qwen3_chunk_start_times[chunk_index] = time.time()
        emit_progress(f"Qwen3-ASR 转写音频块 {chunk_index}/{total_chunks}", percent, processed, audio_total)
        emit_log(f"Qwen3-ASR 正在转写音频块 {chunk_index}/{total_chunks}")
    elif name == "chunk_completed":
        elapsed = 0.0
        if chunk_index in _qwen3_chunk_start_times:
            elapsed = time.time() - _qwen3_chunk_start_times[chunk_index]
        chunk_dur = float(event.get("chunk_duration_sec") or 0)
        tokens = int(event.get("generated_tokens") or 0)
        speed_msg = f"Qwen3-ASR 已完成音频块 {chunk_index}/{total_chunks}"
        if elapsed > 0:
            rtf = chunk_dur / elapsed
            if tokens > 0:
                tok_sec = tokens / elapsed
                speed_msg += f" (耗时: {elapsed:.2f}秒, 速度: {rtf:.1f}x 倍速, {tok_sec:.1f} tokens/s)"
            else:
                speed_msg += f" (耗时: {elapsed:.2f}秒, 速度: {rtf:.1f}x 倍速)"
        else:
            speed_msg += f" (已完成)"
        emit_progress(f"Qwen3-ASR 完成音频块 {chunk_index}/{total_chunks}", percent, processed, audio_total)
        emit_log(speed_msg)
    elif name == "diarization_completed":
        count = int(event.get("speaker_segment_count") or 0)
        emit_progress("pyannote 说话人分离完成", 90, audio_total, audio_total)
        emit_log(f"pyannote 说话人分离完成，得到 {count} 个说话人片段")
    elif name == "completed":
        emit_progress("Qwen3-ASR 转写完成", 92, audio_total, audio_total)
        emit_log("Qwen3-ASR 全流程完成，开始解析结果")
    else:
        emit_log(f"Qwen3-ASR 进度事件: {name}")


def install_qwen3_diarization_logging(qwen3_module, total_seconds):
    """为 mlx-qwen3-asr 的 pyannote 阶段补充开始、心跳和完成日志。"""
    original_infer = getattr(qwen3_module, "infer_speaker_turns", None)
    if not callable(original_infer) or getattr(original_infer, "_voicescribe_logged", False):
        return

    def wrapped_infer_speaker_turns(audio, *, sr, config, _pipeline=None):
        audio_seconds = float(len(audio) / sr) if sr else float(total_seconds or 0)
        min_speakers = getattr(config, "min_speakers", 1)
        max_speakers = getattr(config, "max_speakers", 8)
        fixed_speakers = getattr(config, "num_speakers", None)
        speaker_hint = f"固定 {fixed_speakers} 人" if fixed_speakers else f"{min_speakers}-{max_speakers} 人"
        started_at = time.time()
        stop_event = threading.Event()
        try:
            heartbeat_seconds = float(os.environ.get("VOICESCRIBE_DIARIZATION_HEARTBEAT_SECONDS", "15"))
        except ValueError:
            heartbeat_seconds = 15.0
        heartbeat_seconds = max(0.1, heartbeat_seconds)

        emit_progress("pyannote 说话人分离中...", 89, 0, audio_seconds)
        emit_log(
            "pyannote 说话人分离开始："
            f"音频 {format_seconds(audio_seconds)}，说话人范围 {speaker_hint}；"
            "该阶段会执行 VAD、声纹 embedding 与聚类，主要使用 CPU"
        )

        def heartbeat():
            while not stop_event.wait(heartbeat_seconds):
                elapsed = time.time() - started_at
                emit_progress(f"pyannote 说话人分离中... 已耗时 {format_seconds(elapsed)}", 89, 0, audio_seconds)
                emit_log(
                    "pyannote 仍在运行："
                    f"已耗时 {format_seconds(elapsed)}，正在执行 VAD/embedding/聚类；"
                    "长音频或说话人较多时 CPU 占用会较高"
                )

        monitor = threading.Thread(target=heartbeat, daemon=True)
        monitor.start()
        try:
            turns = original_infer(audio, sr=sr, config=config, _pipeline=_pipeline)
        finally:
            stop_event.set()

        elapsed = time.time() - started_at
        speakers = sorted({str(turn.get("speaker", "")) for turn in turns if turn.get("speaker")})
        emit_log(
            "pyannote pipeline 完成："
            f"耗时 {format_seconds(elapsed)}，speaker turn {len(turns)} 个，"
            f"检测到 {len(speakers)} 个说话人标签"
        )
        emit_progress("pyannote 正在合并说话人片段...", 90, audio_seconds, audio_seconds)
        return turns

    wrapped_infer_speaker_turns._voicescribe_logged = True
    qwen3_module.infer_speaker_turns = wrapped_infer_speaker_turns


def call_qwen3_transcribe(qwen3_transcribe, audio_path, **kwargs):
    """Call mlx-qwen3-asr while tolerating versions without optional callbacks."""
    try:
        signature = inspect.signature(qwen3_transcribe)
        parameters = signature.parameters
        accepts_kwargs = any(
            parameter.kind == inspect.Parameter.VAR_KEYWORD
            for parameter in parameters.values()
        )
        if not accepts_kwargs:
            kwargs = {
                key: value
                for key, value in kwargs.items()
                if key in parameters
            }
    except (TypeError, ValueError):
        pass
    return qwen3_transcribe(audio_path, **kwargs)


def get_audio_duration(path):
    """使用 ffprobe 获取音频时长（秒）"""
    try:
        result = subprocess.run(
            ["ffprobe", "-v", "quiet", "-show_entries", "format=duration",
             "-of", "csv=p=0", path],
            capture_output=True, text=True, timeout=10
        )
        duration = float(result.stdout.strip())
        return duration
    except Exception:
        return None


def validate_input_audio(path):
    """在进入 ffmpeg / 模型加载前校验输入音频，避免底层错误淹没有效提示。"""
    if not os.path.isfile(path):
        emit_error(
            "input_file_missing",
            f"输入音频文件不存在: {path}",
            "请重新选择音频文件；如果文件在 iCloud、外接盘或移动硬盘，请确认文件已下载且磁盘已连接",
        )
        sys.exit(1)

    if not os.access(path, os.R_OK):
        emit_error(
            "input_file_unreadable",
            f"输入音频文件不可读取: {path}",
            "请检查文件权限，或把文件复制到本地目录后重新选择",
        )
        sys.exit(1)


def role_name_from_index(index):
    alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    if index < len(alphabet):
        return f"角色{alphabet[index]}"
    return f"角色{index + 1}"


def seconds_to_timestamp(seconds):
    total = int(max(0, seconds))
    return f"{total//60:02d}:{total%60:02d}"


def build_role_mapping(speaker_keys):
    mapping = {}
    roles = []
    for idx, key in enumerate(speaker_keys):
        placeholder = role_name_from_index(idx)
        key_str = str(key)
        mapping[key_str] = placeholder
        roles.append({
            "key": key_str,
            "placeholder": placeholder,
            "displayName": placeholder,
        })
    return mapping, roles


def _extract_segments_from_funasr(result):
    """从 FunASR 结果中提取 segments：优先用 _unwrap_result_object，兼容新旧 API"""
    item = result[0]
    _, segments = _unwrap_result_object(item)
    if segments:
        # 标准化为新版格式 speaker_id + text
        norm = []
        for s in segments:
            norm.append({
                "spk": str(s.get("speaker_id", s.get("spk", s.get("Speaker", "0")))),
                "text": s.get("text", s.get("Content", "")),
                "start": int(float(s.get("start", s.get("Start", 0))) * 1000),
                "end": int(float(s.get("end", s.get("End", 0))) * 1000),
            })
        return norm

    # 兜底：旧版 sentence_info
    if isinstance(item, dict):
        segs = item.get("sentence_info", [])
        if segs:
            return segs
        raw_text = item.get("text", "")
        if raw_text and len(str(raw_text)) > 20:
            print("[VoiceScribe] 警告: FunASR 仅返回全文，无分段信息")
            return [{"spk": "0", "text": str(raw_text), "start": 0, "end": 0}]
    return []


def format_funasr_markdown(result):
    if not result or not isinstance(result, list) or len(result) == 0:
        print("[VoiceScribe] 警告: FunASR 返回空结果")
        return {"engine": "funASR", "raw": result}, [f"# {base} 通话记录\n", "（转写结果为空，请检查音频文件是否包含有效语音）"], [], []

    segments = _extract_segments_from_funasr(result)
    if not segments:
        # 最后兜底：尝试直接读 result[0] 的 text 属性
        item = result[0]
        raw_text = ""
        if hasattr(item, "text"):
            raw_text = str(item.text)
        elif isinstance(item, dict):
            raw_text = str(item.get("text", ""))
        if raw_text and len(raw_text) > 20:
            print("[VoiceScribe] 警告: 未能解析分段，保存原始文本")
            return {"engine": "funASR", "raw": result}, [f"# {base} 通话记录\n", raw_text], [], []
        print("[VoiceScribe] 警告: FunASR 未检测到语音片段，请检查音频内容")
        return {"engine": "funASR", "raw": result}, [f"# {base} 通话记录\n", "（未检测到语音内容）"], [], []

    speaker_keys = []
    for seg in segments:
        speaker_key = str(seg.get("spk", "?"))
        if speaker_key not in speaker_keys:
            speaker_keys.append(speaker_key)
    speaker_mapping, roles = build_role_mapping(speaker_keys)

    lines = [f"# {base} 通话记录\n"]
    normalized_segments = []
    for seg in segments:
        start_ms = int(seg.get("start", 0))
        end_ms = int(seg.get("end", 0))
        t_start = f"{start_ms//60000:02d}:{(start_ms%60000)//1000:02d}"
        spk = str(seg.get("spk", "?"))
        text = seg.get("text", "")
        if not text.strip():
            continue
        placeholder = speaker_mapping.get(spk, "角色?")
        lines.append(f"[{t_start}] 【{placeholder}】 {text}")
        normalized_segments.append({
            "speakerKey": spk,
            "placeholder": placeholder,
            "start": start_ms / 1000.0,
            "end": end_ms / 1000.0,
            "text": text,
        })
    return {"engine": "funASR", "raw": result}, lines, roles, normalized_segments


def _unwrap_result_object(result):
    """通用结果解析：兼容 dict、STTOutput、以及其他带 .segments / .text 的对象"""
    if isinstance(result, dict):
        return result.get("text", ""), result.get("segments", [])
    if hasattr(result, "segments"):
        text = str(result.text) if hasattr(result, "text") else str(result)
        segs = list(result.segments) if result.segments else []
        return text, segs
    if hasattr(result, "text"):
        text = str(result.text)
        # STTOutput.text 可能是 JSON 字符串
        if text.startswith("[") or text.startswith("{"):
            import json as _json
            try:
                parsed = _json.loads(text)
                if isinstance(parsed, list):
                    segs = []
                    for s in parsed:
                        segs.append({
                            "start": float(s.get("Start", s.get("start", 0))),
                            "end": float(s.get("End", s.get("end", 0))),
                            "speaker_id": str(s.get("Speaker", s.get("speaker_id", s.get("spk", "0")))),
                            "text": s.get("Content", s.get("text", "")),
                        })
                    return text, segs
                elif isinstance(parsed, dict):
                    return text, parsed.get("segments", [])
            except (_json.JSONDecodeError, TypeError):
                pass
        return text, []
    return str(result), []


def normalize_mlx_result(result):
    text, segments = _unwrap_result_object(result)
    return {"text": text, "segments": segments}


def format_mlx_markdown(result):
    payload = normalize_mlx_result(result)
    segments = payload.get("segments", [])
    speaker_keys = []
    for seg in segments:
        speaker_key = str(seg.get("speaker_id", seg.get("speaker", "?")))
        if speaker_key not in speaker_keys:
            speaker_keys.append(speaker_key)
    speaker_mapping, roles = build_role_mapping(speaker_keys)

    lines = [f"# {base} 通话记录\n"]
    normalized_segments = []
    if segments:
        for seg in segments:
            start = float(seg.get("start", 0))
            end = float(seg.get("end", 0))
            t_start = seconds_to_timestamp(start)
            speaker_id = str(seg.get("speaker_id", seg.get("speaker", "?")))
            text = seg.get("text", "").strip()
            if not text:
                continue
            placeholder = speaker_mapping.get(speaker_id, "角色?")
            lines.append(f"[{t_start}] 【{placeholder}】 {text}")
            normalized_segments.append({
                "speakerKey": speaker_id,
                "placeholder": placeholder,
                "start": start,
                "end": end,
                "text": text,
            })
    else:
        lines.append(payload.get("text", "").strip())
    return payload, lines, roles, normalized_segments


def format_whisper_mlx_markdown(result):
    """Format mlx-whisper dict output into the shared transcript and speaker-map contract."""
    if not isinstance(result, dict):
        text, segments = _unwrap_result_object(result)
        payload = {"engine": "whisperMLX", "text": text, "segments": segments}
    else:
        payload = {
            "engine": "whisperMLX",
            "text": result.get("text", ""),
            "language": result.get("language"),
            "segments": result.get("segments", []),
        }

    speaker_mapping, roles = build_role_mapping(["0"])
    placeholder = speaker_mapping["0"]
    lines = [f"# {base} 通话记录\n"]
    normalized_segments = []
    segments = payload.get("segments") or []

    for seg in segments:
        text = (seg.get("text", "") or "").strip()
        if not text:
            continue
        start = float(seg.get("start", 0) or 0)
        end = float(seg.get("end", start) or start)
        t_start = seconds_to_timestamp(start)
        lines.append(f"[{t_start}] 【{placeholder}】 {text}")
        normalized_segments.append({
            "speakerKey": "0",
            "placeholder": placeholder,
            "start": start,
            "end": end,
            "text": text,
        })

    if not normalized_segments:
        text = str(payload.get("text") or "").strip()
        if text:
            lines.append(text)
            normalized_segments.append({
                "speakerKey": "0",
                "placeholder": placeholder,
                "start": 0.0,
                "end": 0.0,
                "text": text,
            })
        else:
            emit_error("no_segments", "Whisper MLX produced no output", "Check if audio contains valid speech")
            sys.exit(1)

    return payload, lines, roles, normalized_segments


def format_qwen3_markdown(result, diarize_enabled):
    """Parse mlx-qwen3-asr TranscriptionResult into markdown + normalized segments."""
    if diarize_enabled and result.speaker_segments:
        segments = result.speaker_segments
        # speaker_segments: [{speaker, start, end, text}, ...]
    elif result.segments:
        segments = result.segments
        # segments: [{text, start, end}, ...] — no speaker, assign default
        for s in segments:
            s["speaker"] = "0"
    elif result.text and len(result.text.strip()) > 0:
        full_text = result.text.strip()
        return (
            {"engine": "qwen3ASR", "text": full_text, "language": result.language},
            [f"# {base} 通话记录\n", full_text],
            [{"key": "0", "placeholder": "Speaker", "displayName": "Speaker"}],
            [{"speakerKey": "0", "placeholder": "Speaker", "start": 0.0, "end": 0.0, "text": full_text}],
        )
    else:
        emit_error("no_segments", "Qwen3-ASR produced no output", "Check if audio contains valid speech")
        sys.exit(1)

    speaker_keys = []
    for seg in segments:
        spk = str(seg.get("speaker", "0"))
        if spk not in speaker_keys:
            speaker_keys.append(spk)
    speaker_mapping, roles = build_role_mapping(speaker_keys)

    lines = [f"# {base} 通话记录\n"]
    normalized_segments = []
    for seg in segments:
        start = float(seg.get("start", 0))
        end = float(seg.get("end", 0))
        t_start = seconds_to_timestamp(start)
        spk = str(seg.get("speaker", "0"))
        text = (seg.get("text", "") or "").strip()
        if not text:
            continue
        placeholder = speaker_mapping.get(spk, "角色?")
        lines.append(f"[{t_start}] 【{placeholder}】 {text}")
        normalized_segments.append({
            "speakerKey": spk,
            "placeholder": placeholder,
            "start": start,
            "end": end,
            "text": text,
        })

    return (
        {"engine": "qwen3ASR", "text": result.text, "language": result.language,
         "segments": list(result.segments) if result.segments else None,
         "speaker_segments": list(result.speaker_segments) if result.speaker_segments else None},
        lines,
        roles,
        normalized_segments,
    )


def prepare_audio(source_path):
    """将所有音频统一转为 16kHz 单声道 WAV，确保转写引擎能可靠处理。"""
    if not os.path.isfile(source_path):
        raise RuntimeError(f"输入音频文件不存在: {source_path}")

    suffix = os.path.splitext(source_path)[1].lower()
    if suffix in [".wav", ".wave"]:
        # 验证是否是 16kHz 单声道，不是则需要转换
        try:
            result = subprocess.run(
                ["ffprobe", "-v", "quiet", "-select_streams", "a:0",
                 "-show_entries", "stream=sample_rate,channels",
                 "-of", "csv=p=0", source_path],
                capture_output=True, text=True, timeout=10
            )
            info = result.stdout.strip()
            if info == "16000,1":
                return source_path, None
            print(f"[VoiceScribe] WAV 格式不符 ({info})，将转换为标准 16kHz 单声道")
        except Exception:
            pass

    temp_dir = tempfile.mkdtemp(prefix="audio_transcriber_")
    converted_path = os.path.join(temp_dir, "input.wav")
    command = [
        "ffmpeg", "-y",
        "-i", source_path,
        "-ac", "1",
        "-ar", "16000",
        "-sample_fmt", "s16",
        converted_path,
    ]
    print(f"[VoiceScribe] 预处理: 转换 {suffix or 'unknown'} → 16kHz 单声道 WAV")
    try:
        subprocess.run(command, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120)
    except subprocess.CalledProcessError as e:
        message = e.stderr.decode("utf-8", errors="ignore").strip()
        raise RuntimeError(f"ffmpeg 转换失败: {message}") from e
    except subprocess.TimeoutExpired:
        raise RuntimeError("ffmpeg 转换超时（120s），请检查音频文件是否完整")
    return converted_path, temp_dir


validate_input_audio(audio_path)

# 限制 PyTorch 线程（如果安装了 torch）。放在输入校验之后，避免无效路径还触发重依赖初始化。
try:
    import torch
    torch.set_num_threads(threads)
    torch.set_num_interop_threads(threads)
    print(f"[VoiceScribe] PyTorch 线程限制为 {threads}")
except ImportError:
    pass

print(f"[VoiceScribe] 音频: {audio_path}")
print(f"[VoiceScribe] 输出: {out_dir}")
print(f"[VoiceScribe] 引擎: {args.engine}")
print(f"[VoiceScribe] 模型: {args.model_id}")
print(f"[VoiceScribe] 线程数: {threads}, 批处理: {args.batch_size_s}s, 语言: {args.language}")

emit_progress("准备中...", 0)

t0 = time.time()
temp_cleanup_dir = None

# ---- 获取音频时长 ----
audio_duration = get_audio_duration(audio_path)
if audio_duration:
    emit_duration(audio_duration)
    print(f"[VoiceScribe] 音频时长: {audio_duration:.1f} 秒")

# ---- 音频预处理（所有引擎统一） ----
emit_progress("音频预处理...", 5, 0, audio_duration or 0)
try:
    prepared_audio_path, temp_cleanup_dir = prepare_audio(audio_path)
except RuntimeError as e:
    emit_error("audio_convert_failed", str(e), "请确认音频文件完整且 ffmpeg 已正确安装")
    sys.exit(1)

emit_progress("加载模型...", 10, 0, audio_duration or 0)

# ---- 转写 ----
if args.engine == "vibeVoiceMLX":
    try:
        from mlx_audio.stt.utils import load_model as load
    except ModuleNotFoundError:
        emit_error("missing_dependency", "当前 Python 环境未安装 mlx_audio", "请在设置中点击'安装依赖'按钮")
        sys.exit(1)

    try:
        emit_progress("加载 MLX 模型...", 15, 0, audio_duration or 0)
        model = load(args.model_id)
        emit_progress("MLX 转写中...", 25, 0, audio_duration or 0)
        mlx_start = time.time()
        res = model.generate(prepared_audio_path)
        mlx_elapsed = time.time() - mlx_start
        if audio_duration and mlx_elapsed > 0:
            mlx_rtf = audio_duration / mlx_elapsed
            emit_log(f"MLX 转写完成 (耗时: {mlx_elapsed:.2f}秒, 速度: {mlx_rtf:.1f}x 倍速)")
        else:
            emit_log(f"MLX 转写完成 (耗时: {mlx_elapsed:.2f}秒)")
        emit_progress("解析结果...", 90, audio_duration or 0, audio_duration or 0)
        save_payload, lines, roles, normalized_segments = format_mlx_markdown(res)
    except MemoryError:
        emit_error("out_of_memory", "内存不足，模型加载或转写过程中耗尽内存", "请降低性能档位或关闭其他应用后重试")
        sys.exit(137)
    except Exception as e:
        emit_error("transcription_failed", f"VibeVoice MLX 转写失败: {e}", "请检查模型是否已正确下载，或尝试重新预热环境")
        sys.exit(1)
elif args.engine == "whisperMLX":
    try:
        import mlx_whisper
    except ModuleNotFoundError:
        emit_error("missing_dependency", "当前 Python 环境未安装 mlx-whisper", "请在设置中点击'安装依赖'按钮")
        sys.exit(1)

    try:
        emit_progress("加载 Whisper MLX 模型...", 15, 0, audio_duration or 0)
        whisper_start = time.time()
        result = mlx_whisper.transcribe(
            prepared_audio_path,
            path_or_hf_repo=args.model_id,
            language=args.language,
            task="transcribe",
            verbose=False,
            initial_prompt="以下是简体中文的转录内容：",
        )
        whisper_elapsed = time.time() - whisper_start
        if audio_duration and whisper_elapsed > 0:
            whisper_rtf = audio_duration / whisper_elapsed
            emit_log(f"Whisper MLX 转写完成 (耗时: {whisper_elapsed:.2f}秒, 速度: {whisper_rtf:.1f}x 倍速)")
        else:
            emit_log(f"Whisper MLX 转写完成 (耗时: {whisper_elapsed:.2f}秒)")
        emit_progress("解析结果...", 90, audio_duration or 0, audio_duration or 0)
        save_payload, lines, roles, normalized_segments = format_whisper_mlx_markdown(result)
    except MemoryError:
        emit_error("out_of_memory", "内存不足，Whisper MLX 模型加载或转写过程中耗尽内存", "请降低性能档位或改用更小的 Whisper 模型")
        sys.exit(137)
    except Exception as e:
        emit_error("transcription_failed", f"Whisper MLX 转写失败: {e}", "请检查 mlx-whisper 依赖和模型缓存是否已准备好")
        sys.exit(1)
elif args.engine == "qwen3ASR":
    # ---- Qwen3-ASR via Python API (supports speaker diarization) ----
    # Parse model-id: supports "REPO" or "REPO:dtype=X" suffix
    import mlx.core as mx
    dtype = mx.float16
    dtype_str = "float16"
    model_id = args.model_id
    if ":" in model_id:
        parts = model_id.split(":", 1)
        model_id = parts[0]
        if "=" in parts[1]:
            dtype_str = parts[1].split("=", 1)[1].strip()
            dtype_map = {"float16": mx.float16, "float32": mx.float32, "bfloat16": mx.bfloat16}
            dtype = dtype_map.get(dtype_str, mx.float16)

    try:
        qwen3_module = importlib.import_module("mlx_qwen3_asr.transcribe")
        qwen3_transcribe = qwen3_module.transcribe
    except ModuleNotFoundError:
        emit_error("missing_dependency", "Qwen3-ASR not installed: pip install mlx-qwen3-asr", "Install deps in settings")
        sys.exit(1)

    use_diarize = args.speaker_diarization != "0"
    if use_diarize:
        install_qwen3_diarization_logging(qwen3_module, audio_duration or 0)
    emit_progress(f"Loading Qwen3-ASR {model_id}...", 15, 0, audio_duration or 0)

    try:
        emit_progress(f"Qwen3-ASR transcribing dtype={dtype_str} diarize={use_diarize}...", 25, 0, audio_duration or 0)
        result = call_qwen3_transcribe(
            qwen3_transcribe,
            prepared_audio_path,
            model=model_id,
            dtype=dtype,
            diarize=use_diarize,
            verbose=True,
            on_progress=emit_qwen3_progress,
        )
    except Exception as e:
        if use_diarize and ("pyannote" in str(e).lower() or "diariz" in str(e).lower()):
            emit_progress("pyannote not available, retrying without diarization...", 30, 0, audio_duration or 0)
            use_diarize = False
            try:
                result = call_qwen3_transcribe(
                    qwen3_transcribe,
                    prepared_audio_path,
                    model=model_id,
                    dtype=dtype,
                    diarize=False,
                    verbose=True,
                    on_progress=emit_qwen3_progress,
                )
            except Exception as e2:
                emit_error("transcription_failed", f"Qwen3-ASR error: {e2}", "Check deps and model installation")
                sys.exit(1)
        else:
            emit_error("transcription_failed", f"Qwen3-ASR error: {e}", "Check deps and model installation")
            sys.exit(1)

    emit_progress("Parsing results...", 90, audio_duration or 0, audio_duration or 0)
    save_payload, lines, roles, normalized_segments = format_qwen3_markdown(result, use_diarize)

else:
    try:
        from funasr import AutoModel
    except ModuleNotFoundError:
        emit_error("missing_dependency", "当前 Python 环境未安装 funasr", "请在设置中点击'安装依赖'按钮")
        sys.exit(1)

    try:
        emit_progress("加载 FunASR 模型...", 15, 0, audio_duration or 0)

        model_id = args.model_id
        # Build model_kwargs based on model type
        if "SenseVoice" in model_id:
            # SenseVoiceSmall: unified model, built-in VAD + punctuation
            model_kwargs = {
                "model": model_id.replace("iic/speech_SenseVoiceSmall", "iic/speech_SenseVoiceSmall"),
                "device": args.device if args.device != "mlx" else "cpu",
                "disable_update": True,
                "ncpu": threads,
            }
            # SenseVoiceSmall doesn't support cam++ speaker diarization
            if args.speaker_diarization == "1":
                print("[VoiceScribe] SenseVoiceSmall 不支持说话人区分，将标注为同一说话人")
        elif "Fun-ASR-Nano" in model_id or "FunAudioLLM" in model_id:
            model_kwargs = {
                "model": model_id,
                "device": args.device if args.device != "mlx" else "cpu",
                "disable_update": True,
                "ncpu": threads,
            }
            if args.speaker_diarization == "1":
                print("[VoiceScribe] Fun-ASR-Nano 不支持 cam++ 说话人区分")
        else:
            # Default: paraformer-zh + cam++
            model_kwargs = {
                "model": "paraformer-zh",
                "vad_model": "fsmn-vad",
                "punc_model": "ct-punc",
                "device": args.device if args.device != "mlx" else "cpu",
                "disable_update": True,
                "ncpu": threads,
            }
            if args.speaker_diarization == "1":
                model_kwargs["spk_model"] = "cam++"

        model = AutoModel(**model_kwargs)

        emit_progress("转写中...", 25, 0, audio_duration or 0)
        funasr_start = time.time()

        # Generate with model-appropriate parameters
        if "SenseVoice" in model_id:
            res = model.generate(input=prepared_audio_path)
        elif "Fun-ASR-Nano" in model_id or "FunAudioLLM" in model_id:
            res = model.generate(input=prepared_audio_path, language=args.language)
        else:
            # 大文件分段处理
            chunk_duration = args.batch_size_s * 30
            if audio_duration and audio_duration > 1800:
                total_chunks = max(1, int(audio_duration / chunk_duration) + 1)
                print(f"[VoiceScribe] 大文件模式：预计分 {total_chunks} 段处理")
                emit_progress(f"转写中（大文件模式）...", 25, 0, audio_duration)

            res = model.generate(
                input=prepared_audio_path,
                batch_size_s=args.batch_size_s,
                merge_vad=True,
                merge_length_s=args.merge_length_s,
                language=args.language,
            )
        funasr_elapsed = time.time() - funasr_start
        if audio_duration and funasr_elapsed > 0:
            funasr_rtf = audio_duration / funasr_elapsed
            emit_log(f"FunASR 转写完成 (耗时: {funasr_elapsed:.2f}秒, 速度: {funasr_rtf:.1f}x 倍速)")
        else:
            emit_log(f"FunASR 转写完成 (耗时: {funasr_elapsed:.2f}秒)")

        emit_progress("解析结果...", 90, audio_duration or 0, audio_duration or 0)
        save_payload, lines, roles, normalized_segments = format_funasr_markdown(res)
    except MemoryError:
        emit_error("out_of_memory", "内存不足，模型加载或转写过程中耗尽内存", "请降低性能档位或关闭其他应用后重试")
        sys.exit(137)
    except Exception as e:
        error_msg = str(e)
        suggestion = "请检查日志中的详细错误信息"
        if "model" in error_msg.lower() and ("not found" in error_msg.lower() or "download" in error_msg.lower()):
            suggestion = "模型文件可能未下载完整，请在设置中点击'下载模型'重新下载"
        elif "memory" in error_msg.lower() or "oom" in error_msg.lower():
            suggestion = "内存不足，请降低性能档位或关闭其他应用后重试"
        emit_error("transcription_failed", f"FunASR 转写失败: {e}", suggestion)
        sys.exit(1)

elapsed = time.time() - t0
emit_progress("保存结果...", 95, audio_duration or 0, audio_duration or 0)

# 保存 JSON
with open(out_json, 'w', encoding='utf-8') as f:
    json.dump(save_payload, f, ensure_ascii=False, indent=2)
print(f"[VoiceScribe] JSON已保存: {out_json}")

with open(out_md, 'w', encoding='utf-8') as f:
    f.write('\n'.join(lines))
print(f"[VoiceScribe] 文本已保存: {out_md}")

speaker_map_payload = {
    "title": base,
    "roles": roles,
    "segments": normalized_segments,
}
with open(out_speaker_map, 'w', encoding='utf-8') as f:
    json.dump(speaker_map_payload, f, ensure_ascii=False, indent=2)
print(f"[VoiceScribe] 角色映射已保存: {out_speaker_map}")

segment_count = len(normalized_segments)
if segment_count == 0:
    emit_error("no_segments", "转写结果中没有语音片段",
               "请检查：1) 音频是否包含有效语音 2) 语言是否匹配 3) 音频质量是否清晰")
print(f"[VoiceScribe] 共 {segment_count} 个片段")

emit_progress("完成", 100, audio_duration or 0, audio_duration or 0)
print(f"[VoiceScribe] Done in {elapsed:.1f}s")

# 主动释放模型内存
if 'model' in dir():
    del model
gc.collect()

if temp_cleanup_dir and os.path.isdir(temp_cleanup_dir):
    try:
        shutil.rmtree(temp_cleanup_dir)
    except Exception:
        pass
