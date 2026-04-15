# ── Cloud Run URLs ──
output "cloud_run_prod_url" {
  description = "Production Cloud Run service URL"
  value       = google_cloud_run_v2_service.prod.uri
}

output "cloud_run_staging_url" {
  description = "Staging Cloud Run service URL"
  value       = google_cloud_run_v2_service.staging.uri
}

# ── Artifact Registry ──
output "artifact_registry_url" {
  description = "Full Artifact Registry repository URL for docker push/pull"
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.app.repository_id}"
}

# ── Workload Identity Federation ──
output "wif_provider" {
  description = "WIF provider resource name — use as GCP_WORKLOAD_IDENTITY_PROVIDER secret in GitHub"
  value       = google_iam_workload_identity_pool_provider.github.name
}

output "github_build_sa" {
  description = "Build SA email — use as GCP_SERVICE_ACCOUNT secret in GitHub"
  value       = google_service_account.github_build.email
}

output "github_staging_sa" {
  description = "Staging deploy SA email — use as GCP_SA_STAGING secret in GitHub"
  value       = google_service_account.github_staging.email
}

output "github_prod_sa" {
  description = "Production deploy SA email — use as GCP_SA_PROD secret in GitHub"
  value       = google_service_account.github_prod.email
}

# ── Database ──
output "db_prod_connection_name" {
  description = "Cloud SQL production instance connection name for Cloud SQL Auth Proxy"
  value       = google_sql_database_instance.prod.connection_name
}

output "db_staging_connection_name" {
  description = "Cloud SQL staging instance connection name"
  value       = google_sql_database_instance.staging.connection_name
}

# ── Networking ──
output "vpc_id" {
  description = "VPC network ID"
  value       = google_compute_network.main.id
}

output "vpc_connector_prod" {
  description = "Production VPC connector ID"
  value       = google_vpc_access_connector.prod.id
}

output "vpc_connector_staging" {
  description = "Staging VPC connector ID"
  value       = google_vpc_access_connector.staging.id
}
