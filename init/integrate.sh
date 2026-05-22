#!/usr/bin/env bash
# Runs on: host (repo root)
# Invoked by: just integrate
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -z "${VIPER_API_KEY:-}" ]; then
  echo "ERROR: VIPER_API_KEY is not set." >&2
  echo "Run:  docker compose exec viper npm run db:create-test-api-key" >&2
  echo "Then: export VIPER_API_KEY=<key printed above>" >&2
  exit 1
fi

# B3: stamp last_pinged so the webhook queryset is non-empty
bash "${SCRIPT_DIR}/backfill-last-pinged.sh"
bash "${SCRIPT_DIR}/register-viper.sh"
