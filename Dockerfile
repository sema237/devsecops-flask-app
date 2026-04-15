# ---- Build Stage ----
FROM python:3.13-slim AS builder
WORKDIR /build
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt
# ---- Production Stage ----
FROM python:3.13-slim
# SECURITY: Run as non-root user
RUN groupadd -r appuser && useradd -r -g appuser appuser


WORKDIR /app
COPY --from=builder /install /usr/local
COPY app/ ./app/
COPY migrations/ ./migrations/


# SECURITY: No root, read-only filesystem where possible
USER appuser
EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=3s \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/api/v1/health')"


CMD ["gunicorn", "--bind", "0.0.0.0:8000", "--workers", "4", "--access-logfile", "-", "app:create_app('production')"]
