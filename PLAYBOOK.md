# PATCH VMP Demo Playbook

|              |                                                                                         |
| ------------ | --------------------------------------------------------------------------------------- |
| **Platform** | PATCH Vulnerability Mitigation Platform (VMP) — TA1                                     |
| **Stack**    | TapirXL → BlueFlow → Viper                                                              |
| **Phase 1**  | Engineering smoke: mounted PCAP → BlueFlow upsert (one-shot)                            |
| **Phase 2**  | Audience demo: Viper asset sync via Inngest (live replay requires `tapirxl:demo-0.3.1`) |

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

## Phase 1 — PCAP smoke (engineering / QA)

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

## Phase 2 — Viper integration (audience demo)

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

### Step 4 — Live replay (requires `tapirxl:demo-0.3.1`)

> **Not yet available.** Live capture support ships in `tapirxl:demo-0.3.1`.
> Until then, re-run `docker compose run --rm tapirxl` to replay the PCAP.

```bash
# When 0.3.1 is released:
just demo
just logs
```

---

## Teardown

```bash
just fresh   # wipes all named volumes; start from Phase 1 on next run
```

---

## Quick reference

```bash
just parse              # Parse only (no BlueFlow upload)
just boot               # Start stack + seed BlueFlow
just capture            # Parse and ingest (run after just boot)
just integrate          # register BlueFlow ↔ Viper + trigger sync
just demo               # start live replay (tapirxl:demo-0.3.1+)
just fresh              # Tear down + wipe volumes
just check blueflow     # Print asset counts + names from BlueFlow
just check viper        # Print asset counts + names from Viper
just logs               # Tail tapirxl + blueflow-worker
just ps                 # Show service health
```

---

## Common failure modes

| Symptom                                                      | Cause                                            | Fix                                                                                          |
| ------------------------------------------------------------ | ------------------------------------------------ | -------------------------------------------------------------------------------------------- |
| `tapirxl` exits `401`                                        | `BLUEFLOW_API_TOKEN` mismatch                    | Both services read the same `.env` value — verify                                            |
| `tapirxl` exits `415`                                        | Stale image missing `Content-Type` header        | `docker compose pull tapirxl`                                                                |
| Vector log `Http status: 404 Not Found` on `/api/assets/upsert/` | `just demo` was run before `just boot` (or seed-blueflow.sh failed). BlueFlow's `AssetViewSet` inherits `WaffleSwitchMixin(waffle_switch='core')`, so without an active `core` switch every viewset 404s; runserver's per-process `LocMemCache` then locks that 404 in until BlueFlow restarts. | `just demo` now depends on `boot`. If you hit this on an already-running stack: `docker compose exec blueflow bash /demo-init/seed-blueflow.sh && docker compose restart blueflow tapirxl replay`. |
| Vector logs `failed to lookup address: blueflow`             | Network split                                    | `docker network inspect tapirxl-demo_clinical_demo` — both must be members                   |
| BlueFlow assets present; Viper stays empty                   | Integration not registered or sync not triggered | Re-run `just integrate`                                                                      |
| `just integrate` fails Step A with `400`                     | `VIPER_API_KEY` stale or DB reset                | Re-run `docker compose exec viper npm run db:create-test-api-key` and export the new key     |
| `just integrate` fails to extract integration ID             | Viper returned an error                          | Check Step A response printed above the error                                                |
| Viper UI blank / 502                                         | Viper still initializing                         | Wait for `docker compose ps` to show `viper` as `(healthy)`                                  |
| Assets disappear after `just fresh`                          | Expected — volumes wiped                         | Start from Phase 1                                                                           |
| `just check` Viper section: `ERROR: Viper API: Unauthorized` | `VIPER_API_KEY` unset / stale                    | `docker compose exec viper npm run db:create-test-api-key` then `export VIPER_API_KEY=<key>` |

### Cross-team blockers (upstream image bugs)

These two are patched in this repo via `compose.yaml`. Remove the workarounds once the upstream images ship the fix.

