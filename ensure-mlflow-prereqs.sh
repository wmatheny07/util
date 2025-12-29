#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${1:?usage: ensure-mlflow-prereqs.sh /path/to/.env.runtime}"

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

: "${POSTGRES_CONTAINER:=postgres}"
: "${MINIO_CONTAINER:=minio}"
: "${DOCKER_NET:=core_data_net}"
: "${MLFLOW_DB_NAME:=mlflow}"
: "${MLFLOW_S3_BUCKET:=mlflow}"
: "${MINIO_S3_ENDPOINT:=http://minio:9000}"

# -------------------------
# Wait for Postgres
# -------------------------
echo "[mlflow] waiting for postgres..."
for i in {1..60}; do
  if docker exec "$POSTGRES_CONTAINER" pg_isready -U analytics >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

# -------------------------
# Ensure DB exists
# -------------------------
echo "[mlflow] ensuring postgres db exists: ${MLFLOW_DB_NAME}"
docker exec -e PGPASSWORD="${ANALYTICS_DB_PASSWORD}" "$POSTGRES_CONTAINER" \
  psql -U analytics -d postgres -tAc \
  "SELECT 1 FROM pg_database WHERE datname='${MLFLOW_DB_NAME}'" | grep -q 1 \
  || docker exec -e PGPASSWORD="${ANALYTICS_DB_PASSWORD}" "$POSTGRES_CONTAINER" \
     psql -U analytics -d postgres -c "CREATE DATABASE ${MLFLOW_DB_NAME};"

# -------------------------
# Wait for MinIO
# -------------------------
echo "[mlflow] waiting for minio..."
for i in {1..60}; do
  if docker exec "$MINIO_CONTAINER" sh -lc "wget -qO- http://127.0.0.1:9000/minio/health/ready >/dev/null 2>&1 || true"; then
    # If wget isn't present in minio container, we won't rely on it
    break
  fi
  sleep 2
done

# -------------------------
# Ensure bucket exists (idempotent)
# Uses minio/mc in a one-shot container attached to your docker network
# -------------------------
echo "[mlflow] ensuring minio bucket exists: ${MLFLOW_S3_BUCKET}"

docker run --rm --network "$DOCKER_NET" \
  -e MC_HOST_local="http://${MINIO_ROOT_USER}:${MINIO_ROOT_PASSWORD}@minio:9000" \
  minio/mc:latest \
  mb --ignore-existing "local/${MLFLOW_S3_BUCKET}"

echo "[mlflow] prereqs OK"
