#!/bin/bash
set -e

if [ $# -eq 0 ]; then
    echo "Error: Environment parameter is required"
    echo "Usage: $0 <environment>"
    echo "Example: $0 dev"
    echo "Available environments: dev, test, prod"
    exit 1
fi

ENVIRONMENT=$1
PROJECT_NAME=${2:-}            # defaults to PROJECT_NAME in .env

# project root, then into terraform/
cd "$(dirname "$0")/.."

# --- Load .env: AWS credentials/region, custom domain, compute sizing -------
source scripts/load-env.sh
PROJECT_NAME=${PROJECT_NAME:-$(read_env_value PROJECT_NAME)}
PROJECT_NAME=${PROJECT_NAME:-gadgethub}

echo "Preparing to destroy ${PROJECT_NAME}-${ENVIRONMENT} infrastructure..."

# --- Load OPENAI_API_KEY from .env ----------------------------------------
if [ -f ".env" ]; then
  OPENAI_KEY=$(read_env_value OPENAI_API_KEY)
  if [ -n "$OPENAI_KEY" ]; then
    export TF_VAR_openai_api_key="$OPENAI_KEY"
  fi
  # terraform destroy still re-evaluates the whole config graph, so every
  # required variable (no default) has to resolve — placeholders are fine
  # here since destroy doesn't actually use these values.
  QDRANT_URL=$(read_env_value QDRANT_URL)
  QDRANT_API_KEY=$(read_env_value QDRANT_API_KEY)
  API_KEY=$(read_env_value API_KEY_UI)
fi
export TF_VAR_qdrant_url="${QDRANT_URL:-https://placeholder}"
export TF_VAR_qdrant_api_key="${QDRANT_API_KEY:-placeholder}"
export TF_VAR_api_key="${API_KEY:-placeholder}"

cd terraform

if ! terraform workspace list | grep -q "$ENVIRONMENT"; then
    echo "Error: Workspace '$ENVIRONMENT' does not exist"
    echo "Available workspaces:"
    terraform workspace list
    exit 1
fi

terraform workspace select "$ENVIRONMENT"

echo "Emptying S3 buckets..."

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

FRONTEND_BUCKET="${PROJECT_NAME}-${ENVIRONMENT}-frontend-${AWS_ACCOUNT_ID}"
MEMORY_BUCKET="${PROJECT_NAME}-${ENVIRONMENT}-memory-${AWS_ACCOUNT_ID}"

if aws s3 ls "s3://$FRONTEND_BUCKET" 2>/dev/null; then
    echo "  Emptying $FRONTEND_BUCKET..."
    aws s3 rm "s3://$FRONTEND_BUCKET" --recursive
else
    echo "  Frontend bucket not found or already empty"
fi

if aws s3 ls "s3://$MEMORY_BUCKET" 2>/dev/null; then
    echo "  Emptying $MEMORY_BUCKET..."
    aws s3 rm "s3://$MEMORY_BUCKET" --recursive
else
    echo "  Memory bucket not found or already empty"
fi

# `image_tag` isn't used by anything `destroy` needs to actually remove
# (the ECR repo has force_delete = true, so leftover images don't block it),
# but the variable is required by the config, so pass a placeholder.
echo "Running terraform destroy..."

terraform destroy -var="project_name=$PROJECT_NAME" -var="environment=$ENVIRONMENT" -var="image_tag=destroy" -auto-approve

echo "Infrastructure for ${ENVIRONMENT} has been destroyed!"
echo ""
echo "To remove the workspace completely, run:"
echo "   terraform workspace select default"
echo "   terraform workspace delete $ENVIRONMENT"
