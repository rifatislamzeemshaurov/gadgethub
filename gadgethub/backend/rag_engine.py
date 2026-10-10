"""The gadget-catalog RAG pipeline: singleton RAGWire connection, retrieval
tools, and a tool-calling LangGraph agent that answers strictly from the
already-ingested Qdrant catalog. Nothing here ever writes to the vector
store — that only happens through ../ingestion/rag_pipeline.ipynb.
"""

from __future__ import annotations

import asyncio
import logging
import os
from functools import lru_cache
from pathlib import Path
from typing import Any, AsyncIterator, Dict, List, Optional

from dotenv import load_dotenv

load_dotenv(override=True)

logger = logging.getLogger("gadgethub")

BACKEND_DIR = Path(__file__).resolve().parent
PIPELINE_YAML = BACKEND_DIR / "pipeline.yaml"

CATEGORIES = ("camera", "laptop", "smart_tv", "smartwatch")

# Only the fields matching a product's own category are ever populated in
# Qdrant — the rest come back null/missing and are skipped below.
CATEGORY_FIELDS: Dict[str, List[str]] = {
    "camera": ["sensor_ram", "storage_cards", "graphics_engine", "key_specs", "camera_description"],
    "laptop": ["memory_ram", "storage_ssd", "graphics_card", "core_architecture"],
    "smart_tv": ["screen_size", "resolution_standard", "display_tech_specialty"],
    "smartwatch": ["memory_and_storage", "graphics_coprocessor", "sensor_array", "architectural_description"],
}

ALL_CATEGORY_FIELDS = [field for fields in CATEGORY_FIELDS.values() for field in fields]

CHAT_MODEL = os.getenv("OPENAI_MODEL", "gpt-4o-mini")

# ragwire's MetadataExtractor lowercases every extracted string before it's
# stored (MetadataExtractor.extract() — not configurable). That's fine for
# matching/filtering, but "sony", "dell", "eos r5 mark iv" reads as sloppy
# in a client-facing UI. Brand/product names are the two fields users
# actually read as proper nouns, so titleize just those two for display —
# spec values stay as extracted, they're shown as labeled fields, not prose.
_ACRONYMS = {
    "ai", "amd", "asic", "asus", "dslr", "fhd", "gb", "gps",
    "gpu", "hd", "hdmi", "hp", "intel", "ip67", "ip68", "ips", "ir", "kb",
    "led", "lg", "lte", "mah", "mb", "msi", "nfc", "nvidia", "oled", "os",
    "amoled", "qled", "qhd", "wqhd", "ram", "rog", "rtx", "gtx", "sd",
    "sim", "soc", "ssd", "tb", "tcl", "tgp", "tof", "tv", "uhd", "usb",
    "usd", "vpro", "zte", "4k", "8k",
}

# A handful of well-known brand names use internal capitals that a plain
# "uppercase the whole word" rule would get wrong (GEFORCE, not GeForce).
_BRAND_OVERRIDES = {
    "gopro": "GoPro",
    "oneplus": "OnePlus",
    "playstation": "PlayStation",
    "geforce": "GeForce",
    "iphone": "iPhone",
    "ipad": "iPad",
    "imac": "iMac",
    "macbook": "MacBook",
    "airpods": "AirPods",
}


def _titleize(value: Optional[str]) -> Optional[str]:
    """Best-effort display casing: title-case each word, fixing known
    brand names and upper-casing known tech acronyms. Applied only to
    short proper-noun fields."""
    if not value:
        return value
    words = []
    for word in value.split(" "):
        bare = word.strip("()[]{}/,.")
        lower = bare.lower()
        if lower in _BRAND_OVERRIDES:
            words.append(word.replace(bare, _BRAND_OVERRIDES[lower]))
        elif lower in _ACRONYMS:
            words.append(word.replace(bare, bare.upper()))
        elif word:
            words.append(word[:1].upper() + word[1:])
        else:
            words.append(word)
    return " ".join(words)


@lru_cache(maxsize=1)
def get_rag():
    """Lazily build the singleton RAGWire pipeline.

    Connects to the already-ingested Qdrant collection (pipeline.yaml has
    force_recreate: false) — this never re-embeds or deletes anything.
    """
    from ragwire import RAGWire

    return RAGWire(str(PIPELINE_YAML))


