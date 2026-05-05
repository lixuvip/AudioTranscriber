#!/usr/bin/env python3
"""
AudioTranscriber - 转写脚本
用法: python3 transcribe.py <音频路径> <输出目录>
"""
import os, sys, json, time
import argparse
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument("audio_path")
parser.add_argument("out_dir")
parser.add_argument("--engine", default="funASR")
parser.add_argument("--model-id", default="paraformer-zh + cam++")
parser.add_argument("--device", default="cpu")
parser.add_argument("--threads", type=int, default=4)
parser.add_argument("--batch-size-s", type=int, default=240)
parser.add_argument("--merge-length-s", type=int, default=15)
parser.add_argument("--speaker-diarization", default="1")
args = parser.parse_args()

audio_path = args.audio_path
out_dir = args.out_dir
os.makedirs(out_dir, exist_ok=True)

base = os.path.splitext(os.path.basename(audio_path))[0]
out_json = os.path.join(out_dir, f"{base}_funasr.json")
out_md = os.path.join(out_dir, f"{base}_通话记录.md")
out_speaker_map = os.path.join(out_dir, f"{base}_speaker_map.json")

os.environ['OMP_NUM_THREADS'] = str(args.threads)
os.environ['MKL_NUM_THREADS'] = str(args.threads)

print(f"[AudioTranscriber] 音频: {audio_path}")
print(f"[AudioTranscriber] 输出: {out_dir}")
print(f"[AudioTranscriber] 引擎: {args.engine}")
print(f"[AudioTranscriber] 模型: {args.model_id}")
print(f"[AudioTranscriber] 加载模型中...")


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


def format_funasr_markdown(result):
    segments = result[0].get("sentence_info", [])
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
        t_end = f"{end_ms//60000:02d}:{(end_ms%60000)//1000:02d}"
        spk = str(seg.get("spk", "?"))
        text = seg.get("text", "")
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


def normalize_mlx_result(result):
    if isinstance(result, dict):
        segments = result.get("segments", [])
        text = result.get("text", "")
        return {
            "text": text,
            "segments": segments,
        }
    return {"text": str(result), "segments": []}


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


def prepare_audio_for_mlx(source_path):
    suffix = os.path.splitext(source_path)[1].lower()
    if suffix in [".wav", ".wave", ".flac"]:
        return source_path, None

    temp_dir = tempfile.mkdtemp(prefix="audio_transcriber_mlx_")
    converted_path = os.path.join(temp_dir, "input.wav")
    command = [
        "ffmpeg",
        "-y",
        "-i", source_path,
        "-ac", "1",
        "-ar", "16000",
        converted_path,
    ]
    print(f"[AudioTranscriber] MLX 预处理中，正在转换音频为 WAV: {suffix or 'unknown'}")
    try:
        subprocess.run(command, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except subprocess.CalledProcessError as e:
        message = e.stderr.decode("utf-8", errors="ignore").strip()
        raise RuntimeError(f"ffmpeg 转换失败: {message}") from e
    return converted_path, temp_dir


print(f"[AudioTranscriber] 开始转写...")
t0 = time.time()
temp_cleanup_dir = None

if args.engine == "vibeVoiceMLX":
    try:
        from mlx_audio.stt.utils import load
    except ModuleNotFoundError:
        print("[AudioTranscriber] 错误: 当前 Python 环境未安装 mlx_audio，请先安装 VibeVoice MLX 依赖后再试。")
        sys.exit(1)

    try:
        model = load(args.model_id)
        prepared_audio_path, temp_cleanup_dir = prepare_audio_for_mlx(audio_path)
        res = model.generate(prepared_audio_path)
        save_payload, lines, roles, normalized_segments = format_mlx_markdown(res)
    except Exception as e:
        print(f"[AudioTranscriber] VibeVoice MLX 转写失败: {e}")
        sys.exit(1)
else:
    try:
        from funasr import AutoModel
    except ModuleNotFoundError:
        print("[AudioTranscriber] 错误: 当前 Python 环境未安装 funasr，请先安装 FunASR 依赖后再试。")
        sys.exit(1)

    try:
        model = AutoModel(
            model="paraformer-zh",
            vad_model="fsmn-vad",
            punc_model="ct-punc",
            spk_model="cam++" if args.speaker_diarization == "1" else None,
            device=args.device if args.device != "mlx" else "cpu",
            disable_update=True,
        )

        res = model.generate(
            input=audio_path,
            batch_size_s=args.batch_size_s,
            merge_vad=True,
            merge_length_s=args.merge_length_s,
        )
        save_payload, lines, roles, normalized_segments = format_funasr_markdown(res)
    except Exception as e:
        print(f"[AudioTranscriber] FunASR 转写失败: {e}")
        sys.exit(1)

print(f"[AudioTranscriber] 转写完成, 耗时 {time.time()-t0:.1f}s")

# 保存 JSON
with open(out_json, 'w', encoding='utf-8') as f:
    json.dump(save_payload, f, ensure_ascii=False, indent=2)
print(f"[AudioTranscriber] JSON已保存: {out_json}")

with open(out_md, 'w', encoding='utf-8') as f:
    f.write('\n'.join(lines))
print(f"[AudioTranscriber] 文本已保存: {out_md}")

speaker_map_payload = {
    "title": base,
    "roles": roles,
    "segments": normalized_segments,
}
with open(out_speaker_map, 'w', encoding='utf-8') as f:
    json.dump(speaker_map_payload, f, ensure_ascii=False, indent=2)
print(f"[AudioTranscriber] 角色映射已保存: {out_speaker_map}")

segment_count = len(normalized_segments)
print(f"[AudioTranscriber] 共 {segment_count} 个片段")
print(f"[AudioTranscriber] Done in {time.time()-t0:.1f}s")

# 主动释放模型内存
del model
import gc
gc.collect()

if temp_cleanup_dir and os.path.isdir(temp_cleanup_dir):
    try:
        import shutil
        shutil.rmtree(temp_cleanup_dir)
    except Exception:
        pass
