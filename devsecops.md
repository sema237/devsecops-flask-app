# DevSecOps Mastery — Implementation Guide

> **Source:** DevSecOps Mastery: Production-Ready CI/CD with GitHub Actions (April 2026)
> **Stack:** Python / Flask / GitHub Actions / Docker / Google Cloud
> **Repo:** `sema237/devsecops-flask-app`
>
> This document maps every course module to the actual implementation in this repository.
> ✅ = complete | 🔲 = still needed

---

## Module 1: DevSecOps Foundations

### 1.1 The DevSecOps Pipeline

Security is integrated at every stage — not bolted on at the end:

| Stage | Tools | Pipeline Job |
|---|---|---|
| Code | Python, Flask, SQLAlchemy | `lint-and-security` |
| Build | Docker, pip | `build-and-scan` |
| Test | pytest, coverage | `test` |
| Release | GitHub Releases, Artifact Registry | `build-and-scan` |
| Deploy | Cloud Run, Terraform | `deploy` |
| Monitor | Dependabot, Trivy nightly | `security-monitor` |

### 1.2 Prerequisites

```bash
python3 --version        # 3.11+
docker --version
gh auth login
gcloud auth login
gcloud config set project YOUR_PROJECT_ID
node --version           # 18+ (for some scanning tools)
```

### 1.3 Repository Setup ✅

```bash
mkdir devsecops-flask-app && cd devsecops-flask-app
git init
gh repo create devsecops-flask-app --public --source=. --push
mkdir -p app tests .github/workflows scripts terraform .semgrep
touch app/__init__.py app/config.py app/models.py app/routes.py app/errors.py
touch tests/__init__.py tests/conftest.py tests/test_security.py
touch Dockerfile docker-compose.yml requirements.txt requirements-dev.txt
touch .env.example .gitignore .pre-commit-config.yaml pyproject.toml
```

**Template this repo** for future projects:
```bash
gh api --method PATCH repos/sema237/devsecops-flask-app --field is_template=true
# Future projects:
gh repo create my-new-project --template sema237/devsecops-flask-app --clone
```

---

## Module 2: Building the Flask Application ✅

All application code is in `app/`. The factory pattern is the foundation.

### 2.1 Application Factory (`app/__init__.py`) ✅

`create_app(config_name)` maps to `{config_name.title()}Config` in `app/config.py`. Extensions (`db`, `migrate`) are initialised inside the factory, never at module level. Security headers (`X-Frame-Options`, `X-Content-Type-Options`) and correlation IDs are added via `@app.before_request` / `@app.after_request`.

### 2.2 Config Hierarchy (`app/config.py`) ✅

```
BaseConfig
├── DevelopmentConfig  — SQLite fallback, DEBUG=True
├── TestingConfig      — in-memory SQLite, no external services
└── ProductionConfig   — asserts DATABASE_URL + SECRET_KEY are set at startup
                         SESSION_COOKIE_SECURE=True, ssl enforced
```

**Critical:** `ProductionConfig.__init__` will hard-fail if env vars are missing — this is intentional.

### 2.3 Models (`app/models.py`) ✅

- Passwords: Werkzeug scrypt hash (`generate_password_hash` / `check_password_hash`)
- `to_dict()` never exposes `password_hash`
- `__repr__` omits hash to prevent log leakage
- `updated_at` + `password_changed_at` for audit trail

### 2.4 Routes (`app/routes.py`) ✅

- `UserSchema` (Marshmallow) validates all input before any DB access
- Duplicate email/username detected via `IntegrityError` on commit — not a pre-check (eliminates race condition)
- `request.get_json(silent=True)` prevents crash on non-JSON body

### 2.5 Error Handlers (`app/errors.py`) ✅

- `HTTPException` handler returns structured JSON
- `Exception` handler logs `exc_info=exc` but returns a generic body — stack traces never reach the client

### 2.6 Requirements ✅

