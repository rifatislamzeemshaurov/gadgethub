"""Uploaded-PDF handling.

A visitor can upload a gadget spec sheet / product page to get catalog
alternatives. The file is parsed to text, sent through the same LLM metadata
schema used for the catalog, and then used as a search query against the
catalog. The uploaded file is written to a temp path only for the moment
ragwire needs a real filesystem path to parse it, and is deleted immediately
after — its text and bytes are never written to the vector store or kept
past this call.
"""

from __future__ import annotations

import logging
import os
import tempfile
from pathlib import Path
from typing import Any, Dict

from rag_engine import CATEGORIES, CATEGORY_FIELDS, _titleize, doc_to_product, get_rag, search_catalog

logger = logging.getLogger("gadgethub")

MAX_UPLOAD_BYTES = 15 * 1024 * 1024  # 15 MB


async def analyze_pdf(file_bytes: bytes, filename: str) -> Dict[str, Any]:
    if len(file_bytes) > MAX_UPLOAD_BYTES:
        return {"success": False, "error": "File is larger than 15 MB."}

    rag = get_rag()
    suffix = Path(filename).suffix or ".pdf"

    fd, tmp_path = tempfile.mkstemp(suffix=suffix)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(file_bytes)

        # Parse-only — this never calls rag.ingest_*, so nothing here is
        # embedded or written to Qdrant.
        result = rag.loader.load(tmp_path)
    finally:
        os.remove(tmp_path)  # always discard the uploaded file after parsing

    if not result["success"]:
        return {"success": False, "error": result["error"] or "Could not read that file."}

    text = result["text_content"]
    if not text.strip():
        return {"success": False, "error": "No readable text found in that file."}

    try:
        extracted = rag.extract_metadata(text)
    except Exception as e:
        logger.exception("Metadata extraction failed for uploaded PDF")
        return {"success": False, "error": f"Could not analyze that file: {e}"}

    category = extracted.get("category")
    first_spec = next(
        (extracted.get(field) for field in CATEGORY_FIELDS.get(category, []) if extracted.get(field)),
        None,
    )
    query_parts = [
        extracted.get("product_name"),
        extracted.get("brand_or_make"),
        category,
        first_spec,
    ]
    query = " ".join(p for p in query_parts if p) or text[:200]

    filters = {"category": category} if category in CATEGORIES else None
    alt_docs = search_catalog(query, filters=filters, top_k=5)
    alternatives = [doc_to_product(d) for d in alt_docs]

    # Display-only casing fix — ragwire's extractor lowercases every string
    # it returns (see rag_engine._titleize). The raw lowercase values above
    # already built the search query; this only affects what's shown to the
    # visitor.
    if extracted.get("product_name"):
        extracted["product_name"] = _titleize(extracted["product_name"])
    if extracted.get("brand_or_make"):
        extracted["brand_or_make"] = _titleize(extracted["brand_or_make"])

    return {
        "success": True,
        "extracted": extracted,
        "alternatives": alternatives,
    }
