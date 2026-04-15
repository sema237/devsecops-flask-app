terraform {
  required_version = ">= 1.6"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
  backend "gcs" {
    bucket = "your-project-tf-state"
    prefix = "devsecops"
  }
}


provider "google" {
  project = var.project_id
  region  = var.region
}


# ── Enable Required APIs ──
resource "google_project_service" "apis" {
  for_each = toset([
    "run.googleapis.com",
    "artifactregistry.googleapis.com",
    "secretmanager.googleapis.com",
    "sqladmin.googleapis.com",
    "vpcaccess.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",         # Required for Workload Identity Federation
    "cloudresourcemanager.googleapis.com",   # Required for IAM policy management
    "servicenetworking.googleapis.com",      # Required for VPC peering to Cloud SQL
    "binaryauthorization.googleapis.com",    # Required for signed-image enforcement
  ])
  service            = each.value
  disable_on_destroy = false
}


# ── Artifact Registry ──
resource "google_artifact_registry_repository" "app" {
  location      = var.region
  repository_id = "devsecops-repo"
  format        = "DOCKER"
  description   = "Flask app container images"

  docker_config {
    immutable_tags = true  # SECURITY: Prevent tag overwriting
  }

  labels = {
    env     = "shared"
    managed = "terraform"
  }

  depends_on = [google_project_service.apis]
}


# ── VPC for Private Networking ──
resource "google_compute_network" "main" {
  name                    = "devsecops-vpc"
  auto_create_subnetworks = false
  depends_on              = [google_project_service.apis]
}

resource "google_compute_subnetwork" "main" {
  name                     = "devsecops-subnet"
  ip_cidr_range            = "10.0.0.0/24"
  region                   = var.region
  network                  = google_compute_network.main.id
  private_ip_google_access = true  # Allow VMs to reach Google APIs without public IP
}

# Reserved IP range for VPC peering to Cloud SQL
resource "google_compute_global_address" "private_ip_range" {
  name          = "devsecops-private-ip"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = google_compute_network.main.id
}

resource "google_service_networking_connection" "private_vpc_connection" {
  network                 = google_compute_network.main.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_ip_range.name]
  depends_on              = [google_project_service.apis]
}

# VPC Connector — Production (Cloud Run → Cloud SQL)
resource "google_vpc_access_connector" "prod" {
  name          = "prod-vpc-connector"
  region        = var.region
  ip_cidr_range = "10.8.0.0/28"
  network       = google_compute_network.main.name
  depends_on    = [google_project_service.apis]
}

# VPC Connector — Staging
resource "google_vpc_access_connector" "staging" {
  name          = "staging-vpc-connector"
  region        = var.region
  ip_cidr_range = "10.8.1.0/28"
  network       = google_compute_network.main.name
  depends_on    = [google_project_service.apis]
}


# ── Cloud SQL (PostgreSQL) — Production ──
resource "google_sql_database_instance" "prod" {
  name             = "devsecops-db-prod"
  database_version = "POSTGRES_16"
  region           = var.region

  settings {
    tier = var.db_tier_prod

    ip_configuration {
      ipv4_enabled                                  = false  # SECURITY: No public IP
      private_network                               = google_compute_network.main.id
      enable_private_path_for_google_cloud_services = true
      ssl_mode                                      = "ENCRYPTED_ONLY"  # SECURITY: Require TLS
    }

    backup_configuration {
      enabled                        = true
      point_in_time_recovery_enabled = true
      backup_retention_settings {
        retained_backups = 14  # 14-day retention for production
      }
    }

    database_flags {
      name  = "log_connections"
      value = "on"
    }
    database_flags {
      name  = "log_disconnections"
      value = "on"
    }
    database_flags {
      name  = "log_lock_waits"
      value = "on"
    }
    database_flags {
      name  = "log_min_duration_statement"
      value = "1000"  # Log queries taking > 1 second
    }
    database_flags {
      name  = "password_encryption"
      value = "scram-sha-256"
    }
  }

  deletion_protection = true
  depends_on          = [google_service_networking_connection.private_vpc_connection]
}

