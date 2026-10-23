# GadgetHub: Deployment Guide

Everything needed to set up, deploy, operate and tear down GadgetHub. For what the product does, see the [README](README.md). All commands run from the `gadgethub/` folder.

---

## 1. Overview

```
Browser ──HTTPS──> Route 53 (optional) ──> CloudFront ──┬──> S3   (Next.js static site)
                                                       └──> ALB ──> ECS Fargate: FastAPI :8000
                                                                     ├─> Qdrant Cloud (catalog, hybrid search)
                                                                     ├─> OpenAI (agent + embeddings)
                                                                     └─> S3 (conversation memory)
```

The backend runs on **ECS Fargate behind an Application Load Balancer** (not Lambda), so the first message after an idle period never waits for a cold start. Frontend and API share one CloudFront domain.

## 2. One-time prerequisites

| Tool | Check it is installed |
|---|---|
| AWS CLI v2 | `aws --version` |
| Terraform 1.0+ | `terraform -version` |
| Docker (running) | `docker info` |
| Node.js 20+ and npm | `node -v` |
| uv (local backend runs and ingestion) | `uv --version` |
| Bash (macOS / Linux / Git Bash) or Windows PowerShell 5.1+ | |

**Accounts:** an OpenAI API key ([platform.openai.com](https://platform.openai.com/api-keys)) and a Qdrant Cloud cluster ([cloud.qdrant.io](https://cloud.qdrant.io)).

**AWS permissions:** the IAM user or role must be able to create S3, ECR, ECS, IAM roles, EC2 security groups, Elastic Load Balancing, CloudFront, CloudWatch Logs, and (for a custom domain) ACM and Route 53 records. `AdministratorAccess` on a sandbox account is the simplest option.

**Region:** set `AWS_REGION` (default `ap-south-1`). The ACM certificate for CloudFront is always created in `us-east-1`, as CloudFront requires.

## 3. Configure before deploying

### 3.1 Secrets file

Copy `.env.example` to `.env` (both in `gadgethub/`) and fill it in. One file configures everything: the backend, the ingestion notebook and the deploy and destroy scripts all read it. `.env` is git-ignored.

1. `OPENAI_API_KEY` and `OPENAI_MODEL`
2. `QDRANT_URL` and `QDRANT_API_KEY`
3. `API_KEY_UI`: any long random string; the frontend sends it as `X-API-Key`
4. `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` (or leave empty to use your `aws configure` profile), `AWS_REGION`, `AWS_ACCOUNT_ID`
5. Optionally `USE_CUSTOM_DOMAIN`, `DOMAIN_NAME`, `APP_SUBDOMAIN`

For local frontend runs, also create `frontend/.env.development` with `NEXT_PUBLIC_API_URL=http://localhost:8000` and `NEXT_PUBLIC_API_KEY` set to the same value as `API_KEY_UI`.

### 3.2 The product catalog (one time)

No catalog ships in this repository, and `backend/pipeline.yaml` has `force_recreate: false` so the API never wipes the collection on start-up. Load the catalog once before the first deploy:

1. Put the four catalog PDFs (smartwatches, cameras, laptops, smart TVs) in `gadgethub/data/`. The `CATALOGS` dict in `ingestion/rag_pipeline.ipynb` (section 2) lists the file names it expects; edit it to match yours.
2. Open `ingestion/rag_pipeline.ipynb` and run the setup, staging and ingest cells top to bottom.
3. Keep `backend/metadata.yaml` identical to `ingestion/rag_metadata.yaml`; the API's schema must match what was stored.

See [`ingestion/ingest.md`](gadgethub/ingestion/ingest.md) for the PDF layout each category expects and how to add products or a new category. Skip this step if the `gadgethub-catalog-openai-qdrant` collection is already populated.

## 4. Deploy: one command

```bash
./scripts/deploy.sh dev                      # macOS / Linux / Git Bash
```
```powershell
.\scripts\deploy.ps1 -Environment dev        # Windows PowerShell
```

What the script does:

1. Checks Docker is running and that `OPENAI_API_KEY`, `QDRANT_URL`, `QDRANT_API_KEY` and `API_KEY_UI` are set (and not placeholders).
2. Selects (or creates) the Terraform workspace for the environment and creates the ECR repository.
3. Builds the backend image and pushes it to ECR with a timestamp tag.
4. Runs the full `terraform apply`, which rolls out a new ECS task definition.
5. Waits until the ECS service is stable and passing load balancer health checks.
6. Builds the Next.js frontend pointed at the app's public domain and syncs it to S3.
7. Invalidates the CloudFront cache and prints the URLs.

**Duration:** the first deploy takes several minutes (creating the CloudFront distribution is the slow part). Redeploys are faster.

**Example output:**

```
Deployment complete!
App URL       : https://dxxxxxxxxxxxx.cloudfront.net
Custom domain : https://shop.example.com
ECS cluster   : gadgethub-dev-cluster
ECS service   : gadgethub-dev-api
Image deployed: <account>.dkr.ecr.ap-south-1.amazonaws.com/gadgethub-dev-api:<timestamp>
```

**Resources created** (with `PROJECT_NAME=gadgethub`, environment `dev`):

| Resource | Name |
|---|---|
| S3 bucket (frontend) | `gadgethub-dev-frontend-<account-id>` |
| S3 bucket (conversation memory) | `gadgethub-dev-memory-<account-id>` |
| ECR repository | `gadgethub-dev-api` |
| ECS cluster / service | `gadgethub-dev-cluster` / `gadgethub-dev-api` |
| ECS task definition | `gadgethub-dev-api` |
| IAM roles | `gadgethub-dev-ecs-execution-role`, `gadgethub-dev-ecs-task-role` |
| CloudWatch log group | `/ecs/gadgethub-dev-api` (14-day retention) |
| Application Load Balancer | `gadgethub-dev-alb`, target group `gadgethub-dev-api-tg` |
| Security groups | `gadgethub-dev-alb-sg`, `gadgethub-dev-ecs-sg` |
| CloudFront distribution | serves the site and proxies the API paths |
| CloudFront function | `gadgethub-dev-host-guard` (custom domain only) |
| ACM certificate + Route 53 A/AAAA records | custom domain only |

## 5. Destroy: one command

```bash
./scripts/destroy.sh dev
```
```powershell
.\scripts\destroy.ps1 -Environment dev
```

The script empties both S3 buckets, then destroys every AWS resource for that environment. The Qdrant catalog is an external service and is never touched, and neither is your Route 53 hosted zone.

To remove the leftover workspace afterwards:

```bash
cd terraform && terraform workspace select default && terraform workspace delete dev
```

## 6. Custom domain: one setting

Set in `.env`:

```
USE_CUSTOM_DOMAIN=true
DOMAIN_NAME=example.com
APP_SUBDOMAIN=shop
```

The app is then served at `https://<APP_SUBDOMAIN>.<DOMAIN_NAME>`. `DOMAIN_NAME` must already be a public Route 53 hosted zone in the account.

**What happens automatically**

| Step | Done by |
|---|---|
| Request the ACM certificate in `us-east-1` | Terraform |
| Create the DNS validation records and wait for the certificate | Terraform |
| Attach the domain and certificate to CloudFront | Terraform |
| Create the Route 53 alias records (A + AAAA) | Terraform |
| 301-redirect any other hostname, including the CloudFront URL | CloudFront function |
| Restrict the API's CORS origin to the domain | Terraform |

**Redeploys** read the same `.env`, so the domain stays attached. **To detach it**, set `USE_CUSTOM_DOMAIN=false` and redeploy.

> A hostname can only be attached to one CloudFront distribution at a time. Before deploying a second environment alongside the first, change `APP_SUBDOMAIN` or set `USE_CUSTOM_DOMAIN=false`.

**Domain bought elsewhere (GoDaddy, Namecheap, ...):** create a public hosted zone for it in Route 53 once, then replace the nameservers at your registrar with the four `NS` values Route 53 shows.

> ⚠️ Moving nameservers moves **all** DNS for the domain. Copy existing records (especially `MX` and `TXT` for email) into the Route 53 zone first, or email will stop working.

**Cost:** the ACM certificate is free; a Route 53 hosted zone costs $0.50 per month.

## 7. Configuration reference

| Variable | Default | Where it is set |
|---|---|---|
| `AWS_REGION` | `ap-south-1` | `.env` |
| `AWS_ACCOUNT_ID` | none | `.env` (safety check) |
| `PROJECT_NAME` | `gadgethub` | `.env` |
| `USE_CUSTOM_DOMAIN` / `DOMAIN_NAME` / `APP_SUBDOMAIN` | `false` / none / none | `.env` |
| `CONTAINER_CPU` / `CONTAINER_MEMORY` | `256` / `512` | `.env` |
| `DESIRED_COUNT` | `1` | `.env` |
| `OPENAI_API_KEY` / `OPENAI_MODEL` | required / `gpt-4o-mini` | `.env` |
| `QDRANT_URL` / `QDRANT_API_KEY` | required | `.env` |
| `API_KEY_UI` | required | `.env`; the deploy script writes it into the frontend build |
| `CORS_ORIGINS` | `http://localhost:3000` | `.env` locally; set to the app's domain by Terraform in AWS |
| `USE_S3` / `S3_BUCKET` / `MEMORY_DIR` | `false` / none / `../memory` | `.env` locally; set by Terraform in AWS |
| `NEXT_PUBLIC_API_URL` / `NEXT_PUBLIC_API_KEY` | none | `frontend/.env.development` locally; written by the deploy script for production |
| Embedding model, `top_k`, hybrid search | `text-embedding-3-small`, `5`, `hybrid` | `backend/pipeline.yaml` |

## 8. Troubleshooting

**`Docker doesn't seem to be running.`**
Start Docker Desktop, wait until it reports that it is running, then re-run the script.

**`OPENAI_API_KEY in .env looks like a placeholder, not a real key.`**
Replace `your_openai_api_key_here` with a real key.

**`QDRANT_URL / QDRANT_API_KEY not set in .env`**
The catalog can't be reached without them; add both from your Qdrant Cloud console.

**`API_KEY_UI not set in .env`**
Set any long random string; the frontend needs it to reach the backend.

**Chat replies "I couldn't find a matching product in our catalog right now." for everything.**
The Qdrant collection is empty or points at a different cluster. Run the ingestion notebook (section 3.2) against the cluster in `QDRANT_URL`.

**`401 Invalid or missing API key` in the browser.**
The frontend was built with a different key from the one the backend has. Locally, match `NEXT_PUBLIC_API_KEY` to `API_KEY_UI`; in AWS, redeploy.

**`500 Server API key is not configured`**
The backend has no `API_KEY_UI`. Protected endpoints fail closed by design; set it and restart or redeploy.

**The first chat after a deploy is slow.**
The API warms up its Qdrant connection in the background at boot (about 20-30 seconds). Requests made during that window wait for it once.

**The custom domain doesn't resolve right after the first deploy.**
Your local DNS may have cached a "not found" answer. Flush it (`ipconfig /flushdns` on Windows) or wait a few minutes; `nslookup <domain> 8.8.8.8` shows whether public DNS already has the record.

**`terraform apply` fails with a CNAME already associated with another CloudFront distribution.**
The hostname is attached to another environment's distribution. Use a different `APP_SUBDOMAIN` or destroy the other environment first.

## 9. Cost notes

Approximate on-demand prices for one environment in `ap-south-1` running all month. Check the AWS Pricing Calculator for exact figures.

| Resource | Approx. monthly cost |
|---|---|
| Application Load Balancer | ~$18 |
| ECS Fargate (0.25 vCPU, 0.5 GB, 1 task) | ~$9 |
| Public IPv4 addresses (ALB + task) | ~$11 |
| CloudFront, S3, CloudWatch Logs, ECR | under $2 at demo traffic |
| Route 53 hosted zone (if used) | $0.50 |
| **Total per environment** | **about $40 per month**, plus OpenAI usage and your Qdrant plan |

**Main saving:** destroy `dev` and `test` when they're not in use; the ALB and Fargate task cost money whether or not anyone is chatting. The catalog lives in Qdrant, so a redeploy is ready to answer straight away.
