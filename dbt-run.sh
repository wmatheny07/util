#!/usr/bin/env bash
# dbt-run.sh — run ad-hoc dbt commands with project defaults pre-configured
#
# Usage:
#   dbt-run.sh build --select fct_workout_summary --full-refresh
#   dbt-run.sh build --select +fct_workout_summary --full-refresh --docs
#   dbt-run.sh test --select "marts.health"
#   dbt-run.sh run --select "staging.health" --exclude vw_workouts
#   dbt-run.sh compile --select fct_resting_hr
#   dbt-run.sh -- ls --select "marts.health" --output name
#
# --docs is implied automatically when --full-refresh is present.

set -euo pipefail

DBT_STACK_DIR="/opt/ppd/stacks/dbt"
ENV_FILE="/opt/config/runtime/.env.all"
COMPOSE_FILE="$DBT_STACK_DIR/docker-compose.dbt.yml"
DBT_DOCS_DIR="/opt/dbt-docs"

BOLD='\033[1m'; CYAN='\033[0;36m'; GREEN='\033[0;32m'
YELLOW='\033[1;33m'; RED='\033[0;31m'; RESET='\033[0m'

if [[ $# -eq 0 ]]; then
  echo -e "${RED}No dbt command specified.${RESET}"
  echo ""
  echo "Usage: $(basename "$0") [--docs] <dbt-command> [dbt-args...]"
  echo ""
  echo "  --docs    Regenerate dbt docs after the command (auto-enabled with --full-refresh)"
  echo ""
  echo "Examples:"
  echo "  $(basename "$0") build --select +fct_workout_summary --full-refresh"
  echo "  $(basename "$0") build --select fct_resting_hr --full-refresh --docs"
  echo "  $(basename "$0") test --select \"marts.health\""
  echo "  $(basename "$0") run --select \"staging.health\""
  echo "  $(basename "$0") -- ls --select \"marts.health\" --output name"
  exit 1
fi

# Parse out --docs before passing remaining args to dbt
REGEN_DOCS=false
DBT_ARGS=()
for arg in "$@"; do
  if [[ "$arg" == "--docs" ]]; then
    REGEN_DOCS=true
  else
    DBT_ARGS+=("$arg")
  fi
done

# Strip leading '--' separator if present (allows passing dbt subcommands like ls)
[[ "${DBT_ARGS[0]:-}" == "--" ]] && DBT_ARGS=("${DBT_ARGS[@]:1}")

# Auto-enable docs on full-refresh
if printf '%s\n' "${DBT_ARGS[@]}" | grep -q '^--full-refresh$'; then
  REGEN_DOCS=true
fi

# Load runtime env (provides ANALYTICS_DB_PASSWORD etc.)
if [[ -f "$ENV_FILE" ]]; then
  set -a; source "$ENV_FILE"; set +a
else
  echo -e "${YELLOW}Warning: env file not found at $ENV_FILE — DB password may be missing${RESET}" >&2
fi

run_dbt() {
  docker-compose -f "$COMPOSE_FILE" run --rm --entrypoint bash -e DBT_TARGET=prod dbt -c "dbt $*"
}

echo -e "${BOLD}${CYAN}==> dbt ${DBT_ARGS[*]}${RESET}\n"
run_dbt "${DBT_ARGS[@]}"

if $REGEN_DOCS; then
  echo -e "\n${BOLD}${CYAN}==> Regenerating dbt docs${RESET}\n"
  run_dbt "docs generate"
  cp "$DBT_STACK_DIR/project/target/index.html"   "$DBT_DOCS_DIR/index.html"
  cp "$DBT_STACK_DIR/project/target/catalog.json"  "$DBT_DOCS_DIR/catalog.json"
  cp "$DBT_STACK_DIR/project/target/manifest.json" "$DBT_DOCS_DIR/manifest.json"
  echo -e "${GREEN}Docs updated at $DBT_DOCS_DIR${RESET}"
fi

echo -e "\n${BOLD}${GREEN}✓ Done.${RESET}\n"
