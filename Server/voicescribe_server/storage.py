from datetime import datetime, timezone
import hashlib
import os
from pathlib import Path
import shutil
from typing import BinaryIO
from uuid import uuid4

from .database import Database

ALLOWED_EXTENSIONS = {
    ".wav", ".wave", ".mp3", ".m4a", ".aac", ".flac", ".mp4", ".mov"
}
MAX_UPLOAD_BYTES = 250 * 1024 * 1024  # 250MB
STAGING_RETENTION_SECONDS = 3600  # 1 hour
TASK_RETENTION_SECONDS = 24 * 3600  # 24 hours


class StoredUpload:
    def __init__(self, upload_id: str, filename: str, path: Path, size_bytes: int, sha256: str) -> None:
        self.id = upload_id
        self.filename = filename
        self.path = path
        self.size_bytes = size_bytes
        self.sha256 = sha256


class Storage:
    def __init__(self, root: Path, database: Database) -> None:
        self.root = root
        self.database = database
        self.staging_root = self.root / "uploads" / "staging"
        self.output_root = self.root / "tasks" / "outputs"
        
        self.staging_root.mkdir(parents=True, exist_ok=True)
        self.output_root.mkdir(parents=True, exist_ok=True)

    def save_stream(self, filename: str, stream: BinaryIO) -> StoredUpload:
        # Sanitize filename
        safe_filename = Path(filename).name
        suffix = Path(safe_filename).suffix.lower()
        if suffix not in ALLOWED_EXTENSIONS:
            from fastapi import HTTPException
            raise HTTPException(status_code=415, detail="Unsupported audio format")

        # Check disk space (refuse if < 10 GB)
        disk_usage = shutil.disk_usage(self.root)
        if disk_usage.free < 10 * 1024 * 1024 * 1024:
            from fastapi import HTTPException
            raise HTTPException(status_code=507, detail="Low disk space on server")

        upload_id = str(uuid4())
        dest_dir = self.staging_root / upload_id
        dest_dir.mkdir(parents=True, exist_ok=True)
        dest_path = dest_dir / safe_filename

        hasher = hashlib.sha256()
        size = 0

        try:
            with open(dest_path, "wb") as f:
                while True:
                    chunk = stream.read(64 * 1024)
                    if not chunk:
                        break
                    size += len(chunk)
                    if size > MAX_UPLOAD_BYTES:
                        raise ValueError("File exceeds maximum upload size")
                    hasher.update(chunk)
                    f.write(chunk)
        except Exception as e:
            if dest_path.exists():
                os.remove(dest_path)
            shutil.rmtree(dest_dir, ignore_errors=True)
            from fastapi import HTTPException
            raise HTTPException(status_code=413, detail=str(e))

        sha256 = hasher.hexdigest()
        timestamp = datetime.now(timezone.utc).isoformat()

        self.database.execute(
            """
            INSERT INTO uploads (id, filename, path, sha256, size_bytes, created_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            (upload_id, safe_filename, str(dest_path), sha256, size, timestamp),
        )

        return StoredUpload(upload_id, safe_filename, dest_path, size, sha256)

    def claim_upload(self, upload_id: str, task_id: str) -> Path:
        row = self.database.fetchone(
            "SELECT path, claimed_task_id FROM uploads WHERE id = ?", (upload_id,)
        )
        if row is None:
            from fastapi import HTTPException
            raise HTTPException(status_code=404, detail="Upload not found")
        if row["claimed_task_id"] is not None:
            from fastapi import HTTPException
            raise HTTPException(status_code=409, detail="Upload already claimed by another task")
        
        self.database.execute(
            "UPDATE uploads SET claimed_task_id = ? WHERE id = ?",
            (task_id, upload_id),
        )
        return Path(row["path"])

    def upload_path(self, upload_id: str) -> Path:
        return self.staging_root / upload_id

    def task_output_dir(self, task_id: str) -> Path:
        return self.output_root / task_id

    def cleanup_expired(self) -> None:
        now = datetime.now(timezone.utc)
        
        # 1. Clean up uploads staged > 1 hour ago and not claimed
        rows = self.database.fetchall("SELECT id, path FROM uploads WHERE claimed_task_id IS NULL")
        for row in rows:
            # Check created_at (actually we can just check disk files or parse SQLite time)
            up_id = row["id"]
            up_dir = self.staging_root / up_id
            if up_dir.exists():
                mtime = datetime.fromtimestamp(up_dir.stat().st_mtime, timezone.utc)
                if (now - mtime).total_seconds() > STAGING_RETENTION_SECONDS:
                    shutil.rmtree(up_dir, ignore_errors=True)
                    self.database.execute("DELETE FROM uploads WHERE id = ?", (up_id,))

        # 2. Clean up task folders for completed/failed/cancelled tasks > 24 hours ago or requested cleanup
        tasks = self.database.fetchall(
            """
            SELECT id FROM tasks 
            WHERE (status IN ('completed', 'failed', 'cancelled') AND julianday('now') - julianday(updated_at) > 1.0)
               OR (cleanup_requested = 1 AND status != 'running')
            """
        )
        for t in tasks:
            task_id = t["id"]
            # Clean output dir
            out_dir = self.output_dir(task_id)
            if out_dir.exists():
                shutil.rmtree(out_dir, ignore_errors=True)
            # Also clean claimed upload if any
            upload = self.database.fetchone("SELECT id, path FROM uploads WHERE claimed_task_id = ?", (task_id,))
            if upload:
                up_dir = self.staging_root / upload["id"]
                if up_dir.exists():
                    shutil.rmtree(up_dir, ignore_errors=True)
                self.database.execute("DELETE FROM uploads WHERE id = ?", (upload["id"],))

            # Update database record (remove paths, set cleaned)
            self.database.execute(
                """
                UPDATE tasks
                SET result_manifest_json = NULL, cleanup_requested = 2, updated_at = ?
                WHERE id = ?
                """,
                (now.isoformat(), task_id),
            )

    def output_dir(self, task_id: str) -> Path:
        return self.output_root / task_id
