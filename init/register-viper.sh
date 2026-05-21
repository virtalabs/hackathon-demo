#!/usr/bin/env bash
# BlueFlow ↔ Viper integration ceremony (playbook §5.3)
#
# Prerequisites:
#   VIPER_API_KEY      — docker compose exec viper npm run db:create-test-api-key
#   BLUEFLOW_API_TOKEN — from .env
#
# Called by: just integrate
set -euo pipefail

# Hosts as seen from the Docker host (curl runs on host)
VIPER_URL="${VIPER_URL:-http://localhost:3000}"
BLUEFLOW_URL="${BLUEFLOW_URL:-http://localhost:8000}"

# Internal Docker URL for BlueFlow (embedded in Viper integration record)
BLUEFLOW_INTERNAL_URL="${BLUEFLOW_INTERNAL_URL:-http://blueflow:8000}"

: "${VIPER_API_KEY:?VIPER_API_KEY is not set. Run: docker compose exec viper npm run db:create-test-api-key, then export VIPER_API_KEY=<key>}"
: "${BLUEFLOW_API_TOKEN:?BLUEFLOW_API_TOKEN is not set. Check your .env file.}"

# ── Step A: register BlueFlow as a Viper integration ──────────────────────────
echo "==> Step A: registering BlueFlow as a Viper integration..."

STEP_A_RESPONSE=$(curl -sS -X POST "${VIPER_URL}/api/trpc/integrations.create?batch=1" \
  -H "Authorization: Bearer ${VIPER_API_KEY}" \
  -H "content-type: application/json" \
  --data-raw "{\"0\":{\"json\":{\"authType\":\"Bearer\",\"authentication\":{\"token\":\"${BLUEFLOW_API_TOKEN}\"},\"name\":\"Blueflow\",\"integrationUri\":\"${BLUEFLOW_INTERNAL_URL}/api/viper/webhook/\",\"integrationType\":\"PARTNER\",\"resourceType\":\"Asset\",\"syncEvery\":300}}}")

echo "Step A response: ${STEP_A_RESPONSE}"

# Extract integration ID from Step A response
INTEGRATION_ID=$(echo "${STEP_A_RESPONSE}" \
  | jq -r '.[0].result.data.json.id // empty' 2>/dev/null || true)

if [ -z "${INTEGRATION_ID}" ]; then
  echo "ERROR: could not extract integration ID from Step A response." >&2
  exit 1
fi

echo "==> Integration ID: ${INTEGRATION_ID}"

# ── Step B: trigger an immediate sync ─────────────────────────────────────────
# Viper owns the sync lifecycle: it generates a one-time callback token,
# calls BlueFlow's webhook with it, and BlueFlow posts assets back.
echo "==> Step B: triggering initial sync..."

curl -sS -X POST "${VIPER_URL}/api/trpc/integrations.triggerSync?batch=1" \
  -H "Authorization: Bearer ${VIPER_API_KEY}" \
  -H "Content-Type: application/json" \
  --data-raw "{\"0\":{\"json\":{\"id\":\"${INTEGRATION_ID}\"}}}"

echo ""
echo "==> Integration registered and sync triggered. Watch logs:"
echo "    docker compose logs -f blueflow inngest"
