#!/usr/bin/env bash
set -euo pipefail

# Migrates health-data files from:
#   health-data/{category}/json/file.json
# to:
#   health-data/{category}/json/wes/file.json

ENV_FILE="${1:?usage: migrate-minio-health-data.sh /path/to/.env.runtime}"
PERSON="${2:-wes}"
BUCKET="health-data"
DRY_RUN="${DRY_RUN:-false}"

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

: "${DOCKER_NET:?DOCKER_NET not set}"
: "${MINIO_ROOT_USER:?MINIO_ROOT_USER not set}"
: "${MINIO_ROOT_PASSWORD:?MINIO_ROOT_PASSWORD not set}"

MC="docker run --rm \
  --network ${DOCKER_NET} \
  --dns 127.0.0.11 \
  -e MC_HOST_minio=http://${MINIO_ROOT_USER}:${MINIO_ROOT_PASSWORD}@minio:9000 \
  minio/mc"

echo "▶ Scanning ${BUCKET} for json paths to migrate to .../{category}/json/${PERSON}/..."
echo "▶ DRY_RUN=${DRY_RUN}"

# List all objects under health-data/*/json/ that are NOT already under a person subfolder
while IFS= read -r line; do
  # mc ls --recursive outputs lines like: [date] [time] [size] path
  key=$(echo "$line" | awk '{print $NF}')

  # Skip if already under a person subfolder (json/something/file vs json/file)
  # Pattern we want to move: {category}/json/{file}  (no extra slash-segment after json/)
  if echo "$key" | grep -qP '^[^/]+/json/[^/]+$'; then
    category=$(echo "$key" | cut -d'/' -f1)
    filename=$(echo "$key" | cut -d'/' -f3)
    src="minio/${BUCKET}/${key}"
    dst="minio/${BUCKET}/${category}/json/${PERSON}/${filename}"

    if [[ "$DRY_RUN" == "true" ]]; then
      echo "  [dry-run] mv ${src} -> ${dst}"
    else
      echo "  ➡ mv ${src} -> ${dst}"
      $MC mv "$src" "$dst"
    fi
  fi
done < <($MC ls --recursive "minio/${BUCKET}" | awk '{print $NF}')

echo "✅ Migration complete"