resource "google_sql_database" "prod" {
  name     = "flaskapp"
  instance = google_sql_database_instance.prod.name
}

resource "google_sql_user" "app_prod" {
  name     = "flaskapp"
  instance = google_sql_database_instance.prod.name
  password = null  # Use Cloud SQL IAM auth — no password needed
  type     = "CLOUD_IAM_SERVICE_ACCOUNT"
}


# ── Cloud SQL (PostgreSQL) — Staging ──
resource "google_sql_database_instance" "staging" {
  name             = "devsecops-db-staging"
  database_version = "POSTGRES_16"
  region           = var.region

  settings {
    tier = var.db_tier_staging

    ip_configuration {
      ipv4_enabled    = false
      private_network = google_compute_network.main.id
      ssl_mode        = "ENCRYPTED_ONLY"
    }

    backup_configuration {
      enabled = true
      backup_retention_settings {
        retained_backups = 7
      }
    }

    database_flags {
      name  = "log_connections"
      value = "on"
    }
  }

  deletion_protection = false  # Staging can be recreated
  depends_on          = [google_service_networking_connection.private_vpc_connection]
}

resource "google_sql_database" "staging" {
  name     = "flaskapp"
  instance = google_sql_database_instance.staging.name
}


# ── Secret Manager — Production ──
resource "google_secret_manager_secret" "db_url_prod" {
  secret_id = "db-url-prod"
  replication { auto {} }
  labels = { env = "prod", managed = "terraform" }
  depends_on = [google_project_service.apis]
}

resource "google_secret_manager_secret" "secret_key_prod" {
  secret_id = "secret-key-prod"
  replication { auto {} }
  labels = { env = "prod", managed = "terraform" }
  depends_on = [google_project_service.apis]
}

# ── Secret Manager — Staging ──
resource "google_secret_manager_secret" "db_url_staging" {
  secret_id = "db-url-staging"
  replication { auto {} }
  labels = { env = "staging", managed = "terraform" }
  depends_on = [google_project_service.apis]
}

resource "google_secret_manager_secret" "secret_key_staging" {
  secret_id = "secret-key-staging"
  replication { auto {} }
  labels = { env = "staging", managed = "terraform" }
  depends_on = [google_project_service.apis]
}


# ── Workload Identity Federation (keyless GitHub Actions auth) ──
resource "google_iam_workload_identity_pool" "github" {
  workload_identity_pool_id = "github-pool"
  display_name              = "GitHub Actions Pool"
  description               = "OIDC identity pool for GitHub Actions — no static keys"
  depends_on                = [google_project_service.apis]
}

resource "google_iam_workload_identity_pool_provider" "github" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-provider"
  display_name                       = "GitHub Actions OIDC Provider"

  # SECURITY: Scope to this repo only — prevents other repos from impersonating
  attribute_condition = "assertion.repository == '${var.github_repo}'"

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.actor"      = "assertion.actor"
    "attribute.repository" = "assertion.repository"
    "attribute.ref"        = "assertion.ref"
  }

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}


# ── GitHub Actions Service Accounts (one per pipeline role) ──

# 1. Build SA — pushes images to Artifact Registry + signs with Cosign
resource "google_service_account" "github_build" {
  account_id   = "github-actions-build"
  display_name = "GitHub Actions Build SA"
  description  = "Used by build-push job to push and sign container images"
}

# 2. Staging Deploy SA — deploys to staging Cloud Run only
resource "google_service_account" "github_staging" {
  account_id   = "github-actions-staging"
  display_name = "GitHub Actions Staging Deploy SA"
  description  = "Least-privilege SA for staging deployments — cannot touch production"
}

# 3. Production Deploy SA — deploys to production Cloud Run only
resource "google_service_account" "github_prod" {
  account_id   = "github-actions-prod"
  display_name = "GitHub Actions Production Deploy SA"
  description  = "Least-privilege SA for production deployments — separate from staging"
}


