#!/usr/bin/env bash
set -euo pipefail

source ~/miniconda3/etc/profile.d/conda.sh

NGINX_TEMPLATE="/opt/nginx/nginx.conf.template"
NGINX_RENDERED="/opt/nginx/nginx.conf"
KEEP_ENV=false

usage() {
  cat <<'EOF'
Usage:
  stack.sh -f compose.yml [-f override.yml ...] -e /tmp/runtime.env [-p project] <cmd> [services...]

Commands:
  up [services...]        Bring up whole stack (no services) or only listed services
  down                    Bring down the stack (project)
  stop <services...>      Stop specific services
  restart <services...>   Restart specific services
  logs [service]          Follow logs for stack or one service
  ps                      Show status
  -k, --keep-env          Do not delete the injected runtime env file at the end

Examples:
  stack.sh -f core.yml -e /tmp/core.env -p core up
  stack.sh -f core.yml -e /tmp/core.env -p core up mlflow
  stack.sh -f core.yml -e /tmp/core.env -p core down
  stack.sh -f core.yml -e /tmp/core.env -p core stop superset
  stack.sh -f core.yml -e /tmp/core.env -p core restart nginx mlflow
  stack.sh -f core.yml -e /tmp/core.env -p core logs mlflow
EOF
}

# --- Postgres: ensure application databases exist (idempotent) ---
ensure_postgres_dbs() {
  # Load runtime env vars into this shell (so $POSTGRES_CONTAINER, etc. exist)
  set -a
  # shellcheck disable=SC1090
  source "$RUNTIME_ENV"
  set +a

  local pg_container="${POSTGRES_CONTAINER:-postgres}"

  # role used to connect (must have CREATEDB or be superuser)
  local pg_user="${POSTGRES_USER:-analytics}"

  # Who should own the app DBs?
  local owner="${POSTGRES_APP_OWNER:-${POSTGRES_USER:-analytics}}"

  # Which DBs should exist?
  local dbs=()
  if [[ -n "${POSTGRES_APP_DBS:-}" ]]; then
    read -r -a dbs <<< "${POSTGRES_APP_DBS}"
  else
    [[ -n "${METABASE_DB_NAME:-}" ]] && dbs+=("${METABASE_DB_NAME}")
    [[ -n "${AIRFLOW_DB_NAME:-}"   ]] && dbs+=("${AIRFLOW_DB_NAME}")
    [[ -n "${MLFLOW_DB_NAME:-}"    ]] && dbs+=("${MLFLOW_DB_NAME}")
    [[ -n "${SUPERSET_DB_NAME:-}"  ]] && dbs+=("${SUPERSET_DB_NAME}")
    [[ -n "${ESPN_DB_NAME:-}"      ]] && dbs+=("${ESPN_DB_NAME}")

    [[ ${#dbs[@]} -eq 0 ]] && dbs=(metabase airflow mlflow superset)
  fi

  echo "▶ Ensuring Postgres DBs exist (container=${pg_container}, user=${pg_user}, owner=${owner}): ${dbs[*]}"

  for db in "${dbs[@]}"; do
    [[ -z "$db" ]] && continue

    # Check from maintenance DB
    if docker exec -i "${pg_container}" psql -U "${pg_user}" -d postgres -tAc \
        "SELECT 1 FROM pg_database WHERE datname='${db}'" | grep -q 1; then
      echo "✅ DB exists: ${db}"
      continue
    fi

    echo "➕ Creating DB: ${db}"
    docker exec -i "${pg_container}" psql -U "${pg_user}" -d postgres -v ON_ERROR_STOP=1 -c \
      "CREATE DATABASE \"${db}\";"

    # Set owner (safe even if CREATE DATABASE defaulted differently)
    docker exec -i "${pg_container}" psql -U "${pg_user}" -d postgres -v ON_ERROR_STOP=1 -c \
      "ALTER DATABASE \"${db}\" OWNER TO \"${owner}\";"
  done
}

# --- pick compose binary (docker compose preferred) ---
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  COMPOSE_BIN=("docker" "compose")
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE_BIN=("docker-compose")
else
  echo "❌ Neither 'docker compose' nor 'docker-compose' found" >&2
  exit 1
fi

COMPOSE_FILES=()
PROJECT=""
RUNTIME_ENV=""

# Parse flags
while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--file) COMPOSE_FILES+=("${2:?missing value for $1}"); shift 2 ;;
    -e|--env)  RUNTIME_ENV="${2:?missing value for $1}"; shift 2 ;;
    -p|--project) PROJECT="${2:?missing value for $1}"; shift 2 ;;
    -k|--keep-env) KEEP_ENV=true; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    *) break ;;
  esac
done

CMD="${1:-}"
shift || true
SERVICES=("$@")

if [[ -z "$CMD" ]]; then
  echo "❌ Missing command" >&2
  usage
  exit 1
fi

