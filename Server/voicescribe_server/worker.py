from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import threading
from typing import Any, Optional

from .database import Database
from .config import Settings


def _subprocess_env(arguments: dict[str, Any]) -> dict[str, str]:
    env = os.environ.copy()
    hf_token = str(arguments.get("hf_token") or "").strip()
    if hf_token:
        env["HF_TOKEN"] = hf_token
        env["HUGGING_FACE_HUB_TOKEN"] = hf_token
    return env


class TaskWorker:
    def __init__(self, database: Database, settings: Settings, output_root: Path) -> None:
        self.database = database
        self.settings = settings
        self.output_root = output_root
        self._event = threading.Event()
        self._stop = threading.Event()
        self._thread: Optional[threading.Thread] = None
        self._current_process: Optional[subprocess.Popen] = None

    def start(self) -> None:
        self._recover_interrupted_tasks()
        self._thread = threading.Thread(target=self._loop, daemon=True)
        self._thread.start()

    def notify(self) -> None:
        self._event.set()

    def stop(self) -> None:
        self._stop.set()
        self._event.set()
        if self._current_process is not None:
            try:
                self._current_process.terminate()
            except Exception:
                pass
        if self._thread is not None:
            self._thread.join(timeout=5)

    def run_next(self) -> bool:
        row = self.database.fetchone(
            """
            SELECT * FROM tasks
            WHERE status = 'queued'
            ORDER BY created_at ASC
            LIMIT 1
            """
        )
        if row is None:
            return False

        task_id = row["id"]
        self._update(task_id, status="preparing", progress=0.0, current_stage="准备中...")

        try:
            arguments = json.loads(row["arguments_json"])
            
            # Find claimed upload
            upload = self.database.fetchone(
                "SELECT path FROM uploads WHERE claimed_task_id = ?", (task_id,)
            )
            if not upload:
                raise ValueError("No audio upload associated with this task")

            audio_path = upload["path"]
            output_dir = self.output_root / task_id
            output_dir.mkdir(parents=True, exist_ok=True)

            script_path = self.settings.scripts_dir / "transcribe.py"
            if not script_path.exists():
                raise FileNotFoundError(f"transcribe.py script not found at {script_path}")

            # Build subprocess CLI arguments
            cmd = [
                sys.executable,
                str(script_path),
                str(audio_path),
                str(output_dir),
                "--engine", arguments.get("engine", "funASR"),
                "--model-id", arguments.get("model_id", ""),
                "--device", arguments.get("device", "cpu"),
                "--threads", str(arguments.get("threads", 4)),
                "--batch-size-s", str(arguments.get("batch_size_s") or arguments.get("batch_size_seconds") or 60),
                "--merge-length-s", str(arguments.get("merge_length_s") or arguments.get("merge_length_seconds") or 15),
                "--speaker-diarization", "0" if str(arguments.get("speaker_diarization", "1")) in ("0", "False", "false") else "1"
            ]

            self._update(task_id, status="running", progress=0.05, current_stage="准备中...")

            # Spawn subprocess
            self._current_process = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                env=_subprocess_env(arguments),
                text=True,
                bufsize=1,
                universal_newlines=True
            )

            # Read stdout line-by-line to extract progress
            output_buffer = []
            while True:
                line = self._current_process.stdout.readline()
                if not line:
                    break
                
                # Print to server console for real-time monitoring
                print(f"[Subprocess] {line.rstrip()}", file=sys.stderr, flush=True)
                output_buffer.append(line)
                if len(output_buffer) > 500:
                    output_buffer.pop(0)
                
                # Check for progress JSON output
                stripped = line.strip()
                if stripped.startswith("{") and stripped.endswith("}"):
                    try:
                        data = json.loads(stripped)
                        if data.get("type") == "progress":
                            pct = float(data.get("percent", 0.0))
                            stage = data.get("stage", "running")
                            # We can also compute simple estimated time
                            self.database.execute(
                                """
                                UPDATE tasks
                                SET progress = ?, current_stage = ?, updated_at = ?
                                WHERE id = ?
                                """,
                                (pct / 100.0, stage, _now(), task_id)
                            )
                    except Exception:
                        pass

            rc = self._current_process.wait()
            self._current_process = None

            if rc == 0:
                # Build manifest of results
                manifest = self._build_manifest(output_dir)
                self.database.execute(
                    """
                    UPDATE tasks
                    SET status = 'completed', progress = 1.0, current_stage = '完成 ✓',
                        result_manifest_json = ?, updated_at = ?
                    WHERE id = ?
                    """,
                    (json.dumps(manifest), _now(), task_id),
                )
            else:
                last_output = "".join(output_buffer[-30:])
                self.database.execute(
                    """
                    UPDATE tasks
                    SET status = 'failed', error_code = 'subprocess_failed',
                        current_stage = '失败 ✗',
                        error_message = ?, updated_at = ?
                    WHERE id = ?
                    """,
                    (f"transcribe.py process exited with code {rc}.\n--- Subprocess Traceback ---\n{last_output}", _now(), task_id),
                )

        except Exception as exc:
            self._current_process = None
            self.database.execute(
                """
                UPDATE tasks
                SET status = 'failed', error_code = 'worker_failed',
                    current_stage = '失败 ✗',
                    error_message = ?, updated_at = ?
                WHERE id = ?
                """,
                (str(exc), _now(), task_id),
            )

        return True

    def _loop(self) -> None:
        while not self._stop.is_set():
            processed = self.run_next()
            if not processed:
                self._event.wait(timeout=5)
                self._event.clear()

    def _recover_interrupted_tasks(self) -> None:
        self.database.execute(
            """
            UPDATE tasks
            SET status = 'failed', error_code = 'server_restarted',
                error_message = '服务器意外重启，转写进程已被中断',
                updated_at = ?
            WHERE status IN ('preparing', 'running')
            """,
            (_now(),),
        )

    def _update(self, task_id: str, *, status: str, progress: float, current_stage: Optional[str] = None) -> None:
        if current_stage is not None:
            self.database.execute(
                "UPDATE tasks SET status = ?, progress = ?, current_stage = ?, updated_at = ? WHERE id = ?",
                (status, progress, current_stage, _now(), task_id),
            )
        else:
            self.database.execute(
                "UPDATE tasks SET status = ?, progress = ?, updated_at = ? WHERE id = ?",
                (status, progress, _now(), task_id),
            )

    def _build_manifest(self, output_dir: Path) -> dict[str, list[dict[str, Any]]]:
        # Walk and locate expected outputs
        # transcribe.py outputs: {base}_funasr.json, {base}_通话记录.md, {base}_speaker_map.json, {base}_整理版.md
        results = []
        
        # We index the output files for download
        # PDF / MD / SRT will be compiled by Client, but Server should provide:
        # index 0: _通话记录.md
        # index 1: _整理版.md
        # index 2: _speaker_map.json
        # Let's find these files
        paths = list(output_dir.glob("*_通话记录.md")) + \
                list(output_dir.glob("*_整理版.md")) + \
                list(output_dir.glob("*_speaker_map.json")) + \
                list(output_dir.glob("*_funasr.json"))
        
        # De-duplicate and order
        unique_paths = []
        for p in paths:
            if p not in unique_paths:
                unique_paths.append(p)
                
        # Sort them so they correspond to reliable indices
        # We want to match:
        # - *_通话记录.md (index 0)
        # - *_整理版.md (index 1)
        # - *_speaker_map.json (index 2)
        # If any is missing, it's fine, we will just list what we have.
        def sort_key(p: Path):
            name = p.name
            if name.endswith("_通话记录.md"): return 0
            if name.endswith("_整理版.md"): return 1
            if name.endswith("_speaker_map.json"): return 2
            return 3
            
        unique_paths.sort(key=sort_key)

        for index, path in enumerate(unique_paths):
            data = path.read_bytes()
            # File category mapping (for helper identification)
            category = "transcript"
            if path.name.endswith("_整理版.md"):
                category = "speaker_text"
            elif path.name.endswith("_speaker_map.json"):
                category = "speaker_map"
            elif path.name.endswith("_funasr.json"):
                category = "raw_json"
                
            results.append(
                {
                    "index": index,
                    "filename": path.name,
                    "category": category,
                    "path": str(path),
                    "size_bytes": len(data),
                    "sha256": hashlib.sha256(data).hexdigest(),
                }
            )
        return {"results": results}


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()
