import os
from pathlib import Path
import tempfile

from voicescribe_server.worker import TaskWorker, _subprocess_env


def test_subprocess_env_forwards_hf_token_without_mutating_parent(monkeypatch):
    monkeypatch.delenv("HF_TOKEN", raising=False)
    monkeypatch.delenv("HUGGING_FACE_HUB_TOKEN", raising=False)

    env = _subprocess_env({"hf_token": "  test-hf-token  "})

    assert env["HF_TOKEN"] == "test-hf-token"
    assert env["HUGGING_FACE_HUB_TOKEN"] == "test-hf-token"
    assert "HF_TOKEN" not in os.environ
    assert "HUGGING_FACE_HUB_TOKEN" not in os.environ


def test_subprocess_env_keeps_existing_hf_token_when_argument_missing(monkeypatch):
    monkeypatch.setenv("HF_TOKEN", "existing-token")

    env = _subprocess_env({})

    assert env["HF_TOKEN"] == "existing-token"


def test_build_manifest_orders_voice_outputs_and_categories():
    with tempfile.TemporaryDirectory() as tmp:
        output_dir = Path(tmp)
        (output_dir / "demo_整理版.md").write_text("speaker text", encoding="utf-8")
        (output_dir / "demo_speaker_map.json").write_text("{}", encoding="utf-8")
        (output_dir / "demo_通话记录.md").write_text("transcript", encoding="utf-8")
        (output_dir / "demo_funasr.json").write_text("{}", encoding="utf-8")

        worker = TaskWorker(database=object(), settings=object(), output_root=output_dir)
        manifest = worker._build_manifest(output_dir)

    results = manifest["results"]

    assert [item["filename"] for item in results] == [
        "demo_通话记录.md",
        "demo_整理版.md",
        "demo_speaker_map.json",
        "demo_funasr.json",
    ]
    assert [item["index"] for item in results] == [0, 1, 2, 3]
    assert [item["category"] for item in results] == [
        "transcript",
        "speaker_text",
        "speaker_map",
        "raw_json",
    ]
