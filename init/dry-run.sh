#!/usr/bin/env bash
# Runs on: host (repo root)
# Invoked by: just dry-run
# Prints AssetUpsertPayload JSONL (Vector console sink). No BlueFlow upload.
set -euo pipefail

: "${TAPIRXL_PCAP_PATH:=/pcap/ct_to_pacs_scenario.pcap}"

docker compose run --rm --no-deps \
  -e "TAPIRXL_PCAP_PATH=${TAPIRXL_PCAP_PATH}" \
  -e "UPLOAD_VECTOR_VRL_PATH=/etc/vector/upload-vector.vrl" \
  --entrypoint bash tapirxl -c \
  'tapirxl parse "$TAPIRXL_PCAP_PATH" --json 2>/dev/null \
   | vector --quiet --config-toml /demo-init/upload-vector.dryrun.toml' \
  | jq .
