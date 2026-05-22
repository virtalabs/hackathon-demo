#!/usr/bin/env bash
# Runs on: host (repo root)
# Invoked by: just check
set -euo pipefail

if [ "$SERVICE" = "blueflow" ]; then
  echo "==> $SERVICE (http://localhost:8000/api/assets/)"
  curl -sS -H "Authorization: Token ${BLUEFLOW_API_TOKEN}" \
    http://localhost:8000/api/assets/ | jq .
  echo ""
elif [ "$SERVICE" = "viper" ]; then
  if [ -z "${VIPER_API_KEY:-}" ]; then
    echo "==> Viper: skipped (VIPER_API_KEY not set)"
    echo "Run:  docker compose exec viper npm run db:create-test-api-key"
    echo "Then: export VIPER_API_KEY=<key printed above>"
    exit 1
  fi
  echo "==> Viper (http://localhost:3000/api/v1/assets)"
  viper_body=$(curl -sS -H "Authorization: Bearer ${VIPER_API_KEY}" \
    "http://localhost:3000/api/v1/assets?pageSize=100")
  if echo "${viper_body}" | jq -e '.code' >/dev/null 2>&1; then
    echo "ERROR: Viper API: $(echo "${viper_body}" | jq -r '.message')" >&2
    echo "Regenerate: docker compose exec viper npm run db:create-test-api-key" >&2
    exit 1
  fi
  echo "${viper_body}" | jq .
  echo ""
else
  echo "Invalid service: $SERVICE" >&2
  exit 1
fi