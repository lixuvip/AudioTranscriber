from voicescribe_server import app as app_module


def test_probe_available_engines_includes_whisper_mlx_when_dependency_exists(monkeypatch):
    installed = {"funasr", "mlx_audio", "mlx_whisper", "mlx_qwen3_asr"}

    def fake_find_spec(name):
        return object() if name in installed else None

    monkeypatch.setattr(app_module.importlib.util, "find_spec", fake_find_spec)

    assert app_module._probe_available_engines() == [
        "funASR",
        "vibeVoiceMLX",
        "whisperMLX",
        "qwen3ASR",
    ]
