from contextlib import asynccontextmanager
from datetime import datetime, timezone
import importlib.util
import json
import os
from pathlib import Path
import shutil
from typing import Optional
from uuid import uuid4

from fastapi import FastAPI, File, Header, HTTPException, Request, Response, UploadFile
from fastapi.responses import FileResponse

from .auth import require_token
from .config import Settings
from .database import Database
from .models import (
    HealthResponse,
    TaskCreateRequest,
    TaskStatusResponse,
    UploadResponse,
)
from .storage import Storage
from .worker import TaskWorker


def _probe_available_engines() -> list[str]:
    engines = []
    if importlib.util.find_spec("funasr") is not None:
        engines.append("funASR")
    if importlib.util.find_spec("mlx_audio") is not None:
        engines.append("vibeVoiceMLX")
    if importlib.util.find_spec("mlx_qwen3_asr") is not None:
        engines.append("qwen3ASR")
    return engines


def create_app(settings: Optional[Settings] = None) -> FastAPI:
    resolved_settings = settings or Settings.from_env()

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        app.state.settings = resolved_settings
        app.state.database = Database(resolved_settings.service_root / "tasks.sqlite3")
        app.state.storage = Storage(resolved_settings.service_root, app.state.database)
        app.state.worker = TaskWorker(app.state.database, resolved_settings, app.state.storage.output_root)
        
        # Probe remote available engines on startup to avoid slow imports on API requests
        app.state.available_engines = _probe_available_engines()
        
        # Cleanup expired items on start
        app.state.storage.cleanup_expired()
        # Start worker thread
        app.state.worker.start()
        
        try:
            yield
        finally:
            app.state.worker.stop()
            app.state.database.close()

    service = FastAPI(title="VoiceScribeServer", version="0.1.0", lifespan=lifespan)

    @service.middleware("http")
    async def enforce_json_limit(request: Request, call_next):
        content_length = request.headers.get("content-length")
        content_type = request.headers.get("content-type", "")
        if (
            content_length
            and content_type.startswith("application/json")
            and int(content_length) > 1024 * 1024
        ):
            from fastapi.responses import JSONResponse
            return JSONResponse(status_code=413, content={"detail": "Request too large"})
        return await call_next(request)

    @service.get("/live")
    def live() -> dict[str, str]:
        return {"status": "alive"}

    @service.get("/v1/health", response_model=HealthResponse)
    def health(
        request: Request,
        authorization: Optional[str] = Header(default=None),
    ) -> HealthResponse:
        require_token(resolved_settings.token, authorization)
        
        # Verify transcription script path is ready
        script_ready = (resolved_settings.scripts_dir / "transcribe.py").exists()
        
        queue_depth = request.app.state.database.fetchone(
            "SELECT COUNT(*) AS count FROM tasks WHERE status = 'queued'"
        )["count"]
        active = request.app.state.database.fetchone(
            """
            SELECT id FROM tasks
            WHERE status IN ('preparing', 'running')
            ORDER BY created_at ASC
            LIMIT 1
            """
        )
        return HealthResponse(
            api_version="1",
            service_version="0.1.0",
            runtime_state="ready" if script_ready else "unconfigured",
            queue_depth=queue_depth,
            active_task_id=active["id"] if active else None,
            available_disk_bytes=shutil.disk_usage(resolved_settings.data_root).free,
            available_engines=request.app.state.available_engines,
        )

    @service.get("/v1/system/stats")
    def system_stats(
        authorization: Optional[str] = Header(default=None),
    ) -> dict:
        require_token(resolved_settings.token, authorization)
        from .system_monitor import get_system_stats
        return get_system_stats(resolved_settings.data_root)

    @service.post("/v1/uploads", response_model=UploadResponse, status_code=201)
    def upload(
        request: Request,
        file: UploadFile = File(...),
        authorization: Optional[str] = Header(default=None),
    ) -> UploadResponse:
        require_token(resolved_settings.token, authorization)
        stored = request.app.state.storage.save_stream(file.filename or "upload", file.file)
        return UploadResponse(
            upload_id=stored.id,
            filename=stored.filename,
            size_bytes=stored.size_bytes,
            sha256=stored.sha256,
        )

    @service.post("/v1/tasks", response_model=TaskStatusResponse, status_code=202)
    def create_task(
        payload: TaskCreateRequest,
        request: Request,
        authorization: Optional[str] = Header(default=None),
    ) -> TaskStatusResponse:
        require_token(resolved_settings.token, authorization)
        
        if payload.command != "transcribe":
            raise HTTPException(status_code=422, detail="Unsupported command")
            
        # Security boundaries: prevent path manipulation
        forbidden = {"voxcpm_root", "output_directory", "reference_audio_path", "audio_path", "out_dir"}
        if forbidden.intersection(payload.arguments):
            raise HTTPException(status_code=422, detail="Filesystem paths are not accepted")
            
        task_id = str(uuid4())
        
        if payload.upload_id:
            request.app.state.storage.claim_upload(payload.upload_id, task_id)
            
        timestamp = datetime.now(timezone.utc).isoformat()
        request.app.state.database.execute(
            """
            INSERT INTO tasks (
              id, command, arguments_json, status, progress, current_stage, created_at, updated_at
            ) VALUES (?, ?, ?, 'queued', 0.0, '排队中...', ?, ?)
            """,
            (
                task_id,
                payload.command,
                json.dumps(payload.arguments, ensure_ascii=False),
                timestamp,
                timestamp,
            ),
        )
        request.app.state.worker.notify()
        return TaskStatusResponse(task_id=task_id, status="queued", progress=0.0, current_stage="排队中...")

    @service.get("/v1/tasks/{task_id}", response_model=TaskStatusResponse)
    def get_task(
        task_id: str,
        request: Request,
        authorization: Optional[str] = Header(default=None),
    ) -> TaskStatusResponse:
        require_token(resolved_settings.token, authorization)
        row = request.app.state.database.fetchone(
            "SELECT * FROM tasks WHERE id = ?", (task_id,)
        )
        if row is None:
            raise HTTPException(status_code=404, detail="Task not found")
            
        manifest = (
            json.loads(row["result_manifest_json"])
            if row["result_manifest_json"]
            else {"results": []}
        )
        # Avoid exposing full file path on server
        results = [
            {key: value for key, value in item.items() if key != "path"}
            for item in manifest["results"]
        ]
        
        error = None
        if row["error_code"]:
            error = {"code": row["error_code"], "message": row["error_message"]}
            
        return TaskStatusResponse(
            task_id=task_id,
            status=row["status"],
            progress=row["progress"],
            estimated_time_remaining=row["estimated_time_remaining"],
            current_stage=row["current_stage"],
            error=error,
            results=results,
        )

    @service.get("/v1/tasks/{task_id}/result/{index}")
    def download_result(
        task_id: str,
        index: int,
        request: Request,
        authorization: Optional[str] = Header(default=None),
    ):
        require_token(resolved_settings.token, authorization)
        row = request.app.state.database.fetchone(
            "SELECT status, result_manifest_json FROM tasks WHERE id = ?", (task_id,)
        )
        if row is None:
            raise HTTPException(status_code=404, detail="Task not found")
        if row["status"] != "completed" or not row["result_manifest_json"]:
            raise HTTPException(status_code=409, detail="Task result is not ready")
            
        results = json.loads(row["result_manifest_json"])["results"]
        if index < 0 or index >= len(results):
            raise HTTPException(status_code=404, detail="Result not found")
            
        result = results[index]
        path = Path(result["path"])
        
        # Determine media type based on filename
        media_type = "application/octet-stream"
        if result["filename"].endswith(".md"):
            media_type = "text/markdown"
        elif result["filename"].endswith(".json"):
            media_type = "application/json"
            
        return FileResponse(
            path,
            media_type=media_type,
            filename=result["filename"],
            headers={"X-Content-SHA256": result["sha256"]},
        )

    @service.delete("/v1/tasks/{task_id}", status_code=204)
    def delete_task(
        task_id: str,
        request: Request,
        authorization: Optional[str] = Header(default=None),
    ) -> Response:
        require_token(resolved_settings.token, authorization)
        row = request.app.state.database.fetchone(
            "SELECT status FROM tasks WHERE id = ?", (task_id,)
        )
        if row is not None:
            status = "cancelled" if row["status"] == "queued" else row["status"]
            request.app.state.database.execute(
                """
                UPDATE tasks
                SET cleanup_requested = 1, status = ?, updated_at = ?
                WHERE id = ?
                """,
                (status, datetime.now(timezone.utc).isoformat(), task_id),
            )
        return Response(status_code=204)

    return service


app = create_app()
