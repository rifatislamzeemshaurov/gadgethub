"""Per-session conversation history, stored as local JSON files or S3 objects.

Only chat turns (user/assistant text) live here. Uploaded PDFs are never
written through this module — see pdf_intake.py.
"""

import json
import os
from typing import Dict, List

import boto3
from botocore.exceptions import ClientError

USE_S3 = os.getenv("USE_S3", "false").lower() == "true"
S3_BUCKET = os.getenv("S3_BUCKET", "")
MEMORY_DIR = os.getenv("MEMORY_DIR", "../memory")

_s3_client = boto3.client("s3") if USE_S3 else None


def _key(session_id: str) -> str:
    return f"{session_id}.json"


def load_conversation(session_id: str) -> List[Dict]:
    """Load conversation history from storage."""
    if USE_S3:
        try:
            response = _s3_client.get_object(Bucket=S3_BUCKET, Key=_key(session_id))
            return json.loads(response["Body"].read().decode("utf-8"))
        except ClientError as e:
            if e.response["Error"]["Code"] == "NoSuchKey":
                return []
            raise
    file_path = os.path.join(MEMORY_DIR, _key(session_id))
    if os.path.exists(file_path):
        with open(file_path, "r", encoding="utf-8") as f:
            return json.load(f)
    return []


def save_conversation(session_id: str, messages: List[Dict]) -> None:
    """Save conversation history to storage."""
    if USE_S3:
        _s3_client.put_object(
            Bucket=S3_BUCKET,
            Key=_key(session_id),
            Body=json.dumps(messages, indent=2),
            ContentType="application/json",
        )
        return
    os.makedirs(MEMORY_DIR, exist_ok=True)
    file_path = os.path.join(MEMORY_DIR, _key(session_id))
    with open(file_path, "w", encoding="utf-8") as f:
        json.dump(messages, f, indent=2)
