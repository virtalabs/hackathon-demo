#!/usr/bin/env bash
# Runs on: host (repo root)
# Invoked by: just capture
set -euo pipefail

: "${TAPIRXL_PCAP_PATH:=/pcap/ct_to_pacs_scenario.pcap}"

docker compose --progress quiet run --rm --no-deps \
  -e "TAPIRXL_PCAP_PATH=${TAPIRXL_PCAP_PATH}" \
  -e "UPLOAD_VECTOR_VRL_PATH=/etc/vector/upload-vector.vrl" \
  --entrypoint bash tapirxl /demo-init/tapirxl-pretty-ingest.sh