**`requirements.txt`** (production, exact pins):
```
flask==3.1.0
flask-sqlalchemy==3.1.1
flask-migrate==4.0.7
marshmallow==3.23.2
gunicorn==23.0.0
psycopg2-binary==2.9.10
python-dotenv==1.0.1
```

**`requirements-dev.txt`** adds: `pytest`, `pytest-cov`, `ruff`, `bandit`, `safety`, `pip-audit`, `pre-commit`

### 2.7 Dockerfile ✅

Multi-stage build — build tools never reach the production image:
```dockerfile
FROM python:3.13-slim AS builder   # 3.13 chosen to avoid CVEs in 3.12
# ... install deps to /install ...
FROM python:3.13-slim
RUN groupadd -r appuser && useradd -r -g appuser appuser
USER appuser                        # Non-root — prevents container escape
EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=3s ...
CMD ["gunicorn", "--bind", "0.0.0.0:8000", ...]
```

`.dockerignore` excludes `.env`, `tests/`, `terraform/`, dev tooling.

### 2.8 Database Migrations

```bash
# Initialize (run once)
flask --app 'app:create_app("development")' db init

# After model changes
flask --app 'app:create_app("development")' db migrate -m "describe change"
flask --app 'app:create_app("development")' db upgrade

# In production — run as a Cloud Run Job before deploy:
gcloud run jobs create run-migrations \
  --image=IMAGE_URL \
  --region=us-central1 \
  --set-secrets=DATABASE_URL=db-url-prod:latest \
  --command="flask" \
  --args="db,upgrade"
```

> **Tip:** Always review auto-generated migration files in `migrations/versions/` before applying. Alembic may interpret column renames as drop + add.

### 2.9 Local Development ✅

```bash
cp .env.example .env    # fill in values
docker compose up       # starts app + PostgreSQL with healthcheck
```

`docker-compose.yml` reads credentials from `.env` (not hardcoded), uses `depends_on: condition: service_healthy` for the DB.

---

## Module 3: Pre-Commit Security Hooks ✅

Pre-commit hooks are the first security gate — they run before code reaches the remote.

### 3.1 `.pre-commit-config.yaml` ✅

```yaml
repos:
  - repo: https://github.com/pre-commit/pre-commit-hooks
    rev: v5.0.0
    hooks:
      - id: trailing-whitespace
      - id: end-of-file-fixer
      - id: check-yaml
      - id: check-json
      - id: check-toml
      - id: check-merge-conflict
      - id: detect-private-key          # Catches raw keys/certs
      - id: check-added-large-files
        args: ["--maxkb=500"]

  - repo: https://github.com/astral-sh/ruff-pre-commit
    rev: v0.8.6
    hooks:
      - id: ruff
        args: [--fix]
      - id: ruff-format

  - repo: https://github.com/PyCQA/bandit
    rev: 1.8.3
    hooks:
      - id: bandit
        args: ["-r", "app/", "-ll"]    # Medium severity and above

  - repo: https://github.com/Yelp/detect-secrets
    rev: v1.5.0
    hooks:
      - id: detect-secrets
        args: ["--baseline", ".secrets.baseline"]
        exclude: "(.env.example|CLAUDE.md)"
```

### 3.2 Activate

```bash
pip install pre-commit
pre-commit install
pre-commit run --all-files    # Test against all existing files
```

> **Incident response:** If gitleaks or detect-secrets catches a real secret, rotate the credential immediately. Then use `git-filter-repo` to remove it from history — deleting the file is not enough.

---

## Module 4: GitHub Actions CI Pipeline ✅

**File:** `.github/workflows/ci.yml`
**Trigger:** Push to `main`/`development`, PR to `main`

### 4.1 Pipeline Architecture

```
┌─────────────────┐  ┌──────────────────┐  ┌─────────────┐
│ lint-and-       │  │ dependency-scan  │  │ secret-scan │  ← Parallel Group 1
│ security        │  │                  │  │             │
└────────┬────────┘  └──────────────────┘  └──────┬──────┘
         │                                         │
         ▼                                         │
┌────────────────┐   ┌──────────────────┐          │
│ test           │   │ sast (Semgrep)   │  ←────── ┘
│ (needs: lint)  │   │                  │
└────────┬───────┘   └──────────┬───────┘
         └──────────────────────┘
                      │
                      ▼
           ┌──────────────────────┐
           │ build-and-scan       │  ← Docker + Trivy + SBOM (needs: ALL)
           └──────────────────────┘
```

