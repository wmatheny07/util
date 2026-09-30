#!/usr/bin/env bash

set -euo pipefail
source <(sudo cat /etc/1password/op-service-account.env)

DELETE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -e|--env)  RUNTIME_ENV="${2:?missing value for $1}"; shift 2 ;;
    -d|--delete)
      DELETE=true
      shift
      ;;
    --) shift; break ;;
    *) break ;;
  esac
done

op inject -i /opt/config/.env -o $RUNTIME_ENV

if $DELETE; then
  rm $RUNTIME_ENV
fi