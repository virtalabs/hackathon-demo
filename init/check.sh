#!/usr/bin/env bash
# Runs on: host (repo root)
# Invoked by: just check
set -euo pipefail

if [ "$SERVICE" = "blueflow" ]; then
  curl -sS -H "Authorization: Token ${BLUEFLOW_API_TOKEN}" \
    http://localhost:8000/api/assets/ | jq '[.results[] | {hostname,ip_address,mac_address,manufacturer,model}]'
elif [ "$SERVICE" = "viper" ]; then
  if [ -z "${VIPER_API_KEY:-}" ]; then
    exit 1
  fi
  viper_body=$(curl -sS -H "Authorization: Bearer ${VIPER_API_KEY}" \
    "http://localhost:3000/api/v1/assets?pageSize=100")
  if echo "${viper_body}" | jq -e '.code' >/dev/null 2>&1; then
    exit 1
  fi
  echo "${viper_body}" | jq .
else
  exit 1
fi