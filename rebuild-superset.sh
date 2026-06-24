#!/usr/bin/env bash
# Weekly superset-with-playwright rebuild — picks up latest Chromium from Debian 12
# and fresh Playwright browser bundle. Run via cron:
# 0 3 * * 0 /opt/util/rebuild-superset.sh >> /var/log/superset-rebuild.log 2>&1
set -euo pipefail

CORE_COMPOSE=/opt/ppd/stacks/core/docker-compose.core.yml
ENV_FILE=/opt/config/runtime/.env.all
LOG_PREFIX="[superset-rebuild $(date -u '+%Y-%m-%dT%H:%M:%SZ')]"

echo "$LOG_PREFIX Starting weekly superset image rebuild"

# Pull freshest apache/superset base
docker pull apache/superset:latest

# Build superset-with-pg (system Chromium layer)
docker build --no-cache --pull \
  -f /opt/ppd/stacks/core/dockerfile.superset \
  -t superset-with-pg:latest \
  /opt/ppd/stacks/core/
echo "$LOG_PREFIX superset-with-pg built"

# Verify Chromium version
CHROME_VER=$(docker run --rm superset-with-pg:latest dpkg-query -W -f='${Version}' chromium)
echo "$LOG_PREFIX System Chromium: $CHROME_VER"

# Build superset-with-playwright (Playwright + bundled Chromium layer)
docker build --no-cache \
  -t superset-with-playwright:latest \
  /opt/ppd/stacks/superset/
echo "$LOG_PREFIX superset-with-playwright built"

# Rolling restart — beat first (stateless), then worker, then webserver
docker-compose -f "$CORE_COMPOSE" --env-file "$ENV_FILE" \
  up -d --no-deps superset-beat superset-worker superset
echo "$LOG_PREFIX Containers restarted — done"
