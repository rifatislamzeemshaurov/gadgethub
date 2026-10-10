"""Shared-secret gate: only requests carrying the configured API key reach the API.

This is a simple shared-secret check, not real user auth — the key ships
inside the public frontend bundle (NEXT_PUBLIC_API_KEY), so treat it as a
"only our own UI talks to this backend" gate combined with CORS, not a
security boundary against a determined attacker who reads the bundle.
"""

import os

from fastapi import Header, HTTPException

API_KEY = os.getenv("API_KEY_UI", "")


async def require_api_key(x_api_key: str = Header(default="")) -> None:
    if not API_KEY:
        # Fail closed: an unconfigured key must never mean "let everyone in".
        raise HTTPException(status_code=500, detail="Server API key is not configured")
    if x_api_key != API_KEY:
        raise HTTPException(status_code=401, detail="Invalid or missing API key")
