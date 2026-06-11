import hmac
from typing import Optional
from fastapi import Header, HTTPException


def require_token(expected_token: str, authorization: Optional[str]) -> None:
    prefix = "Bearer "
    supplied = authorization[len(prefix):] if authorization and authorization.startswith(prefix) else ""
    if not supplied or not hmac.compare_digest(supplied, expected_token):
        raise HTTPException(status_code=401, detail="Unauthorized")
