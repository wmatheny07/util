#!/usr/bin/env bash
set -euo pipefail

# Build two .env files from two groups of running containers.
#
# Example:
#   ./rebuild_env_split_stacks.sh \
#     --core-out  /opt/config/.env.core.recovered \
#     --core      postgres nginx airflow-webserver airflow-scheduler airflow-worker \
#     --manor-out /opt/config/.env.mathenymanor.recovered \
#     --manor     manor-web manor-api manor-db \
#     --dedupe manor
#
# --dedupe manor   => remove keys from manor env that are already in core env
# --dedupe core    => remove keys from core env that are already in manor env

SKIP_RE='^(PATH|HOSTNAME|HOME|PWD|SHLVL|TERM|LANG|LC_|PYTHONPATH|PYTHONUNBUFFERED|SHELL|USER|LOGNAME|_|GPG_|SSH_|OP_|DEBIAN_FRONTEND|TZ|KUBERNETES_)=|^S6_|^RUNIT_|^DUMB_INIT_'

CORE_OUT=""
MANOR_OUT=""
DEDUPE_TARGET=""  # "core" or "manor" or ""
CORE_CONTAINERS=()
MANOR_CONTAINERS=()

usage() {
  cat <<'EOF'
Usage:
  rebuild_env_split_stacks.sh \
    --core-out  /path/core.env  --core  <containers...> \
    --manor-out /path/manor.env --manor <containers...> \
    [--dedupe core|manor]

Notes:
- Later containers override earlier ones within the same group.
- --dedupe manor removes duplicate keys from manor that already appear in core (common desired behavior).
EOF
}

die(){ echo "❌ $*" >&2; exit 1; }

