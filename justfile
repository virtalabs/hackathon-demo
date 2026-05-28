# TapirXL / BlueFlow / Viper demo stack
# See PLAYBOOK.md for the full runbook.
#
# Prerequisites: docker, just, curl, jq
# First run:  cp .env.example .env  (fill in BLUEFLOW_API_TOKEN)

set dotenv-load := true

# Phase 1 PCAP inside the tapirxl container (host: pcap/ct_to_pacs_scenario.pcap)
pcap := "/pcap/ct_to_pacs_scenario.pcap"

# Phase 2 live replay PCAP (host: pcap/synthetic_philips_demo.pcap)
demo-pcap := "/pcap/synthetic_philips_demo.pcap"

# ── Phase 1: PCAP smoke ───────────────────────────────────────────────────────

# Print TapirXL InventoryRecord JSONL pretty-printed (no BlueFlow upload)
parse:
    TAPIRXL_PCAP_PATH={{pcap}} bash init/parse.sh

# Print AssetUpsertPayload JSON (Vector dry-run; no BlueFlow upload).
# Uses the image-baked VRL at /etc/vector/upload-vector.vrl — not init/tapirxl-patches/.
dry-run:
    TAPIRXL_PCAP_PATH={{pcap}} bash init/dry-run.sh

# Boot stack + seed BlueFlow
boot:
    docker compose up -d blueflow-psql blueflow-redis blueflow viper-psql viper network-flow inngest
    docker compose exec blueflow bash /demo-init/seed-blueflow.sh

# Run one-shot PCAP ingest
capture:
    TAPIRXL_PCAP_PATH={{pcap}} bash init/capture.sh

# ── Phase 2: integration + live demo ─────────────────────────────────────────

# Register BlueFlow ↔ Viper integration (requires VIPER_API_KEY; see PLAYBOOK Step 1)
# Pass --only-backfill to skip register-viper.sh
integrate *args:
    bash init/integrate.sh {{args}}

# Start live replay + tapirxl listener (Phase 2).
# Preconditions are inlined (not delegated to `boot`) so this recipe is
# self-describing: every Vector PUT to /api/assets/upsert/ requires the
# 'core' Waffle switch to be active in BlueFlow's DB *and* in BlueFlow's
# per-process LocMemCache. seed-blueflow.sh sets the DB row; running it
# before `up -d tapirxl replay` guarantees the runserver populates its
# cache from the correct row on the first probe.
demo:
    docker compose up -d blueflow-psql blueflow-redis blueflow viper-psql viper network-flow inngest
    docker compose exec blueflow bash /demo-init/seed-blueflow.sh
    REPLAY_PCAP={{demo-pcap}} TAPIRXL_PCAP_PATH={{demo-pcap}} TAPIRXL_MODE=live \
        docker compose --profile live up -d tapirxl replay
    @echo ""
    @echo "==> Live demo running. Watch logs:"
    @echo "    just logs"

# ── Teardown ──────────────────────────────────────────────────────────────────

# Tear down all services and wipe named volumes (full reset)
fresh:
    docker compose --profile live down --volumes

# ── Utilities ─────────────────────────────────────────────────────────────────

# Show asset counts + names from BlueFlow and Viper (VIPER_API_KEY for Viper)
check $SERVICE:
    bash init/check.sh $SERVICE

# Tail tapirxl + blueflow logs
logs:
    docker compose logs -f tapirxl blueflow

# Show service health status
ps:
    docker compose ps
