#!/usr/bin/env python3
"""
VoiceScribe - 转写脚本
用法: python3 transcribe.py <音频路径> <输出目录>
"""
import os, sys, json, time, gc
import argparse
import subprocess
import tempfile
import shutil

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

# 限制 PyTorch 线程（如果安装了 torch）
try:
    import torch
    torch.set_num_threads(threads)
    torch.set_num_interop_threads(threads)
    print(f"[VoiceScribe] PyTorch 线程限制为 {threads}")
except ImportError:
    pass


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


def prepare_audio(source_path):
    """将所有音频统一转为 16kHz 单声道 WAV，确保转写引擎能可靠处理。"""
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


print(f"[VoiceScribe] 音频: {audio_path}")
print(f"[VoiceScribe] 输出: {out_dir}")
print(f"[VoiceScribe] 引擎: {args.engine}")
print(f"[VoiceScribe] 模型: {args.model_id}")
print(f"[VoiceScribe] 线程数: {threads}, 批处理: {args.batch_size_s}s, 语言: {args.language}")
print(f"[VoiceScribe] 加载模型中...")

t0 = time.time()
temp_cleanup_dir = None

# ---- 音频预处理（所有引擎统一） ----
try:
    prepared_audio_path, temp_cleanup_dir = prepare_audio(audio_path)
except RuntimeError as e:
    print(f"[VoiceScribe] 错误: {e}")
    sys.exit(1)

# ---- 转写 ----
if args.engine == "vibeVoiceMLX":
    try:
        from mlx_audio.stt.utils import load
    except ModuleNotFoundError:
        print("[VoiceScribe] 错误: 当前 Python 环境未安装 mlx_audio，请先安装 VibeVoice MLX 依赖后再试。")
        sys.exit(1)

    try:
        print(f"[VoiceScribe] STATUS: 开始 MLX 转写...")
        model = load(args.model_id)
        res = model.generate(prepared_audio_path)
        save_payload, lines, roles, normalized_segments = format_mlx_markdown(res)
    except Exception as e:
        print(f"[VoiceScribe] ERROR: VibeVoice MLX 转写失败: {e}")
        sys.exit(1)
else:
    try:
        from funasr import AutoModel
    except ModuleNotFoundError:
        print("[VoiceScribe] 错误: 当前 Python 环境未安装 funasr，请先安装 FunASR 依赖后再试。")
        sys.exit(1)

    try:
        print(f"[VoiceScribe] STATUS: 加载 FunASR 模型（语言: {args.language}）...")
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

        print(f"[VoiceScribe] STATUS: 转写中（batch={args.batch_size_s}s, merge={args.merge_length_s}s）...")
        res = model.generate(
            input=prepared_audio_path,
            batch_size_s=args.batch_size_s,
            merge_vad=True,
            merge_length_s=args.merge_length_s,
            language=args.language,
        )
        save_payload, lines, roles, normalized_segments = format_funasr_markdown(res)
    except Exception as e:
        print(f"[VoiceScribe] ERROR: FunASR 转写失败: {e}")
        sys.exit(1)

elapsed = time.time() - t0
print(f"[VoiceScribe] STATUS: 转写完成, 耗时 {elapsed:.1f}s")

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
    print("[VoiceScribe] 警告: 转写结果中没有语音片段。请检查：")
    print("[VoiceScribe]   1. 音频文件是否包含有效语音内容")
    print("[VoiceScribe]   2. 音频语言是否与模型匹配（当前模型为中文 paraformer-zh）")
    print("[VoiceScribe]   3. 音频质量是否足够清晰")
print(f"[VoiceScribe] 共 {segment_count} 个片段")
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
