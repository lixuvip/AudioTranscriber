#!/usr/bin/env python3
"""
VoiceScribe - 声纹库辅助脚本

默认只做本地样本提取和依赖检查，不下载任何模型。
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import math
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unicodedata
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


ECAPA_MODEL_ID = "speechbrain/spkrec-ecapa-voxceleb"
SAMPLE_SOURCE_TYPES = {
    "direct": {
        "title": "近场录制",
        "matchWeight": 1.0,
    },
    "call": {
        "title": "电话录音",
        "matchWeight": 0.72,
    },
    "meeting": {
        "title": "会议录音",
        "matchWeight": 0.78,
    },
    "transcript": {
        "title": "转写片段",
        "matchWeight": 0.86,
    },
}
PYTHON_PACKAGE_DEPENDENCIES = [
    {
        "id": "speechbrain",
        "title": "SpeechBrain",
        "kind": "python_package",
        "description": "生成和读取 ECAPA 声纹 embedding 的核心库。",
        "installCommand": "${python} -m pip install -U speechbrain",
    },
    {
        "id": "torch",
        "title": "PyTorch",
        "kind": "python_package",
        "description": "SpeechBrain 运行所需的张量和推理运行时。",
        "installCommand": "${python} -m pip install -U torch",
    },
    {
        "id": "torchaudio",
        "title": "TorchAudio",
        "kind": "python_package",
        "description": "SpeechBrain 处理音频输入所需的 PyTorch 音频组件。",
        "installCommand": "${python} -m pip install -U torchaudio",
    },
    {
        "id": "huggingface_hub",
        "title": "Hugging Face Hub",
        "kind": "python_package",
        "description": "用于手动下载 SpeechBrain 声纹模型到本机缓存。",
        "installCommand": "${python} -m pip install -U huggingface_hub",
    },
]
COMMON_FFMPEG_PATHS = [
    "/opt/homebrew/bin/ffmpeg",
    "/usr/local/bin/ffmpeg",
    "/usr/bin/ffmpeg",
    "/bin/ffmpeg",
]

# Finder-launched macOS apps usually do not inherit the user's shell PATH.
os.environ["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + os.environ.get("PATH", "")


def slugify(value: str) -> str:
    normalized = unicodedata.normalize("NFKD", value).encode("ascii", "ignore").decode("ascii")
    normalized = re.sub(r"[^a-zA-Z0-9]+", "-", normalized).strip("-").lower()
    if normalized:
        return normalized
    digest = hashlib.sha1(value.encode("utf-8")).hexdigest()[:10]
    return f"speaker-{digest}"


def select_training_segments(
    segments: list[dict[str, Any]],
    speaker_key: str,
    min_seconds: float,
    max_samples: int,
) -> list[dict[str, Any]]:
    selected: list[dict[str, Any]] = []
    for segment in segments:
        if str(segment.get("speakerKey", "")) != str(speaker_key):
            continue
        try:
            start = float(segment.get("start", 0))
            end = float(segment.get("end", 0))
        except (TypeError, ValueError):
            continue
        text = str(segment.get("text", "")).strip()
        if not text:
            continue
        if end - start < min_seconds:
            continue
        selected.append(segment)
        if len(selected) >= max_samples:
            break
    return selected


def _model_cache_exists() -> bool:
    return ecapa_model_source_path() is not None


def ecapa_model_source_path() -> Path | None:
    explicit = os.environ.get("VOICESCRIBE_ECAPA_MODEL_DIR", "").strip()
    if explicit and Path(explicit).exists():
        return Path(explicit)
    cache_root = Path(os.environ.get("HF_HOME", "~/.cache/huggingface")).expanduser()
    model_root = cache_root / "hub" / "models--speechbrain--spkrec-ecapa-voxceleb"
    snapshots_dir = model_root / "snapshots"
    if snapshots_dir.exists():
        snapshots = sorted(
            [path for path in snapshots_dir.iterdir() if path.is_dir()],
            key=lambda path: path.stat().st_mtime,
            reverse=True,
        )
        for snapshot in snapshots:
            if (snapshot / "hyperparams.yaml").exists():
                return snapshot
    if (model_root / "hyperparams.yaml").exists():
        return model_root
    return None


def find_ffmpeg() -> str | None:
    found = shutil.which("ffmpeg")
    if found:
        return found
    for candidate in COMMON_FFMPEG_PATHS:
        if Path(candidate).exists():
            return candidate
    return None


def dependency_report() -> dict[str, Any]:
    packages = {item["id"]: importlib.util.find_spec(item["id"]) is not None for item in PYTHON_PACKAGE_DEPENDENCIES}
    ffmpeg_path = find_ffmpeg()
    ffmpeg_ready = ffmpeg_path is not None
    model_cached = _model_cache_exists()
    dependencies = [
        {
            "id": "ffmpeg",
            "title": "FFmpeg",
            "kind": "system_binary",
            "ready": ffmpeg_ready,
            "description": "用于从原始音频中裁切和转码声纹训练样本。",
            "installCommand": "if command -v brew >/dev/null 2>&1; then brew install ffmpeg; else open https://ffmpeg.org/download.html; fi",
            "detectedPath": ffmpeg_path,
        }
    ]
    dependencies.extend(
        {
            **item,
            "ready": packages[item["id"]],
        }
        for item in PYTHON_PACKAGE_DEPENDENCIES
    )
    dependencies.append(
        {
            "id": ECAPA_MODEL_ID,
            "title": "SpeechBrain ECAPA 声纹模型",
            "kind": "model",
            "ready": model_cached,
            "description": "用于把已确认角色样本转换为后续可比对的声纹 embedding。",
            "installCommand": (
                "${python} -m pip install -U huggingface_hub && "
                "${python} -c \"from huggingface_hub import snapshot_download; "
                f"snapshot_download(repo_id='{ECAPA_MODEL_ID}')\""
            ),
            "envOverride": "VOICESCRIBE_ECAPA_MODEL_DIR",
        }
    )
    missing = []
    if not ffmpeg_ready:
        missing.append("ffmpeg")
    for name, ready in packages.items():
        if not ready:
            missing.append(name)
    if not model_cached:
        missing.append(ECAPA_MODEL_ID)
    return {
        "type": "voiceprint_check",
        "ready": ffmpeg_ready and all(packages.values()) and model_cached,
        "ffmpeg": ffmpeg_ready,
        "ffmpegPath": ffmpeg_path,
        "packages": packages,
        "model": {
            "id": ECAPA_MODEL_ID,
            "cached": model_cached,
            "envOverride": "VOICESCRIBE_ECAPA_MODEL_DIR",
            "sourcePath": str(ecapa_model_source_path()) if model_cached else None,
        },
        "dependencies": dependencies,
        "missing": missing,
    }


def build_profile_payload(
    speaker_name: str,
    speaker_key: str,
    source_audio: str,
    sample_paths: list[Path],
    embedding: list[float] | None,
    embedding_model_available: bool,
) -> dict[str, Any]:
    profile_id = slugify(speaker_name)
    samples = [
        {
            "path": str(path),
            "sha256": file_sha256(path) if path.exists() else "",
            "sourceType": "transcript",
            "sourceTitle": SAMPLE_SOURCE_TYPES["transcript"]["title"],
            "capturedAt": datetime.now(timezone.utc).isoformat(),
        }
        for path in sample_paths
    ]
    return {
        "id": profile_id,
        "displayName": speaker_name,
        "speakerKey": str(speaker_key),
        "createdAt": datetime.now(timezone.utc).isoformat(),
        "updatedAt": datetime.now(timezone.utc).isoformat(),
        "sourceAudio": source_audio,
        "samples": samples,
        "sampleGroups": summarize_sample_groups(samples),
        "embeddingModel": ECAPA_MODEL_ID if embedding else None,
        "embedding": embedding,
        "embeddingStatus": "ready" if embedding else ("model_available_no_embedding" if embedding_model_available else "missing_model"),
        "requiredModel": {
            "id": ECAPA_MODEL_ID,
            "purpose": "known-speaker voiceprint embedding and future automatic role naming",
        },
    }


def sample_source_metadata(source_type: str) -> dict[str, Any]:
    return SAMPLE_SOURCE_TYPES.get(source_type, SAMPLE_SOURCE_TYPES["direct"])


def summarize_sample_groups(samples: list[dict[str, Any]]) -> list[dict[str, Any]]:
    summary: dict[str, dict[str, Any]] = {}
    for sample in samples:
        source_type = str(sample.get("sourceType") or "transcript")
        meta = sample_source_metadata(source_type)
        group = summary.setdefault(
            source_type,
            {
                "sourceType": source_type,
                "title": meta["title"],
                "sampleCount": 0,
                "matchWeight": meta["matchWeight"],
                "lastUpdatedAt": "",
            },
        )
        group["sampleCount"] += 1
        captured_at = str(sample.get("capturedAt") or "")
        if captured_at > group["lastUpdatedAt"]:
            group["lastUpdatedAt"] = captured_at
    return sorted(summary.values(), key=lambda item: item["sourceType"])


def build_manual_capture_payload(
    existing_profile: dict[str, Any] | None,
    speaker_name: str,
    source_audio: str,
    sample_path: Path,
    source_type: str,
    embedding_model_available: bool,
) -> dict[str, Any]:
    profile_id = slugify(speaker_name)
    now = datetime.now(timezone.utc).isoformat()
    meta = sample_source_metadata(source_type)
    sample = {
        "path": str(sample_path),
        "sha256": file_sha256(sample_path) if sample_path.exists() else "",
        "sourceType": source_type,
        "sourceTitle": meta["title"],
        "capturedAt": now,
        "sourceAudio": source_audio,
    }
    if existing_profile:
        payload = dict(existing_profile)
        payload["displayName"] = speaker_name
        payload["updatedAt"] = now
        payload["sourceAudio"] = source_audio
        payload["samples"] = list(payload.get("samples", [])) + [sample]
    else:
        payload = {
            "id": profile_id,
            "displayName": speaker_name,
            "speakerKey": "manual",
            "createdAt": now,
            "updatedAt": now,
            "sourceAudio": source_audio,
            "samples": [sample],
            "embeddingModel": None,
            "embedding": None,
            "embeddingStatus": "model_available_no_embedding" if embedding_model_available else "missing_model",
            "requiredModel": {
                "id": ECAPA_MODEL_ID,
                "purpose": "known-speaker voiceprint embedding and future automatic role naming",
            },
        }
    payload["id"] = profile_id
    payload["sampleGroups"] = summarize_sample_groups(list(payload.get("samples", [])))
    payload["captureMode"] = "manual"
    return payload


def write_profile(library_dir: Path, payload: dict[str, Any]) -> Path:
    person_dir = library_dir / payload["id"]
    person_dir.mkdir(parents=True, exist_ok=True)
    profile_path = person_dir / "profile.json"
    profile_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    return profile_path


def file_sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def load_speaker_segments(speaker_map_path: Path) -> tuple[str, list[dict[str, Any]]]:
    payload = json.loads(speaker_map_path.read_text(encoding="utf-8"))
    return str(payload.get("title", speaker_map_path.stem)), list(payload.get("segments", []))


def extract_samples(
    audio_path: Path,
    output_dir: Path,
    segments: list[dict[str, Any]],
    padding_seconds: float,
) -> list[Path]:
    ffmpeg_path = find_ffmpeg()
    if ffmpeg_path is None:
        raise RuntimeError("ffmpeg is required to extract voiceprint samples")

    output_dir.mkdir(parents=True, exist_ok=True)
    sample_paths: list[Path] = []
    for idx, segment in enumerate(segments, start=1):
        start = max(0.0, float(segment["start"]) - padding_seconds)
        end = max(start + 0.2, float(segment["end"]) + padding_seconds)
        duration = end - start
        out = output_dir / f"sample-{idx:03d}.wav"
        cmd = [
            ffmpeg_path,
            "-y",
            "-ss",
            f"{start:.3f}",
            "-i",
            str(audio_path),
            "-t",
            f"{duration:.3f}",
            "-ac",
            "1",
            "-ar",
            "16000",
            "-sample_fmt",
            "s16",
            str(out),
        ]
        subprocess.run(cmd, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        sample_paths.append(out)
    return sample_paths


def next_manual_sample_path(samples_dir: Path, source_type: str) -> Path:
    samples_dir.mkdir(parents=True, exist_ok=True)
    safe_source = re.sub(r"[^a-zA-Z0-9]+", "-", source_type).strip("-").lower() or "sample"
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S")
    candidate = samples_dir / f"{safe_source}-{timestamp}.wav"
    counter = 2
    while candidate.exists():
        candidate = samples_dir / f"{safe_source}-{timestamp}-{counter}.wav"
        counter += 1
    return candidate


def transcode_full_sample(audio_path: Path, output_path: Path) -> Path:
    ffmpeg_path = find_ffmpeg()
    if ffmpeg_path is None:
        raise RuntimeError("ffmpeg is required to collect voiceprint samples")

    output_path.parent.mkdir(parents=True, exist_ok=True)
    cmd = [
        ffmpeg_path,
        "-y",
        "-i",
        str(audio_path),
        "-ac",
        "1",
        "-ar",
        "16000",
        "-sample_fmt",
        "s16",
        str(output_path),
    ]
    subprocess.run(cmd, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    return output_path


def load_existing_profile(profile_path: Path) -> dict[str, Any] | None:
    if not profile_path.exists():
        return None
    return json.loads(profile_path.read_text(encoding="utf-8"))


def normalize_vector(vector: list[float]) -> list[float]:
    norm = math.sqrt(sum(value * value for value in vector))
    if norm <= 0:
        return vector
    return [value / norm for value in vector]


def cosine_similarity(left: list[float], right: list[float]) -> float:
    if not left or not right or len(left) != len(right):
        return 0.0
    left_norm = normalize_vector(left)
    right_norm = normalize_vector(right)
    return sum(a * b for a, b in zip(left_norm, right_norm))


def average_embeddings(embeddings: list[list[float]]) -> list[float] | None:
    if not embeddings:
        return None
    dim = len(embeddings[0])
    usable = [embedding for embedding in embeddings if len(embedding) == dim]
    if not usable:
        return None
    averaged = [sum(embedding[index] for embedding in usable) / len(usable) for index in range(dim)]
    return normalize_vector(averaged)


def _flatten_embedding(value: Any) -> list[float]:
    if isinstance(value, (int, float)):
        return [float(value)]
    if isinstance(value, list):
        flattened: list[float] = []
        for item in value:
            flattened.extend(_flatten_embedding(item))
        return flattened
    return []


def load_embedding_model():
    report = dependency_report()
    if not report["ready"]:
        raise RuntimeError("voiceprint dependencies are not ready: " + ", ".join(report["missing"]))
    source_path = ecapa_model_source_path()
    if source_path is None:
        raise RuntimeError(f"{ECAPA_MODEL_ID} is not cached")

    try:
        from speechbrain.inference.speaker import EncoderClassifier
    except ImportError:
        from speechbrain.pretrained import EncoderClassifier

    savedir = Path(os.environ.get("VOICESCRIBE_SPEECHBRAIN_SAVEDIR", "~/.voicescribe/speechbrain")).expanduser()
    savedir.mkdir(parents=True, exist_ok=True)
    return EncoderClassifier.from_hparams(source=str(source_path), savedir=str(savedir))


def encode_audio_file(classifier: Any, audio_path: Path) -> list[float]:
    embedding = classifier.encode_file(str(audio_path))
    if hasattr(embedding, "squeeze"):
        embedding = embedding.squeeze()
    if hasattr(embedding, "detach"):
        embedding = embedding.detach()
    if hasattr(embedding, "cpu"):
        embedding = embedding.cpu()
    if hasattr(embedding, "tolist"):
        embedding = embedding.tolist()
    return normalize_vector(_flatten_embedding(embedding))


def load_profile_records(library_dir: Path) -> list[tuple[Path, dict[str, Any]]]:
    if not library_dir.exists():
        return []
    records: list[tuple[Path, dict[str, Any]]] = []
    for profile_path in sorted(library_dir.glob("*/profile.json")):
        try:
            payload = json.loads(profile_path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            continue
        records.append((profile_path, payload))
    return records


def profile_embedding(classifier: Any, profile_path: Path, profile: dict[str, Any], update_profile: bool) -> list[float] | None:
    stored_embedding = profile.get("embedding")
    if isinstance(stored_embedding, list) and stored_embedding:
        return normalize_vector(_flatten_embedding(stored_embedding))

    sample_embeddings: list[list[float]] = []
    for sample in profile.get("samples", []):
        sample_path = Path(str(sample.get("path", ""))).expanduser()
        if not sample_path.exists():
            continue
        try:
            sample_embeddings.append(encode_audio_file(classifier, sample_path))
        except Exception:
            continue

    embedding = average_embeddings(sample_embeddings)
    if embedding and update_profile:
        profile["embedding"] = embedding
        profile["embeddingModel"] = ECAPA_MODEL_ID
        profile["embeddingStatus"] = "ready"
        profile["updatedAt"] = datetime.now(timezone.utc).isoformat()
        profile_path.write_text(json.dumps(profile, ensure_ascii=False, indent=2), encoding="utf-8")
    return embedding


def group_segments_by_speaker(segments: list[dict[str, Any]]) -> dict[str, list[dict[str, Any]]]:
    grouped: dict[str, list[dict[str, Any]]] = {}
    for segment in segments:
        key = str(segment.get("speakerKey") or segment.get("speaker") or segment.get("speaker_id") or "")
        if not key:
            continue
        grouped.setdefault(key, []).append(segment)
    return grouped


def speaker_embedding_from_segments(
    classifier: Any,
    audio_path: Path,
    speaker_key: str,
    segments: list[dict[str, Any]],
    temp_dir: Path,
    min_seconds: float,
    max_samples: int,
    padding_seconds: float,
) -> list[float] | None:
    selected = select_training_segments(
        segments,
        speaker_key=speaker_key,
        min_seconds=min_seconds,
        max_samples=max_samples,
    )
    if not selected:
        return None
    sample_paths = extract_samples(audio_path, temp_dir / slugify(speaker_key), selected, padding_seconds)
    embeddings = [encode_audio_file(classifier, sample_path) for sample_path in sample_paths]
    return average_embeddings(embeddings)


def match_speakers_to_profiles(
    speaker_embeddings: dict[str, list[float]],
    profile_embeddings: list[dict[str, Any]],
    threshold: float,
) -> dict[str, dict[str, Any]]:
    candidates: list[dict[str, Any]] = []
    for speaker_key, speaker_embedding in speaker_embeddings.items():
        for profile in profile_embeddings:
            score = cosine_similarity(speaker_embedding, profile["embedding"])
            if score >= threshold:
                candidates.append(
                    {
                        "speakerKey": speaker_key,
                        "profileId": profile["id"],
                        "displayName": profile["displayName"],
                        "score": score,
                    }
                )

    matches: dict[str, dict[str, Any]] = {}
    used_profiles: set[str] = set()
    for candidate in sorted(candidates, key=lambda item: item["score"], reverse=True):
        if candidate["speakerKey"] in matches or candidate["profileId"] in used_profiles:
            continue
        matches[candidate["speakerKey"]] = candidate
        used_profiles.add(candidate["profileId"])
    return matches


def apply_matches_to_speaker_map(payload: dict[str, Any], matches: dict[str, dict[str, Any]]) -> dict[str, Any]:
    roles = []
    for role in payload.get("roles", []):
        updated = dict(role)
        key = str(updated.get("key", ""))
        match = matches.get(key)
        if match:
            updated["displayName"] = match["displayName"]
            updated["voiceprintMatch"] = {
                "profileId": match["profileId"],
                "score": round(float(match["score"]), 4),
            }
        roles.append(updated)
    payload["roles"] = roles
    payload["voiceprintMatches"] = [
        {
            "speakerKey": key,
            "profileId": match["profileId"],
            "displayName": match["displayName"],
            "score": round(float(match["score"]), 4),
        }
        for key, match in sorted(matches.items())
    ]
    return payload


def enroll(args: argparse.Namespace) -> int:
    library_dir = Path(args.library_dir).expanduser()
    speaker_name = args.speaker_name.strip()
    if not speaker_name:
        raise RuntimeError("speaker name is required")

    _, all_segments = load_speaker_segments(Path(args.speaker_map))
    segments = select_training_segments(
        all_segments,
        speaker_key=args.speaker_key,
        min_seconds=args.min_seconds,
        max_samples=args.max_samples,
    )
    person_dir = library_dir / slugify(speaker_name)
    samples_dir = person_dir / "samples"
    sample_paths = extract_samples(Path(args.audio), samples_dir, segments, args.padding_seconds)

    report = dependency_report()
    payload = build_profile_payload(
        speaker_name=speaker_name,
        speaker_key=args.speaker_key,
        source_audio=str(Path(args.audio)),
        sample_paths=sample_paths,
        embedding=None,
        embedding_model_available=report["ready"],
    )
    payload["selectedSegmentCount"] = len(segments)
    payload["dependencyReport"] = report
    profile_path = write_profile(library_dir, payload)
    print(json.dumps({"type": "voiceprint_enrolled", "profilePath": str(profile_path), "profile": payload}, ensure_ascii=False))
    return 0


def collect(args: argparse.Namespace) -> int:
    library_dir = Path(args.library_dir).expanduser()
    speaker_name = args.speaker_name.strip()
    if not speaker_name:
        raise RuntimeError("speaker name is required")

    profile_id = slugify(speaker_name)
    person_dir = library_dir / profile_id
    samples_dir = person_dir / "samples"
    sample_path = next_manual_sample_path(samples_dir, args.source_type)
    transcode_full_sample(Path(args.audio), sample_path)

    report = dependency_report()
    profile_path = person_dir / "profile.json"
    payload = build_manual_capture_payload(
        existing_profile=load_existing_profile(profile_path),
        speaker_name=speaker_name,
        source_audio=str(Path(args.audio)),
        sample_path=sample_path,
        source_type=args.source_type,
        embedding_model_available=report["ready"],
    )
    payload["dependencyReport"] = report
    profile_path = write_profile(library_dir, payload)
    print(json.dumps({"type": "voiceprint_collected", "profilePath": str(profile_path), "profile": payload}, ensure_ascii=False))
    return 0


def match(args: argparse.Namespace) -> int:
    report = dependency_report()
    if not report["ready"]:
        print(json.dumps({"type": "voiceprint_match_skipped", "reason": "missing_dependencies", "dependencyReport": report}, ensure_ascii=False))
        return 2

    library_dir = Path(args.library_dir).expanduser()
    profile_records = load_profile_records(library_dir)
    if not profile_records:
        print(json.dumps({"type": "voiceprint_match_skipped", "reason": "empty_library", "matches": []}, ensure_ascii=False))
        return 0

    speaker_map_path = Path(args.speaker_map)
    payload = json.loads(speaker_map_path.read_text(encoding="utf-8"))
    segments = list(payload.get("segments", []))
    if not segments:
        print(json.dumps({"type": "voiceprint_match_skipped", "reason": "empty_segments", "matches": []}, ensure_ascii=False))
        return 0

    classifier = load_embedding_model()
    profile_embeddings: list[dict[str, Any]] = []
    for profile_path, profile in profile_records:
        embedding = profile_embedding(classifier, profile_path, profile, update_profile=not args.no_update_profiles)
        if embedding:
            profile_embeddings.append(
                {
                    "id": str(profile.get("id") or profile_path.parent.name),
                    "displayName": str(profile.get("displayName") or profile_path.parent.name),
                    "embedding": embedding,
                }
            )

    if not profile_embeddings:
        print(json.dumps({"type": "voiceprint_match_skipped", "reason": "no_profile_embeddings", "matches": []}, ensure_ascii=False))
        return 0

    grouped = group_segments_by_speaker(segments)
    speaker_embeddings: dict[str, list[float]] = {}
    with tempfile.TemporaryDirectory(prefix="voicescribe-voiceprint-match-") as tmp:
        temp_dir = Path(tmp)
        for speaker_key in grouped:
            embedding = speaker_embedding_from_segments(
                classifier=classifier,
                audio_path=Path(args.audio),
                speaker_key=speaker_key,
                segments=segments,
                temp_dir=temp_dir,
                min_seconds=args.min_seconds,
                max_samples=args.max_samples,
                padding_seconds=args.padding_seconds,
            )
            if embedding:
                speaker_embeddings[speaker_key] = embedding

    matches = match_speakers_to_profiles(speaker_embeddings, profile_embeddings, threshold=args.threshold)
    updated_payload = apply_matches_to_speaker_map(payload, matches)
    if not args.dry_run:
        speaker_map_path.write_text(json.dumps(updated_payload, ensure_ascii=False, indent=2), encoding="utf-8")

    print(
        json.dumps(
            {
                "type": "voiceprint_matched",
                "speakerMap": str(speaker_map_path),
                "matches": updated_payload.get("voiceprintMatches", []),
                "threshold": args.threshold,
            },
            ensure_ascii=False,
        )
    )
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="VoiceScribe voiceprint library helper")
    sub = parser.add_subparsers(dest="command", required=True)

    check = sub.add_parser("check", help="check local voiceprint dependencies without downloading models")
    check.add_argument("--json", action="store_true")

    enroll_cmd = sub.add_parser("enroll", help="extract speaker samples and create/update a voiceprint profile")
    enroll_cmd.add_argument("--audio", required=True)
    enroll_cmd.add_argument("--speaker-map", required=True)
    enroll_cmd.add_argument("--speaker-key", required=True)
    enroll_cmd.add_argument("--speaker-name", required=True)
    enroll_cmd.add_argument("--library-dir", required=True)
    enroll_cmd.add_argument("--min-seconds", type=float, default=2.0)
    enroll_cmd.add_argument("--max-samples", type=int, default=8)
    enroll_cmd.add_argument("--padding-seconds", type=float, default=0.15)

    collect_cmd = sub.add_parser("collect", help="collect a manual voice sample for a known speaker")
    collect_cmd.add_argument("--audio", required=True)
    collect_cmd.add_argument("--speaker-name", required=True)
    collect_cmd.add_argument("--source-type", required=True, choices=sorted(SAMPLE_SOURCE_TYPES.keys()))
    collect_cmd.add_argument("--library-dir", required=True)

    match_cmd = sub.add_parser("match", help="match diarized speakers against the local voiceprint library")
    match_cmd.add_argument("--audio", required=True)
    match_cmd.add_argument("--speaker-map", required=True)
    match_cmd.add_argument("--library-dir", required=True)
    match_cmd.add_argument("--threshold", type=float, default=0.72)
    match_cmd.add_argument("--min-seconds", type=float, default=1.2)
    match_cmd.add_argument("--max-samples", type=int, default=6)
    match_cmd.add_argument("--padding-seconds", type=float, default=0.15)
    match_cmd.add_argument("--no-update-profiles", action="store_true")
    match_cmd.add_argument("--dry-run", action="store_true")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.command == "check":
        report = dependency_report()
        if args.json:
            print(json.dumps(report, ensure_ascii=False, indent=2))
        else:
            print("Voiceprint dependencies: " + ("ready" if report["ready"] else "missing"))
            for item in report["missing"]:
                print(f"- {item}")
        return 0 if report["ready"] else 2
    if args.command == "enroll":
        return enroll(args)
    if args.command == "collect":
        return collect(args)
    if args.command == "match":
        return match(args)
    return 2


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(json.dumps({"type": "voiceprint_error", "message": str(exc)}, ensure_ascii=False), file=sys.stderr)
        raise SystemExit(1)
