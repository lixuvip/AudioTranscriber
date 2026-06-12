from dataclasses import dataclass
from pathlib import Path
import os


@dataclass(frozen=True)
class Settings:
    token: str
    data_root: Path
    scripts_dir: Path

    @classmethod
    def from_env(cls) -> "Settings":
        token = os.environ.get("VOICESCRIBE_TOKEN", "").strip()
        if not token:
            raise ValueError("VOICESCRIBE_TOKEN must not be empty")
        
        # Default data root to ~/.cache/VoiceScribeServer
        default_root = Path("~/.cache/VoiceScribeServer").expanduser()
        data_root = Path(os.environ.get("VOICESCRIBE_DATA_ROOT", str(default_root))).expanduser()
        
        # Default scripts directory pointing to the Scripts directory of the workspace
        default_scripts = Path(__file__).resolve().parents[2] / "Scripts"
        scripts_dir = Path(os.environ.get("VOICESCRIBE_SCRIPTS_DIR", str(default_scripts))).expanduser()
        
        return cls(
            token=token,
            data_root=data_root,
            scripts_dir=scripts_dir,
        )

    @property
    def service_root(self) -> Path:
        return self.data_root
