variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region for all resources"
  type        = string
  default     = "us-central1"
}

variable "github_repo" {
  description = "GitHub repository in owner/repo format (for Workload Identity Federation)"
  type        = string
  default     = "sema237/devsecops-flask-app"
}

variable "db_tier_prod" {
  description = "Cloud SQL machine tier for production"
  type        = string
  default     = "db-g1-small"
}

variable "db_tier_staging" {
  description = "Cloud SQL machine tier for staging"
  type        = string
  default     = "db-f1-micro"
}

variable "cloud_run_min_instances_prod" {
  description = "Minimum Cloud Run instances in production (avoid cold starts)"
  type        = number
  default     = 1
}

variable "cloud_run_max_instances_prod" {
  description = "Maximum Cloud Run instances in production"
  type        = number
  default     = 20
}
