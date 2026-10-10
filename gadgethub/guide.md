# GadgetHub — Setup & Configuration Guide

GadgetHub is a guardrailed AI gadget-shop advisor: smartwatch, smart TV,
laptop, and camera recommendations, retrieved live from a Qdrant product
catalog (never answered from the model's memory), plus PDF upload — a
visitor can hand over a product spec sheet and get parsed details and
catalog alternatives. **Uploaded PDFs are parsed in memory and discarded;
they are never written to the vector store.** The backend runs identically
locally and in the cloud (AWS ECS Fargate — see `../README.md`).

```
gadgethub/
├── .env                     ← every setting and secret: AWS, project, domain, OpenAI, Qdrant, API key
├── .env.example             ← template for .env
├── .gitignore
├── backend/
│   ├── pipeline.yaml           ← RAGWire config (embeddings/LLM/Qdrant/retriever) — force_recreate is FALSE once the catalog is ingested
│   ├── metadata.yaml            ← product metadata schema (must match what was ingested)
│   ├── server.py                  ← FastAPI app (local + container entrypoint)
│   ├── rag_engine.py                ← RAGWire singleton + tool-calling agent + SSE status streaming
│   ├── pdf_intake.py                 ← uploaded-PDF parsing → extraction → catalog alternatives (never ingests)
│   ├── memory.py                      ← per-session chat history (local JSON / S3)
│   ├── auth.py                         ← X-API-Key gate
│   ├── Dockerfile                       ← builds the image the deploy script pushes to ECR
│   └── requirements.txt
├── frontend/                  ← Next.js 16 App Router chat UI
│   ├── app/page.tsx
│   ├── components/gadgethub-advisor.tsx ← chat widget: live "thinking" status, product cards, PDF upload, new-chat button
│   └── next.config.ts
├── ingestion/                 ← source of truth for the catalog
│   ├── rag_pipeline.ipynb       ← splits the 4 catalog PDFs into per-product chunks and ingests them
│   ├── rag_pipeline.yaml
│   ├── rag_metadata.yaml
│   └── ingest.md                ← how to add/replace catalog PDFs
├── terraform/                 ← ECS Fargate + ALB + CloudFront + S3, per environment
├── scripts/                   ← deploy / destroy (.ps1 and .sh) + the load-env helper they share
└── memory/                    ← local conversation JSON files (created at runtime)
```

---

## 1. Configuration — `.env`

One file configures everything: `gadgethub/.env`. The backend, the ingestion
notebook and the deploy/destroy scripts all read it. Copy `.env.example` to
`.env` to start from scratch.

```bash
# AWS account (used by the deploy/destroy scripts)
AWS_ACCESS_KEY_ID=...
AWS_SECRET_ACCESS_KEY=...
AWS_REGION=ap-south-1
AWS_ACCOUNT_ID=123456789012

# Project + custom domain
PROJECT_NAME=gadgethub
USE_CUSTOM_DOMAIN=true
DOMAIN_NAME=example.com
APP_SUBDOMAIN=app

# Backend compute (ECS Fargate)
CONTAINER_CPU=256
CONTAINER_MEMORY=512
DESIRED_COUNT=1

# OpenAI + Qdrant
OPENAI_API_KEY=sk-...
OPENAI_MODEL=gpt-4o-mini
QDRANT_URL=https://xxxx.cloud.qdrant.io
QDRANT_API_KEY=...

# Shared secret the frontend sends as X-API-Key on every request
API_KEY_UI=...
CORS_ORIGINS=http://localhost:3000

# Conversation memory (local runs)
USE_S3=false
S3_BUCKET=
MEMORY_DIR=../memory
```

If you're starting fresh:

1. Get an OpenAI key from https://platform.openai.com/api-keys.
2. Get a Qdrant Cloud cluster URL + API key from https://cloud.qdrant.io and
   run `ingestion/rag_pipeline.ipynb` once to populate the `camera` /
   `laptop` / `smart_tv` / `smartwatch` catalog (see §2).
3. Pick any random string for `API_KEY_UI` and put the same value in
   `frontend/.env.development` as `NEXT_PUBLIC_API_KEY`.
4. Create an AWS access key for the account you deploy to, or leave
   `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` empty to use your
   `aws configure` profile.
5. Never commit this file — it's gitignored.

---
## 2. The product catalog

`backend/pipeline.yaml` has `force_recreate: false` specifically so the API
never wipes the collection on startup — **you must run
`ingestion/rag_pipeline.ipynb` once against your own catalog PDFs before
the API can answer chat requests**, since no catalog ships in this repo.

1. Drop your 4 catalog PDFs into `gadgethub/data/`: a smartwatch catalog, a
   camera catalog, a laptop catalog, and a smart TV catalog (see the
   `CATALOGS` dict in `ingestion/rag_pipeline.ipynb` section 2 for the exact
   filenames it expects, or edit that dict to match your own).
2. Open `ingestion/rag_pipeline.ipynb` and run the setup, staging, and
   ingest cells top to bottom.
3. `backend/metadata.yaml` must stay identical to
   `ingestion/rag_metadata.yaml` — the API's metadata schema has to match
   whatever was actually extracted and stored.
4. See `ingestion/ingest.md` for adding more products later or a brand new
   category — file-hash dedup makes re-running the notebook safe/cheap
   after the first ingest.

---

## 3. Running it locally

Two terminals, both from the `gadgethub/` directory:

**Backend:**
```bash
cd backend
uv sync
uv run uvicorn server:app --reload
```
→ http://127.0.0.1:8000 (check `/health`)

**Frontend:**
```bash
cd frontend
npm install
npm run dev
```
→ http://localhost:3000

`frontend/.env.development` already points at `http://localhost:8000` with
the matching `NEXT_PUBLIC_API_KEY`. Conversation history is written to
`gadgethub/memory/<session_id>.json` as you chat (when `USE_S3=false`).

---

## 4. Deploying to AWS

See **[`../README.md`](../README.md)** for prerequisites and the full
walkthrough. Short version:

```powershell
.\scripts\deploy.ps1 -Environment dev
.\scripts\destroy.ps1 -Environment dev
```

Backend runs on **ECS Fargate behind an Application Load Balancer** (not
Lambda) so the first chat message after any idle period never eats a cold
start. Frontend and API share one CloudFront domain, so there's no CORS
setup to get right in the cloud. The AWS account, region, resource name
prefix and custom domain all come from `.env` (see §1).

---

## 5. Quick-reference: every secret/config value and where it lives

| Value | Local dev | AWS deployment |
|---|---|---|
| OpenAI API key | `.env` → `OPENAI_API_KEY` | injected via `TF_VAR_openai_api_key`, read by the deploy script from `.env` |
| Qdrant URL / key | `.env` → `QDRANT_URL` / `QDRANT_API_KEY` | injected via `TF_VAR_qdrant_url` / `TF_VAR_qdrant_api_key` |
| Shared frontend↔backend secret | `.env` → `API_KEY_UI`, `frontend/.env.development` → `NEXT_PUBLIC_API_KEY` | injected via `TF_VAR_api_key`, written into `frontend/.env.production` by the deploy script |
| CORS allowed origin | `.env` → `CORS_ORIGINS` | set automatically to the CloudFront/custom domain by Terraform |
| Memory storage | local files in `gadgethub/memory/` (`USE_S3=false`) | S3 bucket via `USE_S3=true` + `S3_BUCKET=...` (set automatically by Terraform) |
| API base URL used by frontend | `frontend/.env.development` → `NEXT_PUBLIC_API_URL` | `frontend/.env.production` → `NEXT_PUBLIC_API_URL`, written automatically by the deploy script |
| AWS credentials, region, account | not needed | `.env` → `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_REGION` / `AWS_ACCOUNT_ID` |
| Resource name prefix | not needed | `.env` → `PROJECT_NAME` |
| Custom domain | not needed | `.env` → `USE_CUSTOM_DOMAIN` / `DOMAIN_NAME` / `APP_SUBDOMAIN`, injected via `TF_VAR_*` |
| Fargate task size / count | not needed | `.env` → `CONTAINER_CPU` / `CONTAINER_MEMORY` / `DESIRED_COUNT`, injected via `TF_VAR_*` |

---

## 6. What the API guarantees

- Every product fact in a chat reply is retrieved from Qdrant in the same
  turn via the `search_products` tool — the model never answers a product
  question from memory, and the UI's product cards are built straight from
  that retrieved metadata (not parsed out of the model's prose), so they
  can't disagree with the catalog.
- Uploaded PDFs are parsed to a temp file, read, and the temp file is
  deleted immediately after — `pdf_intake.py` never calls into ingestion,
  so a visitor's file is never embedded or stored.
- `/chat`, `/upload`, and `/conversation/{id}` all require the `X-API-Key`
  header to match `API_KEY_UI`; `/health` and `/` stay open for load balancer
  health checks.
