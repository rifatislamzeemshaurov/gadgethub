# Ingesting New PDFs

How to add new catalog PDFs to the GadgetHub RAG pipeline, and exactly which files/cells need to change depending on what you're adding.

There are two scenarios:

- **A. More products in an existing category** (e.g. another smartwatch catalog, same table layout as `rag_smartwatch_catalog_30_models.pdf`) — a few lines.
- **B. A brand new category** (e.g. headphones, tablets) — you write one new splitter function and extend the metadata schema.

---

## A. More PDFs for an existing category

1. Drop the new PDF into `data/`.
2. Open `rag_pipeline.ipynb` → section **"2. Prepare the catalog"** → the code cell with `CATALOGS = {...}`.
3. Add the new file to the `CATALOGS` dict under the existing category key, e.g.:

   ```python
   CATALOGS = {
       "smartwatch": "../data/rag_smartwatch_catalog_30_models.pdf",
       "smartwatch_2": ["../data/rag_smartwatch_catalog_30_models.pdf", "../data/new_smartwatch_catalog.pdf"],
       ...
   }
   ```

   Simplest approach: change the staging loop to accept a list of paths per category instead of a single string, or just loop twice. The cleanest minimal edit is to make each `CATALOGS` value a **list** of paths and adjust the loop:

   ```python
   for category, paths in CATALOGS.items():
       for path in paths if isinstance(paths, list) else [paths]:
           result = rag.loader.load(path)
           ...
   ```

4. **Only if the new PDF's table layout differs** from the existing one for that category (different field labels, different structure) — the existing `split_*` function will silently produce wrong or empty results. Check first:

   ```python
   result = rag.loader.load("../data/new_smartwatch_catalog.pdf")
   print(result["text_content"][:3000])
   ```

   Compare against what the current splitter expects (see the anchor comment at the top of each `split_*` function). If the layout matches, no code changes needed beyond step 3. If it doesn't match, treat it as scenario B below — write a new splitter and register it in `SPLITTERS` under a differently-named key (or make the existing splitter handle both layouts).

5. Re-run the notebook (see **"Re-running after changes"** below).

---

## B. A brand new category

Example: adding a `headphones` category.

### 1. Put the PDF in `data/`

### 2. Inspect its structure

Before writing anything, look at how MarkItDown actually extracts the text — don't guess:

```python
result = rag.loader.load("../data/rag_headphones_catalog.pdf")
print(result["text_content"][:3000])
```

Find, for a single product entry:
- A **label that appears exactly once per product** and nowhere else (your split anchor) — e.g. a unique spec label like `Driver Size` or a heading like `MODEL #01`.
- Whether brand/name/price sit **before** that anchor (look-behind, like `split_camera`/`split_brand_make`) or the anchor **is** the heading itself (look-forward, like `split_smartwatch`).
- A reliable **end marker** for the block (a closing sentence, a footer, or — if there isn't one — the position of the *next* product's anchor, computed via line offsets like `split_camera` does, so nothing leaks across the boundary).

### 3. Write a new splitter function

In the same cell as the other `split_*` functions (`rag_pipeline.ipynb`, section 2), add:

```python
def split_headphones(text: str) -> list[tuple[str, str]]:
    # describe your anchor + end marker here
    ...
    return entries  # list of (product_name, full_block_text)
```

Reuse `split_brand_make` directly if the new catalog happens to share the `Brand / Make` layout — no new function needed.

Return format must match the others: a list of `(product_name, block_text)` tuples — `product_name` is only used for the staged filename slug, `block_text` is the literal text handed to the LLM metadata extractor, so don't rewrite/reformat it beyond trimming.

### 4. Register it

Same cell, in `CATALOGS` and `SPLITTERS`:

```python
CATALOGS = {
    ...,
    "headphones": "../data/rag_headphones_catalog.pdf",
}
SPLITTERS = {
    ...,
    "headphones": split_headphones,
}
```

### 5. Extend `rag_metadata.yaml`

This is what makes extraction accurate — it's the literal instructions the LLM follows per chunk. Open `ingestion/rag_metadata.yaml`:

- In the `category` field's `description`, add `headphones` to the list of valid values (rule 4 in the `prompt` block too — the category → fields mapping list).
- Add a new `# --- Headphones Specific Fields ---` section with one field per spec column in the catalog (mirror the existing camera/laptop/smart_tv/smartwatch sections): `name`, `type: string`, `nullable: true`, and a `description` telling the LLM exactly which literal label to copy from (e.g. `"Only when category is headphones: copy the exact value from 'Driver Size'. Null for other categories."`).
- Keep the same rules: copy character-for-character, null when absent, never guess.

### 6. Extend the agent tool + system prompt (`rag_pipeline.ipynb`, section 5)

In the tools cell:

```python
CATEGORY_FIELDS = {
    ...,
    "headphones": ["driver_size", "impedance", "..."],  # your new field names, no embedding_hash/repository_index-style internal fields
}
```

In the `SYSTEM_PROMPT` cell, `headphones` needs to appear in **every** place `camera | laptop | smart_tv | smartwatch` is enumerated — there are several, all in that one string:
- The collection field summary near the top (`category (camera | laptop | ...)` + the category-specific fields list).
- `BEFORE SEARCHING` step 2 (`decide the single most likely category: camera, laptop, ...`).
- The off-topic decline sentence (`"I can only help with product recommendations for ..."`).

Also update the `get_filter_context` tool's docstring (same cell, just above `SYSTEM_PROMPT`) — it has its own short `category (camera | laptop | smart_tv | smartwatch)` line.

### 7. Check chunk size

Staged product files must fit in **one** chunk (see the comment in `rag_pipeline.yaml`) — otherwise a retrieved chunk may carry only part of a product's specs. After staging, check the longest new block:

```python
lens = [len(block) for _, block in split_headphones(result["text_content"])]
print(max(lens))
```

If it exceeds `splitter.chunk_size` in `rag_pipeline.yaml` (currently `1200`), raise `chunk_size` there.

---

## Re-running after changes

`vectorstore.force_recreate: true` in `rag_pipeline.yaml` means every time the `rag = RAGWire('rag_pipeline.yaml')` cell runs, the Qdrant collection is **dropped and rebuilt from scratch**. Two ways to pick up new PDFs:

- **Full rebuild (default, simplest):** restart the kernel and run the whole notebook top to bottom. Staging re-splits every catalog (including ones you didn't touch) and ingestion re-embeds everything. Safe, but re-embeds products you already had.
- **Incremental (keep the existing collection):** set `force_recreate: false` in `rag_pipeline.yaml`, then just re-run the staging cell and the ingest cell (no kernel restart, don't re-run the `RAGWire(...)` init cell if the collection already exists from a prior run). File-hash dedup in `ingest_documents` skips any staged file whose content hasn't changed, so only genuinely new/changed products get embedded. Switch back to `force_recreate: true` before your next full rebuild if you want a guaranteed-clean collection.

## Sanity-checking a new splitter before trusting it

Run this after writing/registering a new `split_*` function, before ingesting:

```python
blocks = split_headphones(rag.loader.load("../data/rag_headphones_catalog.pdf")["text_content"])
print(len(blocks), "products found")
print(blocks[0][1])   # inspect the first full block
print(blocks[-1][1])  # and the last

# every block should contain exactly one price
import re
for name, block in blocks:
    prices = re.findall(r"\$[\d,]+\.?\d*", block)
    if len(prices) != 1:
        print("WARN:", name, prices)
```

No `WARN` lines and a product count matching what the catalog claims (or close to it — some of these fake catalogs undercount) means the boundaries are clean.