### 4.2 Job Summary

| Job | Tools | Gate |
|---|---|---|
| `lint-and-security` | ruff (GitHub annotations) + Bandit JSON + human-readable | Always first |
| `dependency-scan` | pip-audit (JSON + human-readable) | Parallel |
| `secret-scan` | Gitleaks (`fetch-depth: 0` — full history) | Parallel |
| `test` | pytest `--cov-fail-under=80` | Needs `lint-and-security` |
| `sast` | Semgrep container: `auto`, `p/python`, `p/flask`, `p/security-audit`, `p/owasp-top-ten` → SARIF | Parallel with test |
| `build-and-scan` | Docker build → Trivy CRITICAL/HIGH gate → SBOM (SPDX-JSON) | Needs all above |

---

## Module 5: Advanced Security Scanning

### 5.1 Custom Semgrep Rules 🔲

Create `.semgrep/flask-security.yml`:

```yaml
rules:
  - id: flask-raw-sql
    patterns:
      - pattern: db.engine.execute(...)
    message: >
      Raw SQL detected. Use SQLAlchemy ORM queries
      or parameterized queries to prevent SQL injection.
    severity: ERROR
    languages: [python]
    metadata:
      cwe: CWE-89
      owasp: A03:2021 Injection

  - id: flask-debug-enabled
    pattern: app.run(..., debug=True, ...)
    message: >
      Debug mode must not be enabled in production.
      Use environment-based configuration.
    severity: WARNING
    languages: [python]

  - id: flask-secret-key-hardcoded
    patterns:
      - pattern: SECRET_KEY = "..."
      - pattern-not: SECRET_KEY = "change-me-in-production"
    message: Hardcoded secret key detected.
    severity: ERROR
    languages: [python]
```

Run locally:
```bash
semgrep scan --config=.semgrep/ app/
semgrep scan --config=p/flask app/
```

### 5.2 Trivy (Container Scanning) ✅

Trivy runs in both `ci.yml` (build gate) and `deploy.yml` (pre-push gate) and `security-monitor.yml` (nightly). Local usage:

```bash
brew install trivy

# Scan built image
trivy image devsecops-flask-app:latest

# Severity filter
trivy image --severity HIGH,CRITICAL devsecops-flask-app:latest

# Scan Dockerfile for misconfigurations
trivy config Dockerfile

# Generate JSON report
trivy image --format json -o trivy-report.json devsecops-flask-app:latest
```

### 5.3 IaC Scanning — Checkov ✅

**File:** `.github/workflows/iac-scan.yml`
Triggers on changes to `terraform/**`, `Dockerfile`, or `docker-compose.yml`.

- Checkov scans `terraform/` → SARIF to GitHub Security tab
- Hadolint lints `Dockerfile`
- `docker compose config --quiet` validates compose syntax

### 5.4 DAST with OWASP ZAP 🔲

Add to `ci.yml` after `deploy-staging` succeeds:

```yaml
dast-scan:
  runs-on: ubuntu-latest
  needs: [deploy-staging]
  steps:
    - name: OWASP ZAP Baseline Scan
      uses: zaproxy/action-baseline@v0.12.0
      with:
        target: https://staging.yourapp.com
        rules_file_name: .zap/rules.tsv
        cmd_options: '-a'

    - name: Upload ZAP Report
      uses: actions/upload-artifact@v4
      if: always()
      with:
        name: zap-report
        path: report_html.html
```

> **Important:** DAST runs against staging only — never production. ZAP generates significant traffic and may trigger WAF rules.

---

## Module 6: Secrets Management

### 6.1 GitHub Secrets Setup

