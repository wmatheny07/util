#!/usr/bin/env bash
# Weekly nginx image rebuild — pulls latest mainline base and upgrades OpenSSL.
# Run via cron: 0 2 * * 0 /opt/util/rebuild-nginx.sh >> /var/log/nginx-rebuild.log 2>&1
set -euo pipefail

COMPOSE=/opt/nginx/docker-compose.nginx.yml
LOG_PREFIX="[nginx-rebuild $(date -u '+%Y-%m-%dT%H:%M:%SZ')]"

echo "$LOG_PREFIX Starting weekly nginx image rebuild"

# Pull freshest base layer before build so --pull is honoured
docker pull nginx:mainline

# Rebuild image (no cache so apt-get update always fetches current packages)
docker-compose -f "$COMPOSE" build --no-cache nginx
echo "$LOG_PREFIX Build complete"

# Verify OpenSSL version in new image before deploying
OPENSSL_VER=$(docker run --rm ppd-nginx:latest openssl version)
echo "$LOG_PREFIX New image OpenSSL: $OPENSSL_VER"

# Zero-downtime replacement: compose replaces the container in-place
docker-compose -f "$COMPOSE" up -d --no-deps nginx
echo "$LOG_PREFIX Container restarted — done"
