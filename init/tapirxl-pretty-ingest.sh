#!/usr/bin/env bash
# One-shot PCAP ingest with pretty-printed InventoryRecord JSONL on stderr only.
# Vector logs and tapirxl progress are suppressed; BlueFlow upload still runs.
# Invoked by: just capture

set -euo pipefail

: "${TAPIRXL_PCAP_PATH:?TAPIRXL_PCAP_PATH is required}"

tapirxl parse "$TAPIRXL_PCAP_PATH" --json 2>/dev/null \
 | vector --config-toml /etc/vector/upload-vector.stdin.toml >/dev/null 2>&1