```bash
# Core secrets
gh secret set GCP_PROJECT_ID
gh secret set GCP_WORKLOAD_IDENTITY_PROVIDER    # from: terraform output wif_provider
gh secret set GCP_SERVICE_ACCOUNT              # from: terraform output github_build_sa

# Staging-scoped
gh secret set GCP_WIF_STAGING --env staging    # same as GCP_WORKLOAD_IDENTITY_PROVIDER
gh secret set GCP_SA_STAGING --env staging     # from: terraform output github_staging_sa

# Production-scoped
gh secret set GCP_WIF_PROD --env production
gh secret set GCP_SA_PROD --env production     # from: terraform output github_prod_sa

# Alerting
gh secret set SLACK_SECURITY_WEBHOOK           # Slack Incoming Webhook URL

# Non-sensitive variables
gh variable set GCP_REGION --body 'us-central1'
```

### 6.2 Environment-Based Secrets ✅

Production secrets are scoped to the `production` GitHub Environment, which requires manual approval before the deployment step runs:

```yaml
deploy-production:
  environment:
    name: production    # Manual approval gate configured in GitHub Settings
    url: https://yourapp.com
```

At runtime, Cloud Run injects secrets directly from Secret Manager via `--set-secrets` — the values never appear in container images or environment configs.

### 6.3 Gitleaks Configuration 🔲

Create `.gitleaks.toml`:

```toml
title = "Custom Gitleaks Config"

[allowlist]
description = "Allowlisted patterns"
paths = [
  '''tests/fixtures/.*''',    # Test fixtures with fake credentials
  '''.env.example''',         # Example env file
]

[[rules]]
id = "custom-api-key"
description = "Custom API key pattern"
regex = '''(?i)api[_-]?key\s*[:=]\s*['"]?[a-z0-9]{32,}'''
tags = ["key", "api"]
```

---

## Module 7: Continuous Deployment Pipeline ✅

**File:** `.github/workflows/deploy.yml`
**Trigger:** Push of `v*` tags (e.g. `v1.2.3`) or `workflow_dispatch`

### 7.1 Deployment Flow

```
v1.2.3 tag pushed
       │
       ▼
build-push
├── GCP WIF auth (keyless OIDC — no static SA keys)
├── Trivy scan gates the push (CRITICAL/HIGH = blocked)
├── Push to Artifact Registry
└── Cosign image signing (keyless via OIDC)
       │
       ▼
deploy-staging
├── GCP WIF auth (staging SA only)
├── Cloud Run deploy: 1 CPU / 512Mi / 0-5 instances
├── Secrets from Secret Manager (--set-secrets)
├── VPC connector for private Cloud SQL access
└── Smoke test: curl /api/v1/health → must return 200
       │
       ▼  (manual approval gate in GitHub Environments)
deploy-production
├── GCP WIF auth (prod SA only — cannot touch staging)
├── Cloud Run deploy: --no-traffic (new revision gets 0%)
├── 2 CPU / 1Gi / 1-20 instances
├── Post-deploy verification: 5 retries × 10s
├── Gradual traffic migration: 10% → 50% → 100% (60s windows)
└── Auto-rollback on any failure
```

### 7.2 Tag and Deploy

```bash
git tag v1.0.0
git push origin v1.0.0
# Monitor:
gh run list --workflow=deploy.yml
gh run view <run-id> --log
```

---

## Module 8: Infrastructure as Code — Terraform ✅

**Files:** `terraform/main.tf`, `terraform/variables.tf`, `terraform/outputs.tf`

### 8.1 One-Time Setup

```bash
# Create the GCS state bucket first
gcloud storage buckets create gs://your-project-tf-state --location=us-central1
gcloud storage buckets update gs://your-project-tf-state --versioning

# Update terraform/main.tf backend block:
# bucket = "your-project-tf-state"
```

### 8.2 Deploy Infrastructure

```bash
cd terraform

# Create terraform.tfvars (gitignored — never commit real values)
cat > terraform.tfvars <<EOF
project_id = "your-gcp-project-id"
region     = "us-central1"
github_repo = "sema237/devsecops-flask-app"
EOF

terraform init
terraform plan
terraform apply

# Get GitHub secret values
terraform output
```