# -------------------------
# Parse args
# -------------------------
CORE_PROJECT=""
MANOR_PROJECT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --core-out)      CORE_OUT="${2:?missing}"; shift 2 ;;
    --manor-out)     MANOR_OUT="${2:?missing}"; shift 2 ;;
    --dedupe)        DEDUPE_TARGET="${2:?missing}"; shift 2 ;;

    --core-project)  CORE_PROJECT="${2:?missing}"; shift 2 ;;
    --manor-project) MANOR_PROJECT="${2:?missing}"; shift 2 ;;

    --core)
      shift
      while [[ $# -gt 0 && "$1" != --manor* && "$1" != --core* && "$1" != --core-out && "$1" != --manor-out && "$1" != --dedupe ]]; do
        CORE_CONTAINERS+=("$1"); shift
      done
      ;;

    --manor)
      shift
      while [[ $# -gt 0 && "$1" != --core* && "$1" != --manor* && "$1" != --core-out && "$1" != --manor-out && "$1" != --dedupe ]]; do
        MANOR_CONTAINERS+=("$1"); shift
      done
      ;;

    -h|--help) usage; exit 0 ;;
    *) die "Unknown arg: $1" ;;
  esac
done

containers_for_project() {
  local project="$1"
  docker ps \
    --filter "label=com.docker.compose.project=${project}" \
    --format '{{.Names}}'
}

if [[ ${#CORE_CONTAINERS[@]} -eq 0 && -n "$CORE_PROJECT" ]]; then
  mapfile -t CORE_CONTAINERS < <(containers_for_project "$CORE_PROJECT")
fi

if [[ ${#MANOR_CONTAINERS[@]} -eq 0 && -n "$MANOR_PROJECT" ]]; then
  mapfile -t MANOR_CONTAINERS < <(containers_for_project "$MANOR_PROJECT")
fi

[[ -n "$CORE_OUT"  ]] || die "Missing --core-out"
[[ -n "$MANOR_OUT" ]] || die "Missing --manor-out"
[[ ${#CORE_CONTAINERS[@]}  -gt 0 ]] || die "No containers provided after --core"
[[ ${#MANOR_CONTAINERS[@]} -gt 0 ]] || die "No containers provided after --manor"
[[ -z "$DEDUPE_TARGET" || "$DEDUPE_TARGET" == "core" || "$DEDUPE_TARGET" == "manor" ]] || die "--dedupe must be 'core' or 'manor'"

# -------------------------
# Helpers
# -------------------------
backup_if_exists() {
  local f="$1"
  if [[ -e "$f" ]]; then
    cp -a "$f" "${f}.bak.$(date +%Y%m%d%H%M%S)"
    echo "🧷 Backed up existing $f to ${f}.bak.*" >&2
  fi
}

# Writes env file from container list; also outputs a "keys file" for dedupe
write_env_from_containers() {
  local out="$1"; shift
  local keys_out="$1"; shift
  local label="$1"; shift
  local -a containers=("$@")

  declare -A KV=()

  for c in "${containers[@]}"; do
    if ! docker inspect "$c" >/dev/null 2>&1; then
      echo "⚠️  [$label] Skipping (not found): $c" >&2
      continue
    fi

    echo "▶ [$label] Reading env from: $c" >&2

    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      if [[ "$line" =~ $SKIP_RE ]]; then
        continue
      fi

      local key="${line%%=*}"
      local val="${line#*=}"

      # keep exact value; escape newlines for env-file safety
      val="${val//$'\n'/\\n}"
      KV["$key"]="$val"
    done < <(docker inspect "$c" --format '{{range .Config.Env}}{{println .}}{{end}}')
  done

  local tmp
  tmp="$(mktemp)"
  {
    echo "# Recovered env ($label) generated on $(date -Is)"
    echo "# Source containers: ${containers[*]}"
    echo
    for k in "${!KV[@]}"; do echo "$k"; done | sort | while read -r k; do
      v="${KV[$k]}"

      if [[ "$v" =~ [[:space:]\#\'\"] ]]; then
        v="${v//\\/\\\\}"
        v="${v//\"/\\\"}"
        echo "${k}=\"${v}\""
      else
        echo "${k}=${v}"
      fi
    done
  } > "$tmp"

  backup_if_exists "$out"
  install -m 600 "$tmp" "$out"
  rm -f "$tmp"

  # keys for dedupe
  awk -F= '/^[A-Za-z_][A-Za-z0-9_]*=/{print $1}' "$out" | sort -u > "$keys_out"

  echo "✅ [$label] Wrote: $out" >&2
}

dedupe_env() {
  local target_env="$1"
  local target_label="$2"
  local remove_keys_file="$3"

  echo "▶ Dedupe: removing keys from $target_label that exist in $(basename "$remove_keys_file")" >&2

  local tmp
  tmp="$(mktemp)"

  # Remove any KEY= lines where KEY is in remove_keys_file
  awk -F= 'NR==FNR{rm[$1]=1; next}
           /^[A-Za-z_][A-Za-z0-9_]*=/{ if(rm[$1]) next }
           { print }' \
    "$remove_keys_file" "$target_env" > "$tmp"

  backup_if_exists "$target_env"
  install -m 600 "$tmp" "$target_env"
  rm -f "$tmp"

  echo "✅ Dedupe complete for $target_label: $target_env" >&2
}

# -------------------------
# Build both
# -------------------------
core_keys="$(mktemp)"
manor_keys="$(mktemp)"
trap 'rm -f "$core_keys" "$manor_keys"' EXIT

write_env_from_containers "$CORE_OUT"  "$core_keys"  "core"  "${CORE_CONTAINERS[@]}"
write_env_from_containers "$MANOR_OUT" "$manor_keys" "manor" "${MANOR_CONTAINERS[@]}"

# Optional dedupe
if [[ "$DEDUPE_TARGET" == "manor" ]]; then
  dedupe_env "$MANOR_OUT" "manor" "$core_keys"
elif [[ "$DEDUPE_TARGET" == "core" ]]; then
  dedupe_env "$CORE_OUT" "core" "$manor_keys"
fi

echo "🎉 Done."
echo "  core : $CORE_OUT"
echo "  manor: $MANOR_OUT"
