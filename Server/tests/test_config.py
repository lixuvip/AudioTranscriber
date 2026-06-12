import os
import pytest
from pathlib import Path
from voicescribe_server.config import Settings


def test_settings_from_env_missing_token(monkeypatch):
    monkeypatch.delenv("VOICESCRIBE_TOKEN", raising=False)
    with pytest.raises(ValueError, match="VOICESCRIBE_TOKEN must not be empty"):
        Settings.from_env()


def test_settings_from_env_empty_token(monkeypatch):
    monkeypatch.setenv("VOICESCRIBE_TOKEN", "   ")
    with pytest.raises(ValueError, match="VOICESCRIBE_TOKEN must not be empty"):
        Settings.from_env()


def test_settings_from_env_valid(monkeypatch):
    monkeypatch.setenv("VOICESCRIBE_TOKEN", "valid-token")
    monkeypatch.setenv("VOICESCRIBE_DATA_ROOT", "/tmp/fake-data-root")
    monkeypatch.setenv("VOICESCRIBE_SCRIPTS_DIR", "/tmp/fake-scripts-dir")

    settings = Settings.from_env()
    assert settings.token == "valid-token"
    assert settings.data_root == Path("/tmp/fake-data-root")
    assert settings.scripts_dir == Path("/tmp/fake-scripts-dir")