| ID  | Where                                                                                                                              | Symptom in this repo                                                                                                                                                                                                                                                                                                                                                                                                                                                  | Workaround (current)                                                                                                                                                                                                                                                                                                                                                                            | Upstream fix                                                                                                                                                                                                          |
| --- | ---------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| U1  | `virtalabsinc/blueflow:demo-0.3.0`                                                                                                 | `POST /api/viper/webhook/` returns `500` with `AttributeError: 'NoneType' object has no attribute 'Redis'` even though `EAGER=True`                                                                                                                                                                                                                                                                                                                                   | `compose.yaml` `blueflow.command` runs `uv pip install --quiet redis` before the image's `docker-entrypoint.sh`.                                                                                                                                                                                                                                                                                | Bundle the `redis` Python package in `virtalabsinc/blueflow:demo-0.3.1`.                                                                                                                                              |
| U2  | `viper` (`src/inngest/functions/sync-integrations.ts`) + `virtalabsinc/blueflow:demo-0.3.0` (`blueflow/views/viper.py` `URLField`) | Sync succeeds (BlueFlow returns `202`) but no assets land in Viper. Webhook payload contains `callback: http://localhost:3000/...`, which from inside BlueFlow's container resolves to BlueFlow's own loopback, not Viper. Naively switching to `http://viper:3000` fails Django's `URLValidator` (no TLD) → `400 {"callback":["Enter a valid URL."]}`.                                                                                                               | `compose.yaml` adds the network alias `viper.local` on the `viper` service and sets `viper.NEXT_PUBLIC_APP_URL=http://viper.local:3000`. Server-side `getBaseUrl()` emits the in-network hostname (which the alias resolves) and Django's URL validator accepts it. Browser is unaffected (`getBaseUrl()` returns `""` client-side; `auth.ts` hardcodes `localhost:3000` as a `trustedOrigin`). | Add a dedicated `INTERNAL_BASE_URL` env var in Viper for in-cluster callbacks **and** relax BlueFlow's `URLField` to accept single-label hostnames (or use `serializers.CharField` with a permissive validator).      |
| U3  | `virtalabsinc/blueflow:demo-0.3.0` (`blueflow/models/viper.py` `ViperWebhookResponseList.from_request`)                            | After all of U1/U2 are fixed the webhook returns `202` and the Celery task completes "in 0.01s: None" with no HTTP POST to Viper. BlueFlow filters assets with `last_pinged__gte=since`, but TapirXL ingest never stamps `last_pinged`, so the queryset is always empty.                                                                                                                                                                                              | `just integrate` backfills `Asset.last_pinged = now()` via `manage.py shell` before triggering the sync.                                                                                                                                                                                                                                                                                        | Either have TapirXL set `last_pinged` on upsert, have BlueFlow's `/api/assets/upsert/` default `last_pinged` to `now()` when absent, or change the webhook filter to `last_pinged__gte=since OR last_pinged IS NULL`. |
| U4  | `virtalabsinc/blueflow:demo-0.3.0` (`blueflow/celery/tasks.py` + `blueflow/models/viper.py`)                                       | Celery task raises `TypeError: Object of type datetime is not JSON serializable`. `ViperWebhookRequest` is annotated `since: str` but DRF supplies a `datetime`; `ViperWebhookResponse.to_dict()` then returns it raw into `requests.post(json=...)`.                                                                                                                                                                                                                 | Bind-mount overlay at `init/blueflow-patches/tasks.py` → `/app/blueflow/celery/tasks.py`. Replaces the task body to coerce datetimes to ISO-8601 strings before serialization.                                                                                                                                                                                                                  | Fix `ViperWebhookRequest.since` typing and stringify datetimes in `to_dict()`.                                                                                                                                        |
| U5  | `virtalabsinc/blueflow:demo-0.3.0` (`blueflow/models/viper.py` `ViperAsset` + `ViperWebhookResponse`)                              | Even with all of U1–U4 fixed, Viper rejects the POST with `400` because the payload uses snake_case (`network_segment`, `mac_address`, `vendorID`, …), is missing required `ip` / `upstreamApi` / `vendorId`, sends `status="active"` (Viper enum requires `Active\|Decommissioned\|Maintenance`), and includes extraneous keys (`id`, `name`, `vendor`, `model`, `udi`). Wrapper uses `total`/`total_pages`/`next_page` instead of `totalCount`/`totalPages`/`next`. | Same bind-mount overlay (`init/blueflow-patches/tasks.py`) bypasses the broken model `to_dict()` and constructs the wire payload to match Viper's OpenAPI contract (`/api/v1/assets/integrationUpload/{token}`).                                                                                                                                                                                | Align BlueFlow's `ViperAsset.to_dict()` and `ViperWebhookResponse.to_dict()` with Viper's OpenAPI schema, OR have Viper accept the BlueFlow schema and coerce server-side.                                            |

**Removing the U4/U5 overlay**: once a fixed BlueFlow image ships (`demo-0.3.1+`), delete `init/blueflow-patches/` and remove the bind-mount line from `compose.yaml` `blueflow.volumes`. U1 is fixed in `demo-0.3.1` — drop the `uv pip install redis` override. **U2 is deferred**: the `viper.local` alias + `NEXT_PUBLIC_APP_URL` workaround is functional and minimal; keep it unless BlueFlow relaxes `URLField` for hygiene. Keep U3 (`just integrate` backfill) until either TapirXL or BlueFlow's upsert stamps `last_pinged`.
