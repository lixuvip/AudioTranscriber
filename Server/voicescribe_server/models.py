from __future__ import annotations
from typing import Any, Optional, Dict, List
from pydantic import BaseModel, Field


class HealthResponse(BaseModel):
    api_version: str
    service_version: str
    runtime_state: str
    queue_depth: int
    active_task_id: Optional[str]
    available_disk_bytes: int
    available_engines: Optional[List[str]] = None


class UploadResponse(BaseModel):
    upload_id: str
    filename: str
    size_bytes: int
    sha256: str


class TaskCreateRequest(BaseModel):
    command: str
    arguments: Dict[str, Any] = Field(default_factory=dict)
    upload_id: Optional[str] = None


class TaskStatusResponse(BaseModel):
    task_id: str
    status: str
    progress: float = 0.0
    estimated_time_remaining: Optional[str] = None
    current_stage: Optional[str] = None
    error: Optional[Dict[str, str]] = None
    results: List[Dict[str, Any]] = Field(default_factory=list)
