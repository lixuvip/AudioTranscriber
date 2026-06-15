#!/usr/bin/env python3
"""
VoiceScribe - 摘要脚本
用法: python3 summarize.py <转写文本路径> <模型名> [--api-base URL] [--api-key KEY] [--provider-type TYPE]
"""
import os
import sys
import argparse
import json
import urllib.request
import urllib.error

parser = argparse.ArgumentParser()
parser.add_argument("text_path")
parser.add_argument("model_name")
parser.add_argument("--api-base", default="")
parser.add_argument("--api-key", default="")
parser.add_argument("--provider-type", default="openAICompatible")
parser.add_argument("--summary-prompt", default="")
parser.add_argument("--output-path", default="")
parser.add_argument("--document-title", default="摘要")
args = parser.parse_args()

text_path = args.text_path
model_name = args.model_name

with open(text_path, 'r', encoding='utf-8') as f:
    content = f.read()

base = os.path.splitext(os.path.basename(text_path))[0]
if base.endswith("_整理版"):
    summary_base = base[:-4]
elif base.endswith("_通话记录"):
    summary_base = base[:-5]
else:
    summary_base = base
if args.output_path:
    out_path = os.path.abspath(args.output_path)
else:
    out_path = os.path.join(os.path.dirname(text_path), f"{summary_base}_摘要.md")

print(f"[VoiceScribe] 读取转写文本: {text_path}")
print(f"[VoiceScribe] 使用模型: {model_name}")

# 读取 API Key
api_key = args.api_key or os.environ.get("OPENAI_API_KEY", "")
default_api_base = "https://api.anthropic.com/v1/messages" if args.provider_type == "anthropicMessages" else "https://api.openai.com/v1"
api_base = args.api_base or os.environ.get("OPENAI_API_BASE", default_api_base)

if not api_key:
    print("[VoiceScribe] 错误: 请设置 OPENAI_API_KEY 环境变量")
    sys.exit(1)

prompt = f"""请阅读以下通话记录，生成一份简明摘要，包含：
1. 通话主题
2. 主要内容（按话题分点）
3. 关键结论或决策

通话记录：
{content}

请用中文输出，结构清晰。"""

extra_prompt = args.summary_prompt.strip()
if extra_prompt:
    prompt += f"\n\n额外要求：{extra_prompt}"

print(f"[VoiceScribe] 调用 LLM 生成摘要...")

try:
    if args.provider_type == "anthropicMessages":
        payload = json.dumps({
            "model": model_name,
            "max_tokens": 2000,
            "temperature": 0.5,
            "messages": [
                {
                    "role": "user",
                    "content": prompt
                }
            ]
        }).encode("utf-8")
        request = urllib.request.Request(
            api_base,
            data=payload,
            headers={
                "Content-Type": "application/json",
                "x-api-key": api_key,
                "anthropic-version": "2023-06-01",
            },
            method="POST",
        )
        with urllib.request.urlopen(request, timeout=120) as response:
            body = response.read().decode("utf-8")
        data = json.loads(body)
        parts = []
        for item in data.get("content", []):
            if item.get("type") == "text" and item.get("text"):
                parts.append(item["text"])
        summary = "\n".join(parts).strip()
    else:
        from openai import OpenAI
        client = OpenAI(api_key=api_key, base_url=api_base)

        if args.provider_type == "openAIResponses":
            response = client.responses.create(
                model=model_name,
                input=prompt,
                temperature=0.5,
                max_output_tokens=2000,
            )
            summary = getattr(response, "output_text", "") or ""
            if not summary:
                parts = []
                for item in getattr(response, "output", []) or []:
                    for content_item in getattr(item, "content", []) or []:
                        text_value = getattr(content_item, "text", "")
                        if text_value:
                            parts.append(text_value)
                summary = "\n".join(parts).strip()
        else:
            response = client.chat.completions.create(
                model=model_name,
                messages=[{"role": "user", "content": prompt}],
                temperature=0.5,
                max_tokens=2000,
            )
            summary = response.choices[0].message.content or ""

    if not summary.strip():
        raise RuntimeError("模型返回为空，未生成摘要内容")
except urllib.error.HTTPError as e:
    hint = ""
    if e.code == 404:
        hint = "（提示：请检查 API Base URL 是否正确，DeepSeek 使用 https://api.deepseek.com/v1，接口形态选 OpenAI Compatible）"
    elif e.code == 401 or e.code == 403:
        hint = "（提示：API Key 无效或无权访问该模型）"
    print(f"[VoiceScribe] LLM 调用失败: HTTP {e.code}{hint}")
    sys.exit(1)
except Exception as e:
    print(f"[VoiceScribe] LLM 调用失败: {type(e).__name__}")
    sys.exit(1)

out_dir = os.path.dirname(out_path) or "."
temp_path = f"{out_path}.{os.getpid()}.tmp"
try:
    os.makedirs(out_dir, exist_ok=True)
    with open(temp_path, 'w', encoding='utf-8') as f:
        f.write(
            f"# {args.document_title}\n\n"
            f"{summary.strip()}\n\n"
            "---\n"
            f"原始转写: {os.path.basename(text_path)}\n"
        )
    os.replace(temp_path, out_path)
except Exception as e:
    print(f"[VoiceScribe] 摘要保存失败: {type(e).__name__}")
    sys.exit(1)
finally:
    if os.path.exists(temp_path):
        os.remove(temp_path)

print(f"[VoiceScribe] 摘要已保存: {out_path}")
