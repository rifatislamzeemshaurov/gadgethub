#!/bin/bash
set -e

ENVIRONMENT=${1:-dev}          # dev | test | prod
PROJECT_NAME=${2:-}            # defaults to PROJECT_NAME in .env

# project root
cd "$(dirname "$0")/.."

# --- Load .env: AWS credentials/region, custom domain, compute sizing -------
source scripts/load-env.sh
PROJECT_NAME=${PROJECT_NAME:-$(read_env_value PROJECT_NAME)}
PROJECT_NAME=${PROJECT_NAME:-gadgethub}

echo "Deploying ${PROJECT_NAME} to ${ENVIRONMENT}..."

# --- Pre-flight: Docker must be running to build the backend image --------
echo "Checking Docker is running..."
if ! docker info >/dev/null 2>&1; then
  echo "Docker doesn't seem to be running."
  echo "Start Docker (Docker Desktop / dockerd), wait for it to be ready, then re-run this script."
  exit 1
fi

# --- Load OPENAI_API_KEY from .env ----------------------------------------
OPENAI_KEY=$(read_env_value OPENAI_API_KEY)
if [ -z "$OPENAI_KEY" ] || [ "$OPENAI_KEY" = "your_openai_api_key_here" ]; then
  echo "OPENAI_API_KEY in .env looks unset or a placeholder."
  exit 1
fi
export TF_VAR_openai_api_key="$OPENAI_KEY"

# --- Load QDRANT_URL / QDRANT_API_KEY / API_KEY from .env ------------------
QDRANT_URL=$(read_env_value QDRANT_URL)
QDRANT_API_KEY=$(read_env_value QDRANT_API_KEY)
API_KEY=$(read_env_value API_KEY_UI)
if [ -z "$QDRANT_URL" ] || [ -z "$QDRANT_API_KEY" ]; then
  echo "QDRANT_URL / QDRANT_API_KEY not set in .env - the catalog can't be reached without them."
  exit 1
fi
if [ -z "$API_KEY" ]; then
  echo "API_KEY_UI not set in .env - the frontend needs this shared secret to reach the backend."
  exit 1
fi
export TF_VAR_qdrant_url="$QDRANT_URL"
export TF_VAR_qdrant_api_key="$QDRANT_API_KEY"
export TF_VAR_api_key="$API_KEY"

# --- AWS region (used for ECR login) --------------------------------------
REGION=${AWS_REGION:-$(aws configure get region)}
REGION=${REGION:-ap-south-1}

# 1. Terraform workspace select + bootstrap the ECR repo only.
#    (The full apply further down needs an image_tag that already exists in
#    ECR, so the repo itself has to exist first - classic bootstrap order.)
cd terraform
terraform init -input=false

if ! terraform workspace list | grep -q "$ENVIRONMENT"; then
  terraform workspace new "$ENVIRONMENT"
else
  terraform workspace select "$ENVIRONMENT"
fi

echo "Ensuring ECR repository exists..."
terraform apply -target=aws_ecr_repository.backend \
  -var="project_name=$PROJECT_NAME" -var="environment=$ENVIRONMENT" \
  -var="image_tag=bootstrap" -auto-approve

ECR_URL=$(terraform output -raw ecr_repository_url)

# 2. Build + push the backend image
cd ..
IMAGE_TAG=$(date +%Y%m%d%H%M%S)
echo "Building backend image (${ECR_URL}:${IMAGE_TAG})..."

aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "${ECR_URL%%/*}"

docker build -t "${ECR_URL}:${IMAGE_TAG}" -f backend/Dockerfile backend
docker push "${ECR_URL}:${IMAGE_TAG}"

# 3. Full terraform apply - creates/updates everything, including a new ECS
#    task definition revision pointing at the image we just pushed, which
#    rolls the service forward automatically.
cd terraform
echo "Applying Terraform..."
terraform apply -var="project_name=$PROJECT_NAME" -var="environment=$ENVIRONMENT" -var="image_tag=$IMAGE_TAG" -auto-approve

CF_URL=$(terraform output -raw cloudfront_url)
FRONTEND_BUCKET=$(terraform output -raw s3_frontend_bucket)
CLUSTER_NAME=$(terraform output -raw ecs_cluster_name)
SERVICE_NAME=$(terraform output -raw ecs_service_name)
CUSTOM_URL=$(terraform output -raw custom_domain_url 2>/dev/null || true)

# 4. Wait for the new task(s) to pass ALB health checks and go live
echo "Waiting for the ECS service to become stable (can take a few minutes on first deploy)..."
aws ecs wait services-stable --cluster "$CLUSTER_NAME" --services "$SERVICE_NAME" --region "$REGION"

# 5. Build + deploy frontend, pointed at the app's single public domain
#    (frontend and API share one domain, so no CORS setup is needed). When a
#    custom domain is attached, that's the ONLY domain the app answers on
#    (see aws_cloudfront_function.host_guard in terraform/main.tf, which
#    403s anything else) - so the frontend must call the custom domain, not
#    the raw *.cloudfront.net one, or its own API calls would be rejected.
cd ../frontend

API_URL=${CUSTOM_URL:-$CF_URL}
echo "Setting API URL for production build ($API_URL)..."
{
  echo "NEXT_PUBLIC_API_URL=$API_URL"
  echo "NEXT_PUBLIC_API_KEY=$API_KEY"
} > .env.production

npm install
npm run build

if [ ! -f "out/index.html" ]; then
  echo "frontend/out/index.html was not created - check next.config.ts has output: 'export'."
  exit 1
fi

aws s3 sync ./out "s3://$FRONTEND_BUCKET/" --delete
cd ..

# 6. Invalidate CloudFront so the new frontend build is served immediately
echo "Invalidating CloudFront cache..."
CF_DOMAIN=${CF_URL#https://}
DIST_ID=$(aws cloudfront list-distributions --query "DistributionList.Items[?DomainName=='$CF_DOMAIN'].Id | [0]" --output text)
if [ -n "$DIST_ID" ] && [ "$DIST_ID" != "None" ]; then
  aws cloudfront create-invalidation --distribution-id "$DIST_ID" --paths "/*" >/dev/null
fi

# 7. Final messages
echo ""
echo "Deployment complete!"
echo "App URL        : $CF_URL"
if [ -n "$CUSTOM_URL" ]; then
  echo "Custom domain  : $CUSTOM_URL"
fi
echo "ECS cluster    : $CLUSTER_NAME"
echo "ECS service    : $SERVICE_NAME"
echo "Image deployed : ${ECR_URL}:${IMAGE_TAG}"