if [[ ${#COMPOSE_FILES[@]} -eq 0 ]]; then
  echo "❌ You must supply at least one compose file with -f" >&2
  exit 1
fi

if [[ -z "$RUNTIME_ENV" ]]; then
  echo "❌ You must supply a runtime env output path with -e" >&2
  exit 1
fi

for f in "${COMPOSE_FILES[@]}"; do
  [[ -f "$f" ]] || { echo "❌ Compose file not found: $f" >&2; exit 1; }
done

if [[ -z "$PROJECT" ]]; then
  PROJECT="$(basename "$(dirname "${COMPOSE_FILES[0]}")")"
fi

# Load 1Password and inject env (always, so compose interpolation works consistently)
# Load 1Password and inject env (always, so compose interpolation works consistently)
ENV_TEMPLATE="/opt/config/.env"
ENV_PARTS_DIR="/opt/config/project"

rebuild_env_template() {
  mkdir -p "$(dirname "$ENV_TEMPLATE")"

  # Only include files you explicitly intend (example: core.env, manor.env, secrets.env, etc.)
  # Adjust this list to match what you actually store in /opt/config/project/
  local parts=(
    "$ENV_PARTS_DIR/core.env"
    "$ENV_PARTS_DIR/manor.env"
    "$ENV_PARTS_DIR/shared.env"
    "$ENV_PARTS_DIR/secrets.env"
  )

  echo "▶ Rebuilding $ENV_TEMPLATE from parts in $ENV_PARTS_DIR"

  : > "$ENV_TEMPLATE"  # truncate/create
  for p in "${parts[@]}"; do
    if [[ -f "$p" ]]; then
      echo "  - adding $(basename "$p")"
      cat "$p" >> "$ENV_TEMPLATE"
      echo "" >> "$ENV_TEMPLATE"
    else
      echo "  - skipping missing $(basename "$p")"
    fi
  done

  if [[ ! -s "$ENV_TEMPLATE" ]]; then
    echo "❌ Rebuilt $ENV_TEMPLATE is empty. Check $ENV_PARTS_DIR parts list." >&2
    exit 1
  fi
}

# Rebuild template if missing (or force rebuild by setting REBUILD_ENV=1)
# Load 1Password and inject env (always, so compose interpolation works consistently)
ENV_TEMPLATE="/opt/config/.env"
ENV_PARTS_DIR="/opt/config/project"

rebuild_env_template() {
  mkdir -p "$(dirname "$ENV_TEMPLATE")"

  # Only include files you explicitly intend (example: core.env, manor.env, secrets.env, etc.)
  # Adjust this list to match what you actually store in /opt/config/project/
  local parts=(
    "$ENV_PARTS_DIR/.env.core"
    "$ENV_PARTS_DIR/.env.mathenymanor"
  )

  echo "▶ Rebuilding $ENV_TEMPLATE from parts in $ENV_PARTS_DIR"

  : > "$ENV_TEMPLATE"  # truncate/create
  for p in "${parts[@]}"; do
    if [[ -f "$p" ]]; then
      echo "  - adding $(basename "$p")"
      cat "$p" >> "$ENV_TEMPLATE"
      echo "" >> "$ENV_TEMPLATE"
    else
      echo "  - skipping missing $(basename "$p")"
    fi
  done

  if [[ ! -s "$ENV_TEMPLATE" ]]; then
    echo "❌ Rebuilt $ENV_TEMPLATE is empty. Check $ENV_PARTS_DIR parts list." >&2
    exit 1
  fi
}

# Rebuild template if missing (or force rebuild by setting REBUILD_ENV=1)
if [[ ! -f "$ENV_TEMPLATE" || "${REBUILD_ENV:-0}" == "1" ]]; then
  rebuild_env_template
fi

source <(sudo cat /etc/1password/op-service-account.env)
op inject -i "$ENV_TEMPLATE" -o "$RUNTIME_ENV"

render_nginx_conf() {
  [[ -f "$NGINX_TEMPLATE" ]] || return 0

  echo "▶ Rendering nginx config: $NGINX_TEMPLATE -> $NGINX_RENDERED"
  conda activate py_3.7
  python3 /opt/util/env-inject.py "$NGINX_TEMPLATE" "$NGINX_RENDERED" "$RUNTIME_ENV"
}

# Load runtime env vars into this shell
set -a
# shellcheck disable=SC1090
source "$RUNTIME_ENV"
set +a

# --- Docker network selection ---
# Prefer explicit DOCKER_NET from env, otherwise infer from project
if [[ -z "${DOCKER_NET:-}" ]]; then
  if docker network inspect core_data_net >/dev/null 2>&1; then
    DOCKER_NET="core_data_net"
  elif docker network inspect "${PROJECT}_default" >/dev/null 2>&1; then
    DOCKER_NET="${PROJECT}_default"
  else
    echo "❌ DOCKER_NET not set and no suitable docker network found" >&2
    docker network ls >&2
    exit 1
  fi
fi

export DOCKER_NET
echo "▶ Using Docker network: $DOCKER_NET"

# Build -f args
FILE_ARGS=()
for f in "${COMPOSE_FILES[@]}"; do FILE_ARGS+=("-f" "$f"); done

# helper: service exists in compose config
has_service() {
  local svc="$1"
  "${COMPOSE_BIN[@]}" "${FILE_ARGS[@]}" -p "$PROJECT" --env-file "$RUNTIME_ENV" config --services \
    | grep -qx "$svc"
}

# Validate services if provided (nice UX)
if [[ ${#SERVICES[@]} -gt 0 ]]; then
  for s in "${SERVICES[@]}"; do
    if ! has_service "$s"; then
      echo "❌ Service '$s' not found in compose config" >&2
      echo "Available services:" >&2
      "${COMPOSE_BIN[@]}" "${FILE_ARGS[@]}" -p "$PROJECT" --env-file "$RUNTIME_ENV" config --services >&2
      exit 1
    fi
  done
fi

echo "▶ Project: $PROJECT"
echo "▶ Command: $CMD ${SERVICES[*]:-}"
echo "▶ Compose: ${COMPOSE_BIN[*]}"

# --- execute command ---
case "$CMD" in
  up)
    # bring up stack or specific services
    render_nginx_conf
    "${COMPOSE_BIN[@]}" "${FILE_ARGS[@]}" -p "$PROJECT" --env-file "$RUNTIME_ENV" up -d "${SERVICES[@]}"

    # Only run hooks when bringing up the whole stack (no specific service list)
    if [[ ${#SERVICES[@]} -eq 0 ]]; then
      echo "▶ Post-up hooks"
      if has_service postgres; then
        echo "  - ensure postgres app databases"
        ensure_postgres_dbs
      fi
      if has_service superset; then
        echo "  - ensure superset"
        bash /opt/util/ensure-superset.sh "$RUNTIME_ENV"
      fi
      if has_service mlflow; then
        echo "  - ensure mlflow prereqs"
        bash /opt/util/ensure-mlflow-prereqs.sh "$RUNTIME_ENV"
      fi
      if has_service minio; then
        echo "  - ensure minio buckets"
        bash /opt/util/ensure-minio-buckets.sh "$RUNTIME_ENV"
      fi
      if has_service nginx; then
        echo "▶ Validating nginx config"
        docker exec -it nginx nginx -t || true

        echo "▶ Reloading nginx"
        docker exec -it nginx nginx -s reload || true
      fi
    else
      echo "▶ Skipping post-up hooks (service-specific up)"
    fi
    ;;

  down)
    # down is stack-wide (compose doesn’t support down per-service)
    "${COMPOSE_BIN[@]}" "${FILE_ARGS[@]}" -p "$PROJECT" --env-file "$RUNTIME_ENV" down
    ;;

  stop)
    if [[ ${#SERVICES[@]} -eq 0 ]]; then
      echo "❌ stop requires one or more services" >&2
      exit 1
    fi
    "${COMPOSE_BIN[@]}" "${FILE_ARGS[@]}" -p "$PROJECT" --env-file "$RUNTIME_ENV" stop "${SERVICES[@]}"
    ;;

  restart)
    if [[ ${#SERVICES[@]} -eq 0 ]]; then
      echo "❌ restart requires one or more services" >&2
      exit 1
    fi
    render_nginx_conf
    "${COMPOSE_BIN[@]}" "${FILE_ARGS[@]}" -p "$PROJECT" --env-file "$RUNTIME_ENV" restart "${SERVICES[@]}"
    ;;

  logs)
    # logs can be stack-wide or per-service
    "${COMPOSE_BIN[@]}" "${FILE_ARGS[@]}" -p "$PROJECT" --env-file "$RUNTIME_ENV" logs -f "${SERVICES[@]}"
    ;;

  ps)
    "${COMPOSE_BIN[@]}" "${FILE_ARGS[@]}" -p "$PROJECT" --env-file "$RUNTIME_ENV" ps
    ;;
  
  recreate)
    render_nginx_conf
    "${COMPOSE_BIN[@]}" "${FILE_ARGS[@]}" -p "$PROJECT" --env-file "$RUNTIME_ENV" \
      up -d --force-recreate "${SERVICES[@]}"
    ;;

  rebuild)
    render_nginx_conf
    "${COMPOSE_BIN[@]}" "${FILE_ARGS[@]}" -p "$PROJECT" --env-file "$RUNTIME_ENV" \
      up -d --build --force-recreate "${SERVICES[@]}"
    ;;

  nuke)
    echo "⚠️  NUKING project '$PROJECT' (down -v --remove-orphans)"
    "${COMPOSE_BIN[@]}" "${FILE_ARGS[@]}" -p "$PROJECT" --env-file "$RUNTIME_ENV" \
      down -v --remove-orphans
    ;;

  *)
    echo "❌ Unknown command: $CMD" >&2
    usage
    exit 1
    ;;
esac

if [[ "$KEEP_ENV" == "true" ]]; then
  echo "✅ Done (kept env file: $RUNTIME_ENV)"
else
  rm -f "$RUNTIME_ENV"
  echo "✅ Done (deleted env file)"
fi

echo "✅ Done"