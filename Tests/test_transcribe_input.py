import json
import os
import subprocess
import sys
import tempfile
import textwrap
import unittest
import wave
from pathlib import Path


class TranscribeInputValidationTests(unittest.TestCase):
    @staticmethod
    def _write_silent_wav(path: Path, seconds: float = 0.2):
        frames = int(16000 * seconds)
        with wave.open(str(path), "wb") as wav:
            wav.setnchannels(1)
            wav.setsampwidth(2)
            wav.setframerate(16000)
            wav.writeframes(b"\x00\x00" * frames)

    def test_missing_audio_returns_clear_error_before_ffmpeg(self):
        with tempfile.TemporaryDirectory() as tmp:
            missing_audio = Path(tmp) / "missing.m4a"
            result = subprocess.run(
                [
                    sys.executable,
                    "Scripts/transcribe.py",
                    str(missing_audio),
                    tmp,
                    "--engine",
                    "qwen3ASR",
                    "--model-id",
                    "Qwen/Qwen3-ASR-0.6B",
                ],
                capture_output=True,
                text=True,
                timeout=10,
            )

        self.assertEqual(result.returncode, 1)
        payloads = [
            json.loads(line)
            for line in result.stdout.splitlines()
            if line.startswith("{")
        ]
        self.assertIn("input_file_missing", {payload.get("code") for payload in payloads})
        self.assertNotIn("ffmpeg version", result.stdout + result.stderr)

    def test_qwen3_transcribe_supports_versions_without_progress_callback(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            audio_path = tmp_path / "sample.wav"
            self._write_silent_wav(audio_path)

            fake_root = tmp_path / "fake_modules"
            (fake_root / "mlx").mkdir(parents=True)
            (fake_root / "mlx" / "__init__.py").write_text("", encoding="utf-8")
            (fake_root / "mlx" / "core.py").write_text(
                "float16 = 'float16'\nfloat32 = 'float32'\nbfloat16 = 'bfloat16'\n",
                encoding="utf-8",
            )
            qwen_pkg = fake_root / "mlx_qwen3_asr"
            qwen_pkg.mkdir()
            (qwen_pkg / "__init__.py").write_text("", encoding="utf-8")
            (qwen_pkg / "transcribe.py").write_text(
                textwrap.dedent(
                    """
                    from types import SimpleNamespace

                    def transcribe(audio, *, model, dtype, diarize):
                        return SimpleNamespace(
                            text="兼容旧版 Qwen3",
                            language="Chinese",
                            segments=[],
                            speaker_segments=[],
                        )
                    """
                ),
                encoding="utf-8",
            )

            env = os.environ.copy()
            env["PYTHONPATH"] = f"{fake_root}{os.pathsep}{env.get('PYTHONPATH', '')}"
            result = subprocess.run(
                [
                    sys.executable,
                    "Scripts/transcribe.py",
                    str(audio_path),
                    tmp,
                    "--engine",
                    "qwen3ASR",
                    "--model-id",
                    "Qwen/Qwen3-ASR-0.6B",
                    "--speaker-diarization",
                    "0",
                ],
                capture_output=True,
                text=True,
                timeout=10,
                env=env,
            )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("unexpected keyword", result.stdout + result.stderr)

    def test_qwen3_diarization_stage_emits_start_heartbeat_and_done_logs(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            audio_path = tmp_path / "sample.wav"
            self._write_silent_wav(audio_path)

            fake_root = tmp_path / "fake_modules"
            (fake_root / "mlx").mkdir(parents=True)
            (fake_root / "mlx" / "__init__.py").write_text("", encoding="utf-8")
            (fake_root / "mlx" / "core.py").write_text(
                "float16 = 'float16'\nfloat32 = 'float32'\nbfloat16 = 'bfloat16'\n",
                encoding="utf-8",
            )
            qwen_pkg = fake_root / "mlx_qwen3_asr"
            qwen_pkg.mkdir()
            (qwen_pkg / "__init__.py").write_text("", encoding="utf-8")
            (qwen_pkg / "transcribe.py").write_text(
                textwrap.dedent(
                    """
                    import time
                    from types import SimpleNamespace

                    def infer_speaker_turns(audio, *, sr, config, _pipeline=None):
                        time.sleep(0.25)
                        return [{"speaker": "SPEAKER_00", "start": 0.0, "end": 0.2}]

                    def transcribe(audio, *, model, dtype, diarize, verbose, on_progress, **kwargs):
                        on_progress({"event": "chunks_prepared", "total_chunks": 1, "audio_duration_sec": 0.2, "progress": 0.0})
                        on_progress({"event": "chunk_started", "chunk_index": 1, "total_chunks": 1, "audio_duration_sec": 0.2, "processed_audio_sec": 0.0, "progress": 0.0})
                        on_progress({"event": "chunk_completed", "chunk_index": 1, "total_chunks": 1, "audio_duration_sec": 0.2, "processed_audio_sec": 0.2, "progress": 1.0})
                        turns = []
                        if diarize:
                            config = SimpleNamespace(num_speakers=None, min_speakers=1, max_speakers=8)
                            turns = infer_speaker_turns([0] * 3200, sr=16000, config=config)
                            on_progress({"event": "diarization_completed", "speaker_segment_count": len(turns), "audio_duration_sec": 0.2})
                        on_progress({"event": "completed", "total_chunks": 1, "audio_duration_sec": 0.2, "processed_audio_sec": 0.2, "progress": 1.0, "language": "Chinese"})
                        return SimpleNamespace(
                            text="你好",
                            language="Chinese",
                            segments=[{"text": "你好", "start": 0.0, "end": 0.2}],
                            speaker_segments=[{"speaker": "SPEAKER_00", "start": 0.0, "end": 0.2, "text": "你好"}],
                        )
                    """
                ),
                encoding="utf-8",
            )

            env = os.environ.copy()
            env["PYTHONPATH"] = f"{fake_root}{os.pathsep}{env.get('PYTHONPATH', '')}"
            env["VOICESCRIBE_DIARIZATION_HEARTBEAT_SECONDS"] = "0.1"
            result = subprocess.run(
                [
                    sys.executable,
                    "Scripts/transcribe.py",
                    str(audio_path),
                    tmp,
                    "--engine",
                    "qwen3ASR",
                    "--model-id",
                    "Qwen/Qwen3-ASR-0.6B",
                    "--speaker-diarization",
                    "1",
                ],
                capture_output=True,
                text=True,
                timeout=10,
                env=env,
            )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("pyannote 说话人分离开始", result.stdout)
        self.assertIn("pyannote 仍在运行", result.stdout)
        self.assertIn("pyannote pipeline 完成", result.stdout)


if __name__ == "__main__":
    unittest.main()
