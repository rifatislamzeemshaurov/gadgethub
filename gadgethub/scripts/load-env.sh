#!/bin/bash
# Sourced by deploy.sh / destroy.sh from the project root (gadgethub/).
# Loads .env and exposes its values to the AWS CLI, Docker and Terraform.

ENV_FILE=".env"
if [ ! -f "$ENV_FILE" ]; then
  echo ".env not found - copy .env.example to .env and fill in the values."
  exit 1
fi

read_env_value() {
  grep -m1 "^$1=" "$ENV_FILE" | cut -d '=' -f2- | tr -d '\r'
}

# --- AWS credentials + region ----------------------------------------------
# Exported as the standard AWS_* variables, which the AWS CLI and Terraform's
# AWS provider both read. Left unset when empty so an "aws configure" profile
# still works as a fallback.
for name in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY; do
  value=$(read_env_value "$name")
  if [ -n "$value" ]; then
    export "$name=$value"
  fi
done
ENV_AWS_REGION=$(read_env_value AWS_REGION)
if [ -n "$ENV_AWS_REGION" ]; then
  export AWS_REGION="$ENV_AWS_REGION"
  export AWS_DEFAULT_REGION="$ENV_AWS_REGION"
fi

# --- Terraform variables -----------------------------------------------------
# Terraform auto-reads any TF_VAR_<name> environment variable as the value for
# variable <name>. Anything left empty in .env falls back to the default in
# terraform/variables.tf.
for pair in \
  USE_CUSTOM_DOMAIN:use_custom_domain \
  DOMAIN_NAME:domain_name \
  APP_SUBDOMAIN:app_subdomain \
  OPENAI_MODEL:openai_model \
  CONTAINER_CPU:container_cpu \
  CONTAINER_MEMORY:container_memory \
  DESIRED_COUNT:desired_count; do
  value=$(read_env_value "${pair%%:*}")
  if [ -n "$value" ]; then
    export "TF_VAR_${pair##*:}=$value"
  fi
done

# --- Pre-flight: credentials must work and target the expected account -------
if ! ACTUAL_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text); then
  echo ""
  echo "AWS credentials were rejected - check AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY in .env."
  exit 1
fi
ACTUAL_ACCOUNT_ID=$(echo "$ACTUAL_ACCOUNT_ID" | tr -d '\r')
EXPECTED_ACCOUNT_ID=$(read_env_value AWS_ACCOUNT_ID)
if [ -n "$EXPECTED_ACCOUNT_ID" ] && [ "$ACTUAL_ACCOUNT_ID" != "$EXPECTED_ACCOUNT_ID" ]; then
  echo ""
  echo "AWS account mismatch: credentials belong to $ACTUAL_ACCOUNT_ID but .env sets AWS_ACCOUNT_ID=$EXPECTED_ACCOUNT_ID."
  exit 1
fi