### 8.3 Resource Map

| Resource | Notes |
|---|---|
| `google_iam_workload_identity_pool/provider` | Keyless auth; `attribute_condition` scopes to this repo only — without it any GitHub repo could request tokens |
| `github_build`, `github_staging`, `github_prod` SAs | One SA per pipeline role; staging SA cannot touch production resources |
| `google_artifact_registry_repository` | `immutable_tags = true` — pushed tags cannot be overwritten |
| VPC + 2 connectors | `prod-vpc-connector` (10.8.0.0/28), `staging-vpc-connector` (10.8.1.0/28) |
| Cloud SQL prod + staging | No public IP; `ssl_mode = ENCRYPTED_ONLY`; `scram-sha-256`; PITR on prod (14-day retention) |
| 4 × Secret Manager secrets | `db-url-prod`, `secret-key-prod`, `db-url-staging`, `secret-key-staging` |
| Cloud Run prod + staging | Dedicated runtime SAs; startup + liveness probes on `/api/v1/health` |

### 8.4 Populate Secrets After Apply

```bash
# Add actual secret values (never put real values in .tf files)
echo -n "postgresql://..." | gcloud secrets versions add db-url-prod --data-file=-
echo -n "your-64-char-secret-key" | gcloud secrets versions add secret-key-prod --data-file=-
echo -n "postgresql://..." | gcloud secrets versions add db-url-staging --data-file=-
echo -n "your-staging-secret-key" | gcloud secrets versions add secret-key-staging --data-file=-
```

---

## Module 9: Monitoring and Incident Response

### 9.1 Dependabot 🔲

Create `.github/dependabot.yml`:

```yaml
version: 2
updates:
  - package-ecosystem: pip
    directory: /
    schedule:
      interval: weekly
    reviewers:
      - your-security-team
    labels:
      - dependencies
      - security
    open-pull-requests-limit: 10

  - package-ecosystem: github-actions
    directory: /
    schedule:
      interval: weekly
    labels:
      - ci-cd

  - package-ecosystem: docker
    directory: /
    schedule:
      interval: weekly
```

### 9.2 Scheduled Security Scan ✅

**File:** `.github/workflows/security-monitor.yml`
**Schedule:** Daily at 06:00 UTC

Three parallel jobs:

| Job | What it does |
|---|---|
| `dependency-scan` | pip-audit → auto-opens GitHub issue with CVE details + Slack alert |
| `image-scan` | WIF auth → pull `flask-app:latest` from GAR → Trivy scan → SARIF to Security tab + Slack alert |
| `secret-scan` | Gitleaks with `fetch-depth: 0` (full history) + Slack alert |

Manual trigger:
```bash
gh workflow run security-monitor.yml
```

### 9.3 GitHub Security Dashboard

With SARIF uploads from Semgrep, Trivy, and Checkov, all findings appear in **Security → Code Scanning**. This is your unified security SIEM view for the application.

```bash
# Export findings via API for Confluence/stakeholder reporting:
gh api repos/sema237/devsecops-flask-app/code-scanning/alerts \
  --jq '.[] | {rule: .rule.id, severity: .rule.severity, state: .state}'
```

---

## Module 10: Branch Protection and Governance

### 10.1 Branch Protection Rules 🔲

Enforce that all 6 CI jobs must pass before any PR can merge:

```bash
gh api repos/sema237/devsecops-flask-app/branches/main/protection \
  --method PUT \
  --field required_status_checks='{
    "strict": true,
    "contexts": [
      "lint-and-security",
      "dependency-scan",
      "secret-scan",
      "test",
      "sast",
      "build-and-scan"
    ]
  }' \
  --field enforce_admins=true \
  --field required_pull_request_reviews='{
    "required_approving_review_count": 1,
    "dismiss_stale_reviews": true,
    "require_code_owner_reviews": true
  }'
```