def doc_to_product(doc: Any) -> Dict[str, Any]:
    """Flatten a retrieved RAGWire Document into a plain dict the API/UI renders.

    Every fact here comes straight from Qdrant metadata — nothing is
    invented, so the UI's product cards can never disagree with the
    catalog. brand_or_make/product_name get a display-only titlecase pass
    (see _titleize) since ragwire's extractor lowercases every stored
    string; the underlying value is never altered, just how it's cased.
    """
    m = doc.metadata
    category = m.get("category")
    specs: Dict[str, str] = {}
    for field in CATEGORY_FIELDS.get(category, []):
        value = m.get(field)
        if value:
            specs[field] = value
    return {
        "category": category,
        "brand_or_make": _titleize(m.get("brand_or_make")),
        "product_name": _titleize(m.get("product_name")),
        "price": m.get("price"),
        "specs": specs,
    }


def _format_result(doc: Any) -> str:
    """Compact, field-by-field text block for one product — what the LLM reads."""
    m = doc.metadata
    category = m.get("category", "unknown")
    lines = [
        f"Product: {_titleize(m.get('product_name')) or 'unknown'}",
        f"Brand: {_titleize(m.get('brand_or_make')) or 'unknown'}",
        f"Category: {category}",
        f"Price: {m.get('price') or 'null'}",
    ]
    for field in CATEGORY_FIELDS.get(category, []):
        value = m.get(field)
        if value:
            lines.append(f"{field.replace('_', ' ').title()}: {value}")
    return "\n".join(lines)


def _normalize_filters(filters: Optional[Dict]) -> Optional[Dict]:
    """Filter values must be lowercase, matching how `category` is stored."""
    if not filters:
        return filters
    return {k: (v.strip().lower() if isinstance(v, str) else v) for k, v in filters.items()}


def _dedupe_append(collector: List[Dict[str, Any]], product: Dict[str, Any]) -> None:
    key = (product.get("category"), product.get("product_name"))
    if any((p.get("category"), p.get("product_name")) == key for p in collector):
        return
    collector.append(product)


_stored_values_cache: Optional[Dict[str, Any]] = None

# The only fields ever passed as a search_products filter (see SYSTEM_PROMPT
# and _filter_context_block below) — vs. rag.filter_fields, which is every
# metadata.yaml field (22 of them, several long free-text description
# fields like camera_description/architectural_description). Facet-fetching
# those is slow and sometimes times out for no benefit: nothing ever filters
# on them, so scoping to just these three keeps warm-up fast and keeps the
# system prompt's catalog block small without dropping anything the agent
# actually uses.
FILTER_CONTEXT_FIELDS = ["category", "brand_or_make", "product_name"]


def _stored_filter_values() -> Dict[str, Any]:
    """Cached category/product_name/brand_or_make facet values for
    _filter_context_block.

    ragwire's own rag.get_filter_context() re-fetches these from Qdrant via
    one facet HTTP call per field on every single invocation — with a
    static, already-ingested catalog that's pure added latency on every
    agent turn for values that never change while this process is running.
    Fetched once per process instead.
    """
    global _stored_values_cache
    if _stored_values_cache is None:
        rag = get_rag()
        _stored_values_cache = rag.get_field_values(FILTER_CONTEXT_FIELDS, limit=50)
    return _stored_values_cache


def search_catalog(query: str, filters: Optional[Dict] = None, top_k: Optional[int] = None) -> List[Any]:
    """Retrieve straight from Qdrant, with the same filtered→unfiltered fallback
    the notebook agent uses (a category mismatch shouldn't lose a real match)."""
    rag = get_rag()
    norm = _normalize_filters(filters)
    results = rag.retrieve(query=query, top_k=top_k, filters=norm)
    if not results and norm:
        results = rag.retrieve(query=query, top_k=top_k, filters={})
    return results


def _filter_context_block() -> str:
    """Static block listing the known category/brand_or_make/product_name
    values, built once per process from the warmed-up facet cache.

    This used to be a get_filter_context tool the agent had to decide to call
    on every turn — a full extra LLM round-trip just to fetch information
    that's static for the life of the process. Folding it straight into the
    system prompt gives the agent the same exact-spelling values on every
    turn (more reliably than a tool call it might forget) while cutting that
    round-trip entirely.
    """
    stored_values = _stored_filter_values()
    lines = ["## Catalog Filter Values", ""]
    for field in FILTER_CONTEXT_FIELDS:
        lines.append(f"- **{field}**: {stored_values.get(field, [])}")
    return "\n".join(lines)


