#!/usr/bin/env bash

wait_for_minio() {
  local url="http://minio:9000/minio/health/ready"
  echo "⏳ Waiting for MinIO at $url (via docker network: $DOCKER_NET)..."
  until docker run --rm --network "$DOCKER_NET" curlimages/curl:8.5.0 \
      -fsS "$url" >/dev/null; do
    sleep 2
  done
  echo "✅ MinIO is ready"
}

set -euo pipefail

echo "▶ Ensuring MinIO buckets exist..."

ENV_FILE="${1:?usage: ensure-minio-buckets.sh /path/to/.env.runtime}"

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

MC="docker run --rm \
  --network ${DOCKER_NET} \
  --dns 127.0.0.11 \
  minio/mc"

# Required env vars (fail fast if missing)
: "${MINIO_ENDPOINT:?MINIO_ENDPOINT not set}"
: "${MINIO_ROOT_USER:?MINIO_ROOT_USER not set}"
: "${MINIO_ROOT_PASSWORD:?MINIO_ROOT_PASSWORD not set}"

# Optional but recommended
MINIO_ALIAS=${MINIO_ALIAS:-minio}
MINIO_REGION=${MINIO_REGION:-us-east-1}

# Buckets (add/remove as needed)
BUCKETS=(
  "${MINIO_BUCKET_MLFLOW:-mlflow-artifacts}"
  "${MINIO_BUCKET_SUPERSET:-superset}"
  "${MINIO_BUCKET_DATA:-raw-data}"
)

# Wait for MinIO to be ready
wait_for_minio

# Configure mc alias (idempotent)
mc alias set "${MINIO_ALIAS}" \
  "${MINIO_ENDPOINT}" \
  "${MINIO_ROOT_USER}" \
  "${MINIO_ROOT_PASSWORD}" \
  --api S3v4

# Create buckets if missing
for bucket in "${BUCKETS[@]}"; do
  if $MC ls "${MINIO_ALIAS}/${bucket}" >/dev/null 2>&1; then
    echo "✔ Bucket exists: ${bucket}"
  else
    echo "➕ Creating bucket: ${bucket}"
    $MC mb --region "${MINIO_REGION}" "${MINIO_ALIAS}/${bucket}"
  fi
done

# Enable versioning (safe to re-run)
for bucket in "${BUCKETS[@]}"; do
  $MC version enable "${MINIO_ALIAS}/${bucket}" >/dev/null 2>&1 || true
done

echo "🎉 MinIO ensure complete"