### 10.2 CODEOWNERS 🔲

Create `.github/CODEOWNERS`:

```
# Security team must review any changes to security-sensitive files
/.github/workflows/   @sema237
/Dockerfile           @sema237
/.semgrep/            @sema237
/.gitleaks.toml       @sema237
/terraform/           @sema237
```

### 10.3 Signed Commits 🔲

```bash
# Generate GPG key
gpg --full-generate-key
gpg --list-secret-keys --keyid-format=long

# Configure Git to sign all commits
git config --global user.signingkey YOUR_KEY_ID
git config --global commit.gpgsign true

# Add your GPG public key to GitHub
gpg --armor --export YOUR_KEY_ID | gh gpg-key add -
```

---

## Module 11: Security-Focused Testing ✅

### 11.1 Test Configuration (`tests/conftest.py`) ✅

- `app` fixture (session-scoped): creates in-memory SQLite DB, yields, drops all
- `client` fixture: Flask test client
- `clean_db` fixture (autouse): rolls back and truncates all tables after every test — no test pollution

### 11.2 Security Test Cases (`tests/test_security.py`) ✅

Tests are organised by OWASP category:

| Test Class | OWASP | What's tested |
|---|---|---|
| Health check | — | `GET /api/v1/health` returns 200 |
| Happy path | — | User creation, response shape, password hashing |
| `test_create_user_response_omits_password_hash` | A02 | `password`/`password_hash` never in response |
| `test_password_stored_as_hash` | A02 | DB stores scrypt hash, not plaintext |
| `test_duplicate_email_returns_409` | A07 | Duplicate detection |
| Password length params | A07 | Rejects passwords < 12 chars |
| Email validation params | A03 | Rejects malformed emails |
| SQL injection params | A03 | Payloads return 400 or 201, never 500 |
| XSS payloads | A03 | `<script>` tags don't crash the server |
| `test_404_returns_json` | — | Error responses are JSON |
| `test_500_response_does_not_expose_traceback` | A05 | No Traceback in response body |

### 11.3 Run Tests

```bash
pytest                                           # all tests
pytest tests/test_security.py                   # single file
pytest -k "test_sql_injection"                  # single test
pytest --cov=app --cov-report=term-missing       # with coverage detail
pytest --cov=app --cov-fail-under=80            # enforce 80% threshold
```

Coverage is configured in `pyproject.toml` — the 80% threshold is enforced both locally and in CI.

---

## Module 12: Production Readiness Checklist

### 12.1 Pre-Release Checklist

| Category | Check | Tool | Pipeline Job | Status |
|---|---|---|---|---|
| Code | No linting errors | Ruff | `lint-and-security` | ✅ |
| Code | Bandit zero high/critical | Bandit | `lint-and-security` | ✅ |
| Code | No hardcoded secrets | Gitleaks | `secret-scan` | ✅ |
| Code | SAST scan passes | Semgrep | `sast` | ✅ |
| Deps | No known CVEs | pip-audit | `dependency-scan` | ✅ |
| Deps | SBOM generated | anchore/sbom-action | `build-and-scan` | ✅ |
| Image | Zero CRITICAL CVEs | Trivy | `build-and-scan` | ✅ |
| Image | Non-root user | Dockerfile / Checkov | `iac-scan` | ✅ |
| Image | Image is signed | Cosign | `deploy` | ✅ |
| Infra | IaC passes Checkov | Checkov | `iac-scan` | ✅ |
| Infra | HTTPS enforced | Cloud Run | `deploy` | ✅ |
| Test | 80%+ coverage | pytest-cov | `test` | ✅ |
| Test | Security tests pass | pytest | `test` | ✅ |
| Gov | Branch protection enforced | GitHub | Settings | 🔲 |
| Gov | PR reviewed + approved | CODEOWNERS | Branch rules | 🔲 |
| Mon | Dependabot enabled | GitHub | `dependabot.yml` | 🔲 |
| Mon | Nightly scan active | Trivy | `security-monitor` | ✅ |

