#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./rebuild_env_from_containers.sh /opt/config/.env.recovered postgres airflow-webserver airflow-scheduler airflow-worker espn-web espn-celery
#
# Notes:
# - Later containers override earlier ones for duplicate keys.
# - We skip a bunch of noisy/system vars by default.

OUT="${1:-}"
shift || true

if [[ -z "${OUT}" ]]; then
  echo "Usage: $0 /path/to/output.env <container1> [container2 ...]" >&2
  exit 1
fi

if [[ $# -lt 1 ]]; then
  echo "Provide at least one running container name/id." >&2
  exit 1
fi

# Filter out noisy vars (tune as you like)
SKIP_RE='^(PATH|HOSTNAME|HOME|PWD|SHLVL|TERM|LANG|LC_|PYTHONPATH|PYTHONUNBUFFERED|SHELL|USER|LOGNAME|_|GPG_|SSH_|OP_|DEBIAN_FRONTEND|TZ|KUBERNETES_)=|^S6_|^RUNIT_|^DUMB_INIT_'

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

declare -A KV

for c in "$@"; do
  if ! docker inspect "$c" >/dev/null 2>&1; then
    echo "⚠️  Skipping (not found): $c" >&2
    continue
  fi

  echo "▶ Reading env from container: $c" >&2

  # This prints one env entry per line: KEY=VALUE
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if [[ "$line" =~ $SKIP_RE ]]; then
      continue
    fi

    key="${line%%=*}"
    val="${line#*=}"

    # Keep exact value; escape newlines for .env file safety
    val="${val//$'\n'/\\n}"

    KV["$key"]="$val"
  done < <(docker inspect "$c" --format '{{range .Config.Env}}{{println .}}{{end}}')
done

# Write deterministic output
{
  echo "# Recovered env generated on $(date -Is)"
  echo "# Source containers: $*"
  echo

  # sort keys
  for k in "${!KV[@]}"; do echo "$k"; done | sort | while read -r k; do
    v="${KV[$k]}"

    # Quote if it contains spaces or special chars (basic)
    if [[ "$v" =~ [[:space:]\#\'\"] ]]; then
      # use double quotes; escape existing quotes/backslashes
      v="${v//\\/\\\\}"
      v="${v//\"/\\\"}"
      echo "${k}=\"${v}\""
    else
      echo "${k}=${v}"
    fi
  done
} > "$tmp"

# Safety: don’t overwrite an existing file unless you mean it
if [[ -e "$OUT" ]]; then
  cp -a "$OUT" "${OUT}.bak.$(date +%Y%m%d%H%M%S)"
  echo "🧷 Backed up existing $OUT to ${OUT}.bak.*" >&2
fi

install -m 600 "$tmp" "$OUT"
echo "✅ Wrote recovered env to: $OUT"
