# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

### Install & setup
```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements-dev.txt
pre-commit install
```

### Run the app
```bash
# SQLite — no Docker needed
flask --app "app:create_app('development')" run

# Full stack (PostgreSQL via Docker)
cp .env.example .env          # fill in values first
docker compose up
```

### Database migrations
```bash
flask --app "app:create_app('development')" db migrate -m "description"
flask --app "app:create_app('development')" db upgrade
```

### Tests
```bash
pytest                              # all tests
pytest tests/test_security.py      # single file
pytest -k "test_name"              # single test by name
pytest --cov=app --cov-report=term-missing   # with coverage
```

Coverage threshold is enforced at 80% (`pyproject.toml`). `TestingConfig` uses in-memory SQLite — no external services needed.

### Lint & format
```bash
ruff check app/ tests/ --fix
ruff format app/ tests/
```

### Security scanning (local)
```bash
bandit -r app/ -ll                 # SAST (medium severity and above)
pip-audit -r requirements.txt      # dependency CVEs
```

### Terraform
```bash
cd terraform
terraform init
terraform plan -var="project_id=YOUR_PROJECT"
terraform apply -var="project_id=YOUR_PROJECT"
terraform output                   # prints GitHub secret values after apply
```

## Application Architecture

The app uses the **application factory pattern** — `create_app(config_name)` in `app/__init__.py`. Config name maps directly to a class in `app/config.py` (`development` → `DevelopmentConfig`, `testing` → `TestingConfig`, `production` → `ProductionConfig`). All Flask extensions (`db`, `migrate`) and blueprints are initialised inside the factory.

| File | Role |
|---|---|
| `app/__init__.py` | Factory; registers `api_bp` at `/api/v1`, sets security headers (`X-Frame-Options`, `X-Content-Type-Options`), adds per-request correlation ID via `g.request_id` |
| `app/config.py` | `BaseConfig` → env-specific subclasses; `ProductionConfig.__init__` asserts `DATABASE_URL` and `SECRET_KEY` are set; `MAX_CONTENT_LENGTH = 16 MB` |
| `app/models.py` | `User` model; password stored as scrypt hash (Werkzeug); `to_dict()` never exposes `password_hash`; `__repr__` omits hash to prevent log leakage |
| `app/routes.py` | `UserSchema` (Marshmallow) validates all input before DB access; duplicate email/username caught via `IntegrityError` (not a pre-check race condition) |
| `app/errors.py` | Centralised handlers for `HTTPException` and bare `Exception`; 500 returns a generic body, logs `exc_info=exc` |

## CI/CD Pipeline

All four workflows are fully implemented. The pipeline is tag-triggered for deploy and push/PR-triggered for CI.

### `ci.yml` — CI Pipeline (push/PR to `main`, `development`)
Six sequential gate jobs:
1. `lint-and-security` — ruff (with GitHub annotations) + Bandit SAST
2. `dependency-scan` — pip-audit (JSON + human-readable)
3. `secret-scan` — Gitleaks with full history (`fetch-depth: 0`)
4. `test` — pytest with `--cov-fail-under=80` (needs job 1)
5. `sast` — Semgrep container (`auto`, `python`, `flask`, `owasp-top-ten` rulesets) → SARIF to GitHub Security tab
6. `build-and-scan` — Docker build → Trivy CRITICAL/HIGH gate → SBOM (SPDX-JSON) (needs jobs 2–5)

### `deploy.yml` — Deploy Pipeline (`v*` tags or `workflow_dispatch`)
1. `build-push` — GCP WIF auth → push to Artifact Registry → Cosign image signing; Trivy scan gates the push
2. `deploy-staging` — `google-github-actions/deploy-cloudrun`; smoke tests `/api/v1/health`
3. `deploy-production` — manual approval gate (GitHub Environment); deployed with `--no-traffic`; 10% → 50% → 100% gradual traffic migration; auto-rollback on failure

### `security-monitor.yml` — Scheduled Security Scan (daily 06:00 UTC)
Three parallel jobs: dependency CVE scan (pip-audit → auto GitHub issue), production image Trivy scan (GCP WIF → pull from GAR → SARIF upload), Gitleaks full-history secret scan. All three send Slack alerts to `SLACK_SECURITY_WEBHOOK` on failure.

### `iac-scan.yml` — IaC Scan (on Terraform or Dockerfile changes)
Hadolint (Dockerfile), Checkov (Terraform → SARIF to Security tab), `docker compose config` validation.

## Infrastructure (Terraform)

All GCP infrastructure is in `terraform/`. Three files:
- `main.tf` — all resources
- `variables.tf` — `project_id`, `region`, `github_repo`, DB tiers, scaling vars
- `outputs.tf` — run `terraform output` after apply to get exact values for GitHub secrets

### Resource map
| Resource | Purpose |
|---|---|
| `google_iam_workload_identity_pool/provider` | Keyless GitHub Actions auth — no static SA keys; scoped to this repo only via `attribute_condition` |
| `google_service_account.github_build/staging/prod` | One SA per pipeline role; WIF-bound; staging SA cannot touch prod resources |
| `google_artifact_registry_repository.app` | `immutable_tags = true` — tags cannot be overwritten |
| `google_compute_network/subnetwork` + VPC connectors | Private VPC; two connectors (`prod-vpc-connector`, `staging-vpc-connector`) |
| `google_sql_database_instance.prod/staging` | PostgreSQL 16; no public IP; `ssl_mode = ENCRYPTED_ONLY`; `scram-sha-256` passwords; PITR enabled on prod |
| `google_secret_manager_secret.*` | Four secrets: `db-url-prod`, `secret-key-prod`, `db-url-staging`, `secret-key-staging` |
| `google_cloud_run_v2_service.prod/staging` | Dedicated runtime SAs; secrets injected from Secret Manager; startup + liveness probes on `/api/v1/health` |

After `terraform apply`, run `terraform output` and copy the printed values into the corresponding GitHub repository secrets.

## Security Conventions

- **Input validation**: all request bodies go through a Marshmallow schema (`UserSchema`) before any DB access. There is no separate pre-validation step — the schema is the gate.
- **Duplicate detection**: rely on DB `IntegrityError` on commit, not a pre-check query (eliminates race condition).
- **Secrets at runtime**: `DATABASE_URL` and `SECRET_KEY` are injected via Secret Manager in GCP and via `.env` locally. `ProductionConfig` will hard-fail at startup if either is missing.
- **Error responses**: `handle_unexpected_error` in `errors.py` always returns a generic body — stack traces never reach the API client.
- **Pre-commit hooks**: `detect-private-key`, `ruff`, `bandit`, `detect-secrets` run on every commit. Do not bypass with `--no-verify`.

## GitHub Secrets Required

| Secret | Source |
|---|---|
| `GCP_PROJECT_ID` | Your GCP project ID |
| `GCP_WORKLOAD_IDENTITY_PROVIDER` | `terraform output wif_provider` |
| `GCP_SERVICE_ACCOUNT` | `terraform output github_build_sa` |
| `GCP_WIF_STAGING` | Same as `GCP_WORKLOAD_IDENTITY_PROVIDER` |
| `GCP_SA_STAGING` | `terraform output github_staging_sa` |
| `GCP_WIF_PROD` | Same as `GCP_WORKLOAD_IDENTITY_PROVIDER` |
| `GCP_SA_PROD` | `terraform output github_prod_sa` |
| `SLACK_SECURITY_WEBHOOK` | Slack Incoming Webhook URL for security alerts |
