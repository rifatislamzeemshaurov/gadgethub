variable "project_name" {
  description = "Name prefix for all resources"
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.project_name))
    error_message = "Project name must contain only lowercase letters, numbers, and hyphens."
  }
}

variable "environment" {
  description = "Environment name (dev, test, prod)"
  type        = string
  validation {
    condition     = contains(["dev", "test", "prod"], var.environment)
    error_message = "Environment must be one of: dev, test, prod."
  }
}

variable "openai_api_key" {
  description = "OpenAI API key used by the backend. Pass via TF_VAR_openai_api_key, never commit it."
  type        = string
  sensitive   = true
}

variable "openai_model" {
  description = "OpenAI chat model used for the recommendation agent"
  type        = string
  default     = "gpt-4o-mini"
}

variable "qdrant_url" {
  description = "Qdrant Cloud cluster URL holding the ingested gadget catalog. Pass via TF_VAR_qdrant_url."
  type        = string
  sensitive   = true
}

variable "qdrant_api_key" {
  description = "Qdrant Cloud API key. Pass via TF_VAR_qdrant_api_key, never commit it."
  type        = string
  sensitive   = true
}

variable "api_key" {
  description = "Shared secret the frontend sends as X-API-Key to gate the backend. Pass via TF_VAR_api_key, never commit it."
  type        = string
  sensitive   = true
}

variable "image_tag" {
  description = "Docker image tag in ECR that the ECS task definition should run. Set by the deploy script after it pushes a fresh image."
  type        = string
}

variable "container_port" {
  description = "Port the backend container listens on"
  type        = number
  default     = 8000
}

variable "container_cpu" {
  description = "Fargate task CPU units (256 = 0.25 vCPU)"
  type        = number
  default     = 256
}

variable "container_memory" {
  description = "Fargate task memory in MiB"
  type        = number
  default     = 512
}

variable "desired_count" {
  description = "Number of always-on backend tasks to run"
  type        = number
  default     = 1
}

variable "use_custom_domain" {
  description = "Attach a custom subdomain (app_subdomain.domain_name) to CloudFront"
  type        = bool
  default     = false
}

variable "domain_name" {
  description = "Apex/root domain already hosted in Route 53, e.g. rifatai.com"
  type        = string
  default     = "rifatai.com"
}

variable "app_subdomain" {
  description = "Subdomain the app is served on, e.g. \"rag\" for rag.rifatai.com"
  type        = string
  default     = "rag"
}