def _build_tools(collector: List[Dict[str, Any]]):
    """Build a fresh search_products closure bound to this request's product
    collector.

    A new one is built per chat turn (cheap — no network calls happen until
    the tool is actually invoked) so concurrent requests never share state.
    """
    from langchain_core.tools import tool

    @tool
    def search_products(query: str, filters: Optional[Dict] = None) -> str:
        """
        Search the GadgetHub product catalog.

        IMPORTANT RULES:
        - Always retrieve from the vector database. Never fabricate a product.
        - If a category is determined (camera, laptop, smart_tv, smartwatch),
          pass it as a filter.
        - Category filter values MUST be lowercase exactly as stored.

        Example:
            search_products(
                query="rugged watch for diving",
                filters={"category": "smartwatch"},
            )
        """
        results = search_catalog(query, filters=filters)
        if not results:
            return "NO_RESULTS_FOUND"
        for doc in results:
            _dedupe_append(collector, doc_to_product(doc))
        return "\n\n".join(_format_result(doc) for doc in results)

    return [search_products]


SYSTEM_PROMPT = """
You are the GadgetHub Store Assistant with access to a live product catalog
(gadgethub-catalog-openai-qdrant): smartwatches, smart TVs, laptops, and
cameras.

The collection contains gadget product records with:
- category (camera | laptop | smart_tv | smartwatch)
- brand_or_make, product_name, price
- category-specific fields (only the ones matching a product's category are set):
  - camera: sensor_ram, storage_cards, graphics_engine, key_specs, camera_description
  - laptop: memory_ram, storage_ssd, graphics_card, core_architecture
  - smart_tv: screen_size, resolution_standard, display_tech_specialty
  - smartwatch: memory_and_storage, graphics_coprocessor, sensor_array, architectural_description

Some turns include a note that the visitor just uploaded a product spec sheet
PDF, with its extracted category/product_name/brand/specs. Treat that the
same as if they had typed those details themselves — use it to decide what
to search for (e.g. "find something cheaper" or "what pairs well with this").

==================================================
CLASSIFY EVERY USER MESSAGE
==================================================

A) DEMAND — the user explicitly names a product or category they want
   (e.g. "show me a smartwatch", "I need a gaming laptop", "recommend a
   camera", "I want a new TV").
B) PROBLEM — the user describes an issue a product can help with
   (e.g. "my laptop can't handle video editing anymore", "I can't see the
   screen from across the room", "I want to track my heart rate on runs",
   "my photos never come out sharp at night").
C) HINT — an indirect signal about their needs that implies a category
   (e.g. "I'm training for a marathon", "I edit 4K footage every day",
   "I host movie nights every week", "I post travel photography daily").
   If the hint is too vague to map to one category with reasonable confidence,
   ask ONE short clarifying question instead of guessing a category to force
   a search.
D) GENERAL CHAT — greetings or small talk unrelated to gadgets. Reply in one
   short sentence. Do not search.

If the message is unrelated to gadgets (general trivia, unrelated tasks,
requests for advice outside electronics), decline in one sentence and
redirect: "I can only help with product recommendations for smartwatches,
smart TVs, laptops, and cameras."

==================================================
GENERAL RULES — NEVER HALLUCINATE
==================================================

- Never answer a product question from memory or general knowledge.
- Every product fact you state must come from search_products in the
  current turn — never invent a product, price, spec, or feature.
- Never merge details from two different products into one line.
- Copy retrieved values exactly — do not rewrite prices or specs.
- The exact product details (name, brand, price, specs) are shown to the
  user separately as cards built straight from the retrieved data — never
  repeat them as a list or table in your own reply. Do not write a numbered
  or bulleted product list, and do not restate prices/specs field by
  field — the cards already show all of that.

==================================================
BEFORE SEARCHING
==================================================

1. Classify the message (A-D above).
2. For A/B/C, decide the single most likely category: camera, laptop,
   smart_tv, or smartwatch. If the need genuinely spans more than one
   category, search without a category filter rather than guessing one.
3. Match that category against the exact stored spelling in "Catalog Filter
   Values" below before searching — filter values are case-sensitive and
   stored lowercase.
4. Call search_products with filters={"category": "..."} (or filters={}
   when no single category applies).

==================================================
NO RESULTS
==================================================

If search_products returns NO_RESULTS_FOUND, reply with exactly one short
sentence: "I couldn't find a matching product in our catalog right now."
Do not also restate this a second way in the same reply.

==================================================
OUTPUT RULES — KEEP IT SHORT AND FAST
==================================================

- No greetings, no filler, no repeating the user's question back.
- 1-3 short sentences, plain prose, chat-widget length. No markdown lists,
  no numbered items, no headers, no bold text, no per-product breakdown —
  the product cards below your reply already carry every field. Your job is
  only to frame the results in one or two sentences, never to restate them.

  BAD (never do this — repeats what the cards already show):
  "Here are some laptops with a dedicated GPU:
  1. **Dell - XPS 15**: RTX 4060, 32GB RAM...
  2. **ASUS - ROG Zephyrus**: RTX 4070, 16GB RAM..."

  GOOD (do this instead):
  "Found a few options below with a dedicated GPU — the ASUS has the newer
  card if raw render speed matters most."
- Never end with a wall of questions; give useful framing first.
"""


