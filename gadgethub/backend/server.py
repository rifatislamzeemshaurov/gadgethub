import asyncio
import json
import logging
import os
import uuid
from contextlib import asynccontextmanager
from datetime import datetime
from typing import Optional

from dotenv import load_dotenv
from fastapi import Depends, FastAPI, File, Form, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import StreamingResponse
from pydantic import BaseModel

load_dotenv(override=True)

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("gadgethub")

from auth import require_api_key  # noqa: E402
from memory import load_conversation, save_conversation  # noqa: E402
from pdf_intake import analyze_pdf  # noqa: E402
from rag_engine import get_rag, stream_chat  # noqa: E402
from rag_engine import _stored_filter_values as warm_filter_values  # noqa: E402


@asynccontextmanager
async def lifespan(app: FastAPI):
    async def warm_up():
        # Connecting to Qdrant + confirming payload indexes takes ~20-30s the
        # first time in a fresh process. Doing it here (in the background, at
        # boot) keeps that cost off a real user's first chat message instead
        # of making them wait through it.
        try:
            await asyncio.to_thread(get_rag)
            await asyncio.to_thread(warm_filter_values)
            logger.info("RAG pipeline warmed up and ready")
        except Exception:
            logger.exception("RAG pipeline warm-up failed — first chat request will retry it")

    asyncio.create_task(warm_up())
    yield


app = FastAPI(title="GadgetHub API", lifespan=lifespan)

origins = os.getenv("CORS_ORIGINS", "http://localhost:3000").split(",")
app.add_middleware(
    CORSMiddleware,
    allow_origins=origins,
    allow_credentials=False,
    allow_methods=["GET", "POST", "OPTIONS"],
    allow_headers=["*"],
)


class ChatRequest(BaseModel):
    message: str
    session_id: Optional[str] = None


class UploadResponse(BaseModel):
    success: bool
    session_id: str
    message: Optional[str] = None
    error: Optional[str] = None
    extracted: Optional[dict] = None
    alternatives: Optional[list] = None


def _sse(event: dict) -> str:
    return f"data: {json.dumps(event)}\n\n"


@app.get("/")
async def root():
    return {"message": "GadgetHub API", "memory_enabled": True, "storage": "S3" if os.getenv("USE_S3", "false").lower() == "true" else "local"}


@app.get("/health")
async def health_check():
    return {"status": "healthy"}


@app.post("/chat", dependencies=[Depends(require_api_key)])
async def chat(request: ChatRequest):
    session_id = request.session_id or str(uuid.uuid4())
    conversation = load_conversation(session_id)

    async def event_stream():
        assistant_response = ""
        products: list = []
        try:
            async for event in stream_chat(request.message, conversation):
                if event["type"] == "final":
                    assistant_response = event["response"]
                    products = event.get("products", [])
                    yield _sse({"type": "final", "response": assistant_response, "products": products, "session_id": session_id})
                elif event["type"] == "error":
                    yield _sse({"type": "error", "message": event["message"], "session_id": session_id})
                    return
                else:
                    yield _sse(event)
        except Exception as e:
            logger.exception("Chat stream failed")
            yield _sse({"type": "error", "message": str(e), "session_id": session_id})
            return

        conversation.append({"role": "user", "content": request.message, "timestamp": datetime.now().isoformat()})
        conversation.append({"role": "assistant", "content": assistant_response, "timestamp": datetime.now().isoformat()})
        save_conversation(session_id, conversation)

    return StreamingResponse(event_stream(), media_type="text/event-stream")


@app.post("/upload", response_model=UploadResponse, dependencies=[Depends(require_api_key)])
async def upload(file: UploadFile = File(...), session_id: Optional[str] = Form(None)):
    session_id = session_id or str(uuid.uuid4())
    file_bytes = await file.read()

    result = await analyze_pdf(file_bytes, file.filename or "upload.pdf")

    if not result["success"]:
        return UploadResponse(success=False, session_id=session_id, error=result["error"])

    extracted = result["extracted"]
    alternatives = result["alternatives"]

    message = f"Scanned successfully: {file.filename or 'upload.pdf'}"

    summary_bits = [f"{k}: {v}" for k, v in extracted.items() if v]
    summary = message + ". Extracted: " + "; ".join(summary_bits)
    if alternatives:
        names = ", ".join(p["product_name"] for p in alternatives if p.get("product_name"))
        summary += f". Suggested alternatives from the catalog: {names}."

    conversation = load_conversation(session_id)
    conversation.append(
        {"role": "user", "content": f"[Uploaded file: {file.filename or 'upload.pdf'}]", "timestamp": datetime.now().isoformat()}
    )
    conversation.append({"role": "assistant", "content": summary, "timestamp": datetime.now().isoformat()})
    save_conversation(session_id, conversation)

    return UploadResponse(success=True, session_id=session_id, message=message, extracted=extracted, alternatives=alternatives)


@app.get("/conversation/{session_id}", dependencies=[Depends(require_api_key)])
async def get_conversation(session_id: str):
    try:
        conversation = load_conversation(session_id)
        return {"session_id": session_id, "messages": conversation}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=8000)
