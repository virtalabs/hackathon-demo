#!/bin/bash
# Demo-repo wrapper around virtalabsinc/tapirxl tapirxl-demo-entrypoint.
# Re-sync with /usr/local/bin/tapirxl-demo-entrypoint when TAPIRXL_TAG bumps.
#
# When TAPIRXL_TELEMETRY=1 and TAPIRXL_MODE=live, tees InventoryRecord JSONL
# to stderr so `just demo` can stream it via docker compose logs.

set -euo pipefail

: "${TAPIRXL_MODE:=pcap}"
: "${BLUEFLOW_URL:?BLUEFLOW_URL is required}"
: "${BLUEFLOW_TOKEN:?BLUEFLOW_TOKEN is required}"

VECTOR_STDIN_CONFIG="/etc/vector/upload-vector.stdin.toml"

case "$TAPIRXL_MODE" in
  pcap)
    : "${TAPIRXL_PCAP_PATH:?TAPIRXL_PCAP_PATH is required in pcap mode}"
    tapirxl parse "$TAPIRXL_PCAP_PATH" --json \
      | vector --config-toml "$VECTOR_STDIN_CONFIG"
    ;;
  live)
    : "${TAPIRXL_INTERFACE:?TAPIRXL_INTERFACE is required in live mode}"
    listen_args=(--interface "$TAPIRXL_INTERFACE" --json)
    if [ -n "${TAPIRXL_INITIAL_EMIT_SECS:-}" ]; then
      listen_args+=(--initial-emit-secs "$TAPIRXL_INITIAL_EMIT_SECS")
    fi
    if [ -n "${TAPIRXL_QUIESCENCE_SECS:-}" ]; then
      listen_args+=(--quiescence-secs "$TAPIRXL_QUIESCENCE_SECS")
    fi
    if [ -n "${TAPIRXL_HEARTBEAT_SECS:-}" ]; then
      listen_args+=(--heartbeat-secs "$TAPIRXL_HEARTBEAT_SECS")
    fi
    if [ "${TAPIRXL_TELEMETRY:-0}" = "1" ]; then
      # Line-at-a-time copy to stderr (docker logs); block-buffered tee would batch bursts.
      tapirxl listen "${listen_args[@]}" \
        | while IFS= read -r line; do
            printf '%s\n' "$line" >&2
            printf '%s\n' "$line"
          done \
        | vector --config-toml "$VECTOR_STDIN_CONFIG"
    else
      tapirxl listen "${listen_args[@]}" \
        | vector --config-toml "$VECTOR_STDIN_CONFIG"
    fi
    ;;
  *)
    echo "Unknown TAPIRXL_MODE: $TAPIRXL_MODE  (expected: pcap | live)" >&2
    exit 64
    ;;
esac
