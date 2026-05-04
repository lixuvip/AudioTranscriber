#!/usr/bin/env python3
"""
AudioTranscriber - 转写脚本
用法: python3 transcribe.py <音频路径> <输出目录>
"""
import os, sys, json, time

if len(sys.argv) < 3:
    print("用法: python3 transcribe.py <音频路径> <输出目录>")
    sys.exit(1)

audio_path = sys.argv[1]
out_dir = sys.argv[2]
os.makedirs(out_dir, exist_ok=True)

base = os.path.splitext(os.path.basename(audio_path))[0]
out_json = os.path.join(out_dir, f"{base}_funasr.json")
out_md = os.path.join(out_dir, f"{base}_通话记录.md")

os.environ['OMP_NUM_THREADS'] = '10'
os.environ['MKL_NUM_THREADS'] = '10'

print(f"[AudioTranscriber] 音频: {audio_path}")
print(f"[AudioTranscriber] 输出: {out_dir}")
print(f"[AudioTranscriber] 加载模型中...")

from funasr import AutoModel

model = AutoModel(
    model="paraformer-zh",
    vad_model="fsmn-vad",
    punc_model="ct-punc",
    spk_model="cam++",
    device="cpu",
    disable_update=True,
)

print(f"[AudioTranscriber] 开始转写...")
t0 = time.time()
res = model.generate(
    input=audio_path,
    batch_size_s=300,
    merge_vad=True,
    merge_length_s=15,
)
print(f"[AudioTranscriber] 转写完成, 耗时 {time.time()-t0:.1f}s")

# 保存 JSON
with open(out_json, 'w', encoding='utf-8') as f:
    json.dump(res, f, ensure_ascii=False, indent=2)
print(f"[AudioTranscriber] JSON已保存: {out_json}")

# 生成可读文本
segments = res[0].get("sentence_info", [])
spk_names = {0: "【女声】", 1: "【男声】"}

lines = [f"# {base} 通话记录\n"]
for seg in segments:
    start_ms = int(seg.get("start", 0))
    end_ms = int(seg.get("end", 0))
    t_start = f"{start_ms//60000:02d}:{(start_ms%60000)//1000:02d}"
    t_end = f"{end_ms//60000:02d}:{(end_ms%60000)//1000:02d}"
    spk = seg.get("spk", "?")
    text = seg.get("text", "")
    name = spk_names.get(spk, f"【说话人{spk}】")
    lines.append(f"[{t_start} → {t_end}] {name}：{text}")

with open(out_md, 'w', encoding='utf-8') as f:
    f.write('\n'.join(lines))
print(f"[AudioTranscriber] 文本已保存: {out_md}")
print(f"[AudioTranscriber] 共 {len(segments)} 个片段")
print(f"[AudioTranscriber] Done in {time.time()-t0:.1f}s")

# 主动释放模型内存
del model
import gc
gc.collect()
