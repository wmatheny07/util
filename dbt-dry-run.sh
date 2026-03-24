#!/usr/bin/env bash
# dbt-dry-run.sh — list and compile dbt models without executing them

set -euo pipefail

DBT_STACK_DIR="/opt/ppd/stacks/dbt"
ENV_FILE="/opt/config/runtime/.env.all"
COMPOSE_FILE="$DBT_STACK_DIR/docker-compose.dbt.yml"
COMPILED_DIR="$DBT_STACK_DIR/project/target/compiled/analytics/models"

BOLD='\033[1m'; CYAN='\033[0;36m'; GREEN='\033[0;32m'
YELLOW='\033[1;33m'; RED='\033[0;31m'; RESET='\033[0m'

SELECT="staging.health marts.health"
EXCLUDE=""
FULL_REFRESH=false
SHOW_SQL=false

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

List and compile dbt models without executing them.

Options:
  -s, --select <selector>   dbt node selector  (default: "staging.health marts.health")
  -e, --exclude <selector>  dbt node exclusion
      --full-refresh        compile incrementals as full-refresh (shows full INSERT vs. merge SQL)
      --show-sql            print each model's compiled SQL after compile
  -h, --help                show this help

Examples:
  $(basename "$0")
  $(basename "$0") -s fct_resting_hr --show-sql
  $(basename "$0") -s "tag:health" -e "tag:staging"
  $(basename "$0") -s "marts.health" --full-refresh --show-sql
EOF
}

while [[ $# -gt 0 ]]; do
  case $1 in
    -s|--select)    SELECT="$2"; shift 2 ;;
    -e|--exclude)   EXCLUDE="$2"; shift 2 ;;
    --full-refresh) FULL_REFRESH=true; shift ;;
    --show-sql)     SHOW_SQL=true; shift ;;
    -h|--help)      usage; exit 0 ;;
    *) echo -e "${RED}Unknown option: $1${RESET}" >&2; usage; exit 1 ;;
  esac
done

# Load runtime env (provides ANALYTICS_DB_PASSWORD etc.)
if [[ -f "$ENV_FILE" ]]; then
  set -a; source "$ENV_FILE"; set +a
else
  echo -e "${YELLOW}Warning: env file not found at $ENV_FILE${RESET}" >&2
fi

# Build shared selector flags
SELECTOR_FLAGS="--select $SELECT"
[[ -n "$EXCLUDE" ]] && SELECTOR_FLAGS+=" --exclude $EXCLUDE"
$FULL_REFRESH && SELECTOR_FLAGS+=" --full-refresh"

run_dbt() {
  docker-compose -f "$COMPOSE_FILE" run --rm --entrypoint bash -e DBT_TARGET=prod dbt -c "$*"
}

# ── 1. List matched models ────────────────────────────────────────────────────
echo -e "\n${BOLD}${CYAN}==> Listing matched models${RESET}"

RAW=$(run_dbt "dbt ls $SELECTOR_FLAGS --output name 2>&1" || true)
# dbt ls outputs node names like "analytics.marts.health.fct_resting_hr";
# filter out dbt's own info/warning lines
MODELS=$(echo "$RAW" | grep -E '^analytics\.' || true)
COUNT=$(echo "$MODELS" | grep -c '[^[:space:]]' || true)

if [[ "$COUNT" -eq 0 ]]; then
  echo -e "${RED}No models matched selector \"$SELECT\".${RESET}"
  echo "Raw dbt output:"
  echo "$RAW" | sed 's/^/  /'
  exit 1
fi

echo -e "${GREEN}${COUNT} model(s) matched:${RESET}"
echo "$MODELS" | sed 's/^/  /'

# ── 2. Compile ────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}${CYAN}==> Compiling (no execution)${RESET}"
if $FULL_REFRESH; then
  echo -e "  ${YELLOW}--full-refresh active: incrementals compiled as full table replacements${RESET}"
fi

run_dbt "dbt compile $SELECTOR_FLAGS"
echo -e "${GREEN}Compilation successful.${RESET}"

# ── 3. Optionally show compiled SQL ──────────────────────────────────────────
if $SHOW_SQL; then
  echo -e "\n${BOLD}${CYAN}==> Compiled SQL${RESET}"
  while IFS= read -r node; do
    [[ -z "$node" ]] && continue
    model_name="${node##*.}"
    sql_file=$(find "$COMPILED_DIR" -name "${model_name}.sql" 2>/dev/null | head -1)
    if [[ -n "$sql_file" ]]; then
      rel_path="${sql_file#"$DBT_STACK_DIR/"}"
      echo -e "\n${BOLD}${YELLOW}┌── ${model_name}  (${rel_path})${RESET}"
      sed 's/^/│  /' "$sql_file"
      echo -e "${YELLOW}└──${RESET}"
    else
      echo -e "\n  ${YELLOW}(compiled file not found for ${model_name})${RESET}"
    fi
  done <<< "$MODELS"
fi

echo -e "\n${BOLD}${GREEN}✓ Dry run complete — no models were executed.${RESET}\n"