# ── WIF Bindings (allow GitHub Actions to impersonate each SA) ──

locals {
  wif_principal = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_repo}"
}

resource "google_service_account_iam_member" "wif_build" {
  service_account_id = google_service_account.github_build.name
  role               = "roles/iam.workloadIdentityUser"
  member             = local.wif_principal
}

resource "google_service_account_iam_member" "wif_staging" {
  service_account_id = google_service_account.github_staging.name
  role               = "roles/iam.workloadIdentityUser"
  member             = local.wif_principal
}

resource "google_service_account_iam_member" "wif_prod" {
  service_account_id = google_service_account.github_prod.name
  role               = "roles/iam.workloadIdentityUser"
  member             = local.wif_principal
}


# ── IAM: Build SA permissions ──
resource "google_artifact_registry_repository_iam_member" "build_writer" {
  location   = google_artifact_registry_repository.app.location
  repository = google_artifact_registry_repository.app.repository_id
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${google_service_account.github_build.email}"
}

# Required so build SA can sign images with Cosign via OIDC
resource "google_service_account_iam_member" "build_token_creator" {
  service_account_id = google_service_account.github_build.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${google_service_account.github_build.email}"
}


# ── IAM: Staging Deploy SA permissions ──
resource "google_project_iam_member" "staging_run_developer" {
  project = var.project_id
  role    = "roles/run.developer"
  member  = "serviceAccount:${google_service_account.github_staging.email}"
}

resource "google_artifact_registry_repository_iam_member" "staging_reader" {
  location   = google_artifact_registry_repository.app.location
  repository = google_artifact_registry_repository.app.repository_id
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${google_service_account.github_staging.email}"
}

resource "google_secret_manager_secret_iam_member" "staging_db_url" {
  secret_id = google_secret_manager_secret.db_url_staging.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.github_staging.email}"
}

resource "google_secret_manager_secret_iam_member" "staging_secret_key" {
  secret_id = google_secret_manager_secret.secret_key_staging.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.github_staging.email}"
}


# ── IAM: Production Deploy SA permissions ──
resource "google_project_iam_member" "prod_run_admin" {
  project = var.project_id
  role    = "roles/run.admin"   # run.admin required for traffic management
  member  = "serviceAccount:${google_service_account.github_prod.email}"
}

resource "google_artifact_registry_repository_iam_member" "prod_reader" {
  location   = google_artifact_registry_repository.app.location
  repository = google_artifact_registry_repository.app.repository_id
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${google_service_account.github_prod.email}"
}

resource "google_secret_manager_secret_iam_member" "prod_db_url" {
  secret_id = google_secret_manager_secret.db_url_prod.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.github_prod.email}"
}

resource "google_secret_manager_secret_iam_member" "prod_secret_key" {
  secret_id = google_secret_manager_secret.secret_key_prod.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.github_prod.email}"
}


# ── Cloud Run Service Account (runtime — least privilege) ──
resource "google_service_account" "cloud_run" {
  account_id   = "flask-app-runner"
  display_name = "Flask App Cloud Run SA"
  description  = "Runtime identity for Cloud Run instances — minimal permissions"
}

resource "google_project_iam_member" "cloud_run_sql" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.cloud_run.email}"
}

resource "google_secret_manager_secret_iam_member" "db_url_access" {
  secret_id = google_secret_manager_secret.db_url_prod.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.cloud_run.email}"
}

resource "google_secret_manager_secret_iam_member" "secret_key_access" {
  secret_id = google_secret_manager_secret.secret_key_prod.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.cloud_run.email}"
}

# Cloud Run SA also needs to read from GAR to pull its own image
resource "google_artifact_registry_repository_iam_member" "cloud_run_reader" {
  location   = google_artifact_registry_repository.app.location
  repository = google_artifact_registry_repository.app.repository_id
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${google_service_account.cloud_run.email}"
}


