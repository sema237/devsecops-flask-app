# Workload Identity Pool
resource "google_iam_workload_identity_pool" "github" {
  workload_identity_pool_id = "github-pool"
  display_name              = "GitHub Actions Pool"
  description               = "Pool for GitHub Actions OIDC"
}


# Workload Identity Provider
resource "google_iam_workload_identity_pool_provider" "github" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-provider"
  display_name                       = "GitHub Provider"


  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.actor"      = "assertion.actor"
    "attribute.repository" = "assertion.repository"
  }


  # SECURITY: Restrict to your GitHub org
  attribute_condition = "assertion.repository_owner == 'yourorg'"


  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}


# Service Account for GitHub Actions deployments
resource "google_service_account" "github_actions" {
  account_id   = "github-actions-deploy"
  display_name = "GitHub Actions Deploy SA"
}


# Allow GitHub to impersonate the SA
resource "google_service_account_iam_member" "wif_binding" {
  service_account_id = google_service_account.github_actions.name
  role               = "roles/iam.workloadIdentityUser"
  # SECURITY: Restrict to specific repo
  member = join("", [
    "principalSet://iam.googleapis.com/",
    google_iam_workload_identity_pool.github.name,
    "/attribute.repository/yourorg/devsecops-flask-app"
  ])
}


# Grant deploy permissions
resource "google_project_iam_member" "deployer_run" {
  project = var.project_id
  role    = "roles/run.admin"
  member  = "serviceAccount:${google_service_account.github_actions.email}"
}


resource "google_project_iam_member" "deployer_gar" {
  project = var.project_id
  role    = "roles/artifactregistry.writer"
  member  = "serviceAccount:${google_service_account.github_actions.email}"
}


# Output the provider name for GitHub secrets
output "workload_identity_provider" {
  value = google_iam_workload_identity_pool_provider.github.name
}
