# PATCH VMP Demo Playbook

|              |                                                                                     |
| ------------ | ----------------------------------------------------------------------------------- |
| **Platform** | PATCH Vulnerability Mitigation Platform (VMP) — TA1                                 |
| **Stack**    | TapirXL → BlueFlow → Viper                                                          |
| **Phase 1**  | Engineering smoke: mounted PCAP → BlueFlow upsert (one-shot)                        |
| **Phase 2**  | Audience demo: Viper asset sync via Inngest + live tcpreplay (`tapirxl:demo-0.3.1`) |

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
# The same token is used by both BlueFlow and TapirXL; do not use two values.
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

**Pass criteria:**

- First run: 8 × `201 Created`
- Re-run: 8 × `200 OK` (idempotent)
- All assets have `manufacturer`, `model`, `category`, `open_ports_tcp`, `external_keys.tapirxl_confidence` populated

---

## Demonstrate full device and vulnerability capture

Phase 1 must pass first. Run on the same running stack.

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
4. BlueFlow POSTs paginated assets to `http://viper:3000/api/v1/assets/integrationUpload/{token}`

The `blueflow-worker` container is not required in this configuration.

### Step 3 — Verify assets in Viper

```bash
# BlueFlow
just check blueflow

# Viper
just check viper
open http://localhost:3000
```

Both should show the same 8 assets. Viper re-syncs automatically every 5 minutes via Inngest cron.

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

---

## Common failure modes

| Symptom                                                          | Cause                                                                                                                                                                                                                                                                                                | Fix                                                                                                                                                                                                                                                                                                     |
| ---------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `tapirxl` exits `401`                                            | `BLUEFLOW_API_TOKEN` mismatch                                                                                                                                                                                                                                                                        | Both services read the same `.env` value — verify                                                                                                                                                                                                                                                       |
| `tapirxl` exits `415`                                            | Stale image missing `Content-Type` header                                                                                                                                                                                                                                                            | `docker compose pull tapirxl`                                                                                                                                                                                                                                                                           |
| Vector log `Http status: 404 Not Found` on `/api/assets/upsert/` | `just demo` was run before seed-blueflow.sh (or seed-blueflow.sh failed). BlueFlow's `AssetViewSet` inherits `WaffleSwitchMixin(waffle_switch='core')`, so without an active `core` switch every viewset 404s; runserver's per-process `LocMemCache` then locks that 404 in until BlueFlow restarts. | `just demo` now seeds inline before bringing up tapirxl/replay. If you hit this on an already-running stack (e.g. seed-blueflow.sh was missing the active=True flip on a stale row): `docker compose exec blueflow bash /demo-init/seed-blueflow.sh && docker compose restart blueflow tapirxl replay`. |
| Vector logs `failed to lookup address: blueflow`                 | Network split                                                                                                                                                                                                                                                                                        | `docker network inspect tapirxl-demo_clinical_demo` — both must be members                                                                                                                                                                                                                              |
| BlueFlow assets present; Viper stays empty                       | Integration not registered or sync not triggered                                                                                                                                                                                                                                                     | Re-run `just integrate`                                                                                                                                                                                                                                                                                 |
| `just integrate` fails Step A with `400`                         | `VIPER_API_KEY` stale or DB reset                                                                                                                                                                                                                                                                    | Re-run `docker compose exec viper npm run db:create-test-api-key` and export the new key                                                                                                                                                                                                                |
| `just integrate` fails to extract integration ID                 | Viper returned an error                                                                                                                                                                                                                                                                              | Check Step A response printed above the error                                                                                                                                                                                                                                                           |
| Viper UI blank / 502                                             | Viper still initializing                                                                                                                                                                                                                                                                             | Wait for `docker compose ps` to show `viper` as `(healthy)`                                                                                                                                                                                                                                             |
| Assets disappear after `just fresh`                              | Expected — volumes wiped                                                                                                                                                                                                                                                                             | Start from Phase 1                                                                                                                                                                                                                                                                                      |
| `just check` Viper section: `ERROR: Viper API: Unauthorized`     | `VIPER_API_KEY` unset / stale                                                                                                                                                                                                                                                                        | `docker compose exec viper npm run db:create-test-api-key` then `export VIPER_API_KEY=<key>`                                                                                                                                                                                                            |
