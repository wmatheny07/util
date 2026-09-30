#!/usr/bin/env bash
# Render ESPHome secrets.yaml from 1Password (vault: mathenymanor, item: ESPHome).
set -euo pipefail
source <(sudo cat /etc/1password/op-service-account.env)

TEMPLATE=/opt/config/esphome-secrets.yaml
OUT=/opt/mathenymanor/volumes/esphome/secrets.yaml

mkdir -p "$(dirname "$OUT")"
op inject -f -i "$TEMPLATE" -o "$OUT"
chmod 600 "$OUT"
echo "Wrote $OUT"