### 12.2 Security Maturity Model

| Level | Capabilities | This Repo |
|---|---|---|
| **Level 1: Basic** | Linting, basic tests, manual deploys | ✅ Complete |
| **Level 2: Automated** | SAST, dependency scanning, automated builds | ✅ Complete |
| **Level 3: Integrated** | DAST, container scanning, SBOM, signed images | ✅ (DAST 🔲) |
| **Level 4: Governed** | Branch protection, CODEOWNERS, audit trails | 🔲 Module 10 |
| **Level 5: Optimized** | Nightly scans, auto-remediation, metrics dashboards | ✅ Nightly scan done |

---

## Appendix A: Quick Reference Commands

### Local Development

```bash
# Setup
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements-dev.txt
pre-commit install

# Run
flask --app 'app:create_app("development")' run
docker compose up

# Test
pytest tests/ -v --cov=app --cov-report=term-missing

# Security scans
bandit -r app/ -ll
ruff check app/ tests/
pip-audit -r requirements.txt
semgrep scan --config=auto app/

# Container
docker build -t devsecops-flask-app:test .
trivy image devsecops-flask-app:test
```

### Google Cloud CLI

```bash
# Auth
gcloud auth login
gcloud config set project YOUR_PROJECT_ID
gcloud auth configure-docker us-central1-docker.pkg.dev

# Push image manually
docker tag myapp:test us-central1-docker.pkg.dev/PROJECT/devsecops-repo/flask-app:v1
docker push us-central1-docker.pkg.dev/PROJECT/devsecops-repo/flask-app:v1

# Deploy manually
gcloud run deploy flask-app --image=IMAGE_URL --region=us-central1

# Logs
gcloud run services logs read flask-app-prod --region=us-central1

# Secrets
echo -n 'value' | gcloud secrets versions add MY_SECRET --data-file=-
gcloud secrets versions access latest --secret=MY_SECRET

# Vulnerability scan results (Artifact Registry)
gcloud artifacts vulnerabilities list --filter='resourceUri=IMAGE_URL'
```

### GitHub Actions

```bash
# Trigger / monitor
gh workflow run security-monitor.yml
gh run list --workflow=ci.yml
gh run view <run-id> --log
gh run rerun <run-id>
gh run download <run-id>

# Tag and deploy
git tag v1.2.3 && git push origin v1.2.3
```

---

## Appendix B: Tool Version Matrix

| Tool | Purpose | Version | License |
|---|---|---|---|
| Ruff | Linting + formatting | 0.8.x | MIT |
| Bandit | Python SAST | 1.8.x | Apache 2.0 |
| Semgrep | Advanced SAST | Latest | LGPL 2.1 |
| Trivy | Container scanning | Latest | Apache 2.0 |
| Gitleaks | Secret detection | 8.21.x | MIT |
| Checkov | IaC scanning | Latest | Apache 2.0 |
| OWASP ZAP | DAST | Latest | Apache 2.0 |
| Cosign | Image signing | Latest | Apache 2.0 |
| pip-audit | Dependency audit | Latest | Apache 2.0 |
| anchore/sbom-action | SBOM generation | Latest | Apache 2.0 |

---

## Remaining Work (Priority Order)

1. **`.github/dependabot.yml`** — enable automated dependency PRs (Module 9.1)
2. **`.semgrep/flask-security.yml`** — custom Flask security rules (Module 5.1)
3. **`.gitleaks.toml`** — custom secret patterns + allowlist (Module 6.3)
4. **Branch protection rules** — enforce all 6 CI jobs as required checks (Module 10.1)
5. **`.github/CODEOWNERS`** — require security team review on workflows/Terraform/Dockerfile (Module 10.2)
6. **Signed commits** — GPG key setup (Module 10.3)
7. **DAST job** — OWASP ZAP against staging after deploy (Module 5.4)
8. **`terraform.tfvars`** — set real `project_id` and `github_repo` values, then `terraform apply`
9. **Populate Secret Manager** — add real DB URLs and secret keys after Terraform apply
