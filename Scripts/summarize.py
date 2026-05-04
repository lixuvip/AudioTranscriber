#!/usr/bin/env python3
"""
AudioTranscriber - 总结脚本
用法: python3 summarize.py <转写文本路径> <模型名>
"""
import os, sys

if len(sys.argv) < 3:
    print("用法: python3 summarize.py <文本路径> <模型名>")
    sys.exit(1)

text_path = sys.argv[1]
model_name = sys.argv[2]

with open(text_path, 'r', encoding='utf-8') as f:
    content = f.read()

base = os.path.splitext(os.path.basename(text_path))[0]
out_path = text_path.replace("_通话记录.md", "_摘要.md")

print(f"[AudioTranscriber] 读取转写文本: {text_path}")
print(f"[AudioTranscriber] 使用模型: {model_name}")

# 读取 API Key
api_key = os.environ.get("OPENAI_API_KEY", "")
api_base = os.environ.get("OPENAI_API_BASE", "https://api.openai.com/v1")

if not api_key:
    print("[AudioTranscriber] 错误: 请设置 OPENAI_API_KEY 环境变量")
    sys.exit(1)

prompt = f"""请阅读以下通话记录，生成一份简明摘要，包含：
1. 通话主题
2. 主要内容（按话题分点）
3. 关键结论或决策

通话记录：
{content[:8000]}

请用中文输出，结构清晰。"""

print(f"[AudioTranscriber] 调用 LLM 生成摘要...")

try:
    from openai import OpenAI
    client = OpenAI(api_key=api_key, base_url=api_base)
    response = client.chat.completions.create(
        model=model_name,
        messages=[{"role": "user", "content": prompt}],
        temperature=0.5,
        max_tokens=2000,
    )
    summary = response.choices[0].message.content
except Exception as e:
    print(f"[AudioTranscriber] LLM 调用失败: {e}")
    sys.exit(1)

with open(out_path, 'w', encoding='utf-8') as f:
    f.write(f"# 摘要\n\n{summary}\n\n---\n原始转写: {os.path.basename(text_path)}\n")

print(f"[AudioTranscriber] 摘要已保存: {out_path}")