def _to_lc_messages(history: List[Dict[str, str]], new_message: str):
    from langchain_core.messages import AIMessage, HumanMessage

    lc_messages = []
    for msg in history[-10:]:
        if msg["role"] == "user":
            lc_messages.append(HumanMessage(msg["content"]))
        elif msg["role"] == "assistant":
            lc_messages.append(AIMessage(msg["content"]))
    lc_messages.append(HumanMessage(new_message))
    return lc_messages


def _build_agent(collector: List[Dict[str, Any]]):
    from langchain_openai import ChatOpenAI
    from langgraph.prebuilt import create_react_agent

    llm = ChatOpenAI(model=CHAT_MODEL, temperature=0, streaming=True)
    tools = _build_tools(collector)
    prompt = f"{SYSTEM_PROMPT}\n\n{_filter_context_block()}"
    return create_react_agent(model=llm, tools=tools, prompt=prompt)


def _make_stage_callback(queue: "asyncio.Queue[Optional[Dict[str, Any]]]"):
    """Build a callback handler that pushes human-readable progress stages
    onto the queue as the agent's tool calls fire, so the UI can show real
    (not simulated) status."""
    from langchain_core.callbacks import AsyncCallbackHandler

    class StageCallback(AsyncCallbackHandler):
        async def on_llm_start(self, *args, **kwargs) -> None:
            await queue.put({"type": "status", "stage": "Thinking through your question..."})

        async def on_chat_model_start(self, *args, **kwargs) -> None:
            await queue.put({"type": "status", "stage": "Thinking through your question..."})

        async def on_tool_start(self, serialized, input_str, **kwargs) -> None:
            name = (serialized or {}).get("name", "")
            label = {
                "search_products": "Searching the gadget catalog...",
            }.get(name, "Working...")
            await queue.put({"type": "status", "stage": label})

        async def on_tool_end(self, output, **kwargs) -> None:
            await queue.put({"type": "status", "stage": "Reviewing what we found..."})

        async def on_llm_end(self, *args, **kwargs) -> None:
            await queue.put({"type": "status", "stage": "Writing your answer..."})

    return StageCallback()


async def stream_chat(message: str, history: List[Dict[str, str]]) -> AsyncIterator[Dict[str, Any]]:
    """Run the agent for one turn, yielding status events as it works and a
    final event with the reply text plus the grounded product list."""
    queue: "asyncio.Queue[Optional[Dict[str, Any]]]" = asyncio.Queue()
    collector: List[Dict[str, Any]] = []
    handler = _make_stage_callback(queue)

    yield {"type": "status", "stage": "Thinking through your question..."}

    async def run() -> None:
        try:
            agent = _build_agent(collector)
            lc_messages = _to_lc_messages(history, message)
            full_response = ""
            async for event in agent.astream_events(
                {"messages": lc_messages},
                version="v2",
                config={"callbacks": [handler]},
            ):
                if event["event"] == "on_chat_model_stream":
                    # Only the react agent's own node ("agent") produces the
                    # natural-language reply — a tool invocation never emits
                    # on_chat_model_stream on its own, but this guards against
                    # any future tool that internally calls an LLM leaking
                    # its output into the user-visible stream.
                    if event.get("metadata", {}).get("langgraph_node") != "agent":
                        continue
                    content = event["data"]["chunk"].content
                    if content:
                        full_response += content
                        await queue.put({"type": "token", "content": content})
            await queue.put({"type": "final", "response": full_response, "products": collector})
        except Exception as e:  # surfaced to the client as a normal error event
            logger.exception("Agent run failed")
            await queue.put({"type": "error", "message": str(e)})
        finally:
            await queue.put(None)

    task = asyncio.create_task(run())
    try:
        while True:
            item = await queue.get()
            if item is None:
                break
            yield item
    finally:
        await task
