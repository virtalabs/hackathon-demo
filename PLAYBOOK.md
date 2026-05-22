# PATCH VMP Demo Playbook

|              |                                                                                                            |
| ------------ | ---------------------------------------------------------------------------------------------------------- |
| **Platform** | PATCH Vulnerability Mitigation Platform (VMP) — TA1                                                        |
| **Stack**    | TapirXL → BlueFlow → Viper                                                                                 |
| **Phase 1**  | Engineering smoke: mounted PCAP → BlueFlow upsert (one-shot)                                               |
| **Phase 2**  | Audience demo: Viper asset sync via Inngest + live tcpreplay (`blueflow:demo-0.3.4`, `tapirxl:demo-0.3.1`) |

---

## Prerequisites

```bash
# Tools
docker  # ≥ 24, Compose v2 plugin required
just
curl
jq

# First-time setup
cp .env.example .env
# Edit .env — set BLUEFLOW_API_TOKEN to a value of your choice.
# Pin BLUEFLOW_TAG=demo-0.3.4 (required for Phase 2 without compose workarounds).
# The same token is used by both BlueFlow and TapirXL; do not use two values.
docker compose pull
```

---

## Quick reference

```bash
just parse              # Parse only (no BlueFlow upload)
just boot               # Start stack + seed BlueFlow
just capture            # Parse and ingest (run after just boot)
just integrate          # register BlueFlow ↔ Viper + trigger sync
just demo               # start live replay (full stack + seed + tapirxl live)
just fresh              # Tear down + wipe volumes
just check blueflow     # Print asset counts + names from BlueFlow
just check viper        # Print asset counts + names from Viper
just logs               # Tail tapirxl + blueflow
just ps                 # Show service health
```

---

## Demonstrate passive device capture

**What it proves:** mounted PCAP → TapirXL → Vector → BlueFlow upsert.
Viper is running but not exercised.

```bash
# Optional: parse PCAP to JSON only (no BlueFlow upload)
just parse

# Boot stack + seed BlueFlow
just boot

# Run one-shot PCAP ingest
just capture

# Verify
just check blueflow
# expect: count = 8, all assets named
```

---

## Demonstrate full device and vulnerability capture

### Step 1 — Generate Viper API key

```bash
docker compose exec viper npm run db:create-test-api-key
export VIPER_API_KEY=<key printed above>
```

### Step 2 — Register integration and trigger sync

```bash
just integrate
```

`init/register-viper.sh` does two things:

- **Step A:** `integrations.create` (tRPC) — registers BlueFlow as a PARTNER integration in Viper with `integrationUri = http://blueflow:8000/api/viper/webhook/`
- **Step B:** `integrations.triggerSync` (tRPC) — fires an immediate Inngest sync event

**Sync flow (automatic after Step B):**

1. Viper Inngest generates a one-time callback token
2. POSTs `{callback, since, max_pages, page_size}` to BlueFlow's `/api/viper/webhook/`
3. BlueFlow executes the Celery task synchronously (`CELERY_TASK_ALWAYS_EAGER=True` in dev settings)
4. BlueFlow POSTs paginated assets to `http://viper.local:3000/api/v1/assets/integrationUpload/{token}` (in-cluster hostname; see `compose.yaml` `viper.local` alias)

The `blueflow-worker` container is not required in this configuration. Stock `blueflow/celery/tasks.py` from `demo-0.3.4` is used.

`just integrate` also runs `init/backfill-last-pinged.sh` (workaround **B3**): TapirXL upsert leaves `Asset.last_pinged` null, but the webhook queryset filters on `last_pinged__gte=since`.

### Step 3 — Verify assets in Viper

```bash
# BlueFlow
just check blueflow

# Viper
just check viper
open http://localhost:3000
```

```bash
curl -sS -H "Authorization: Bearer ${VIPER_API_KEY}" \
  "http://localhost:3000/api/v1/assets?pageSize=100" \
  | jq '[.items[] | select(.upstreamApi | test("localhost:8000")) | {hostname, mac: .macAddress, upstream: .upstreamApi}]'
```

Viper's total asset count may be higher than the asset count in BlueFlow due to seed data.
After `just fresh`, expect the eight PCAP `display_name` values to appear in that filtered list.
If some are missing while `docker compose logs blueflow` shows `viper_webhook` **succeeded** with no `TypeError`, treat it as a Viper `integrationUpload` item-handling issue (see failure modes). Viper re-syncs automatically every 5 minutes via Inngest cron.

### Step 4 — Live replay

```bash
just demo
just logs
```

`just demo` brings up the full stack (including seed) and starts `tapirxl` in
`live` mode with the `replay` tcpreplay sidecar. TapirXL listens on the shared
netns `eth0`; `replay` loops the PCAP continuously, so BlueFlow is fed a
steady stream of upserts. Watch `just logs` for `PUT /api/assets/upsert/ 200`
lines confirming the pipeline is live.

---

## Teardown

```bash
just fresh   # wipes all named volumes; start from Phase 1 on next run
```