# ── Cloud Run — Production ──
resource "google_cloud_run_v2_service" "prod" {
  name     = "flask-app-prod"
  location = var.region
  ingress  = "INGRESS_TRAFFIC_ALL"

  template {
    service_account = google_service_account.cloud_run.email

    scaling {
      min_instance_count = var.cloud_run_min_instances_prod
      max_instance_count = var.cloud_run_max_instances_prod
    }

    vpc_access {
      connector = google_vpc_access_connector.prod.id
      egress    = "PRIVATE_RANGES_ONLY"
    }

    containers {
      image = "${var.region}-docker.pkg.dev/${var.project_id}/devsecops-repo/flask-app:latest"

      ports {
        container_port = 8000
      }

      resources {
        limits = {
          cpu    = "2"
          memory = "1Gi"
        }
      }

      # SECURITY: Secrets injected at runtime from Secret Manager — never in env vars
      env {
        name = "DATABASE_URL"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.db_url_prod.secret_id
            version = "latest"
          }
        }
      }

      env {
        name = "SECRET_KEY"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.secret_key_prod.secret_id
            version = "latest"
          }
        }
      }

      startup_probe {
        http_get { path = "/api/v1/health" }
        period_seconds    = 10
        failure_threshold = 3
      }

      liveness_probe {
        http_get { path = "/api/v1/health" }
        period_seconds    = 30
        failure_threshold = 3
      }
    }
  }

  traffic {
    type    = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
    percent = 100
  }

  labels = { env = "prod", managed = "terraform" }

  depends_on = [
    google_project_service.apis,
    google_vpc_access_connector.prod,
    google_secret_manager_secret.db_url_prod,
    google_secret_manager_secret.secret_key_prod,
  ]
}

# Allow unauthenticated public access to production
resource "google_cloud_run_v2_service_iam_member" "prod_public" {
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.prod.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}


# ── Cloud Run — Staging ──
resource "google_service_account" "cloud_run_staging" {
  account_id   = "flask-app-runner-staging"
  display_name = "Flask App Cloud Run Staging SA"
}

resource "google_project_iam_member" "cloud_run_staging_sql" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.cloud_run_staging.email}"
}

resource "google_secret_manager_secret_iam_member" "staging_run_db_url" {
  secret_id = google_secret_manager_secret.db_url_staging.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.cloud_run_staging.email}"
}

resource "google_secret_manager_secret_iam_member" "staging_run_secret_key" {
  secret_id = google_secret_manager_secret.secret_key_staging.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.cloud_run_staging.email}"
}

resource "google_cloud_run_v2_service" "staging" {
  name     = "flask-app-staging"
  location = var.region
  ingress  = "INGRESS_TRAFFIC_ALL"

  template {
    service_account = google_service_account.cloud_run_staging.email

    scaling {
      min_instance_count = 0  # Scale to zero in staging to save cost
      max_instance_count = 5
    }

    vpc_access {
      connector = google_vpc_access_connector.staging.id
      egress    = "PRIVATE_RANGES_ONLY"
    }

    containers {
      image = "${var.region}-docker.pkg.dev/${var.project_id}/devsecops-repo/flask-app:latest"

      ports {
        container_port = 8000
      }

      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
      }

      env {
        name = "DATABASE_URL"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.db_url_staging.secret_id
            version = "latest"
          }
        }
      }

      env {
        name = "SECRET_KEY"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.secret_key_staging.secret_id
            version = "latest"
          }
        }
      }

      startup_probe {
        http_get { path = "/api/v1/health" }
        period_seconds    = 10
        failure_threshold = 3
      }

      liveness_probe {
        http_get { path = "/api/v1/health" }
        period_seconds    = 30
        failure_threshold = 3
      }
    }
  }

  traffic {
    type    = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
    percent = 100
  }

  labels = { env = "staging", managed = "terraform" }

  depends_on = [
    google_project_service.apis,
    google_vpc_access_connector.staging,
    google_secret_manager_secret.db_url_staging,
    google_secret_manager_secret.secret_key_staging,
  ]
}

resource "google_cloud_run_v2_service_iam_member" "staging_public" {
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.staging.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}
