#!/usr/bin/env bash
# Stream InventoryRecord JSON from tapirxl container logs to stdout (line-at-a-time).
# Invoked by: just demo
set -euo pipefail

docker compose logs -f --no-log-prefix tapirxl 2>&1 | while IFS= read -r line; do
  case "$line" in
    '{'*)
      printf '%s\n' "$line" | jq --unbuffered -c .
      ;;
  esac
done
