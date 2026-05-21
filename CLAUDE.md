# Demo Repo — Claude Code Project Context

**What:** Cross-repo orchestration for the **PATCH VMP** (Vulnerability
Mitigation Platform) demo. TapirXL, BlueFlow, and Viper are all TA1 components
of the same VMP; this repo is the glue that runs them together. It owns the
`compose.yaml`, the synthetic PCAP, the `replay` image, and the demo runbook.
It does **not** own application code — each TA1 service ships its own
`demo-<semver>` image that this repo pins exactly.

**Source of truth (external):**

- `TapirXL/docs/ARCHITECTURE.md` — log shipper / VRL / wire contract (§12)
- `TapirXL/.cursor/context/demo_playbook.md` — the canonical compose shape (§4) and runbook (§5–§9)
- `TapirXL/.cursor/context/demo_critical_path.md` — phased delivery items (A/B/C series)
- `TapirXL/.cursor/context/state_of_the_union.md` — decisions D1–D7

This file distills what an agent working in the demo repo must know. When
behaviour disagrees with `PLAYBOOK.md` (local runbook) or TapirXL's
`demo_playbook.md` (compose shape), the playbook wins; update this file in the
same PR.

---

## Repo Layout (expected)

```
demo/
├── compose.yaml                # Phase 1 + Phase 2 (replay behind `live` profile)
├── compose.override.yaml       # optional dev tweaks (gitignored or local)
├── .env.example                # BLUEFLOW_API_TOKEN, image tag versions
├── pcap/
│   └── synthetic_philips_demo.pcap  # canonical demo capture (committed)
├── replay/
│   ├── Dockerfile              # alpine + tcpreplay
│   └── entrypoint.sh           # tcpreplay --intf1=eth0 ...
├── init/                       # host + container scripts (see init/README.md)
├── justfile                    # thin recipes → init/*.sh on host
├── PLAYBOOK.md                 # operator-facing runbook
└── README.md                   # quick start (points to PLAYBOOK.md)
```

The compose file is the canonical reference; anything else is convenience.

---

## Toolchain

```bash
# First-time setup
cp .env.example .env             # fill image tags + BLUEFLOW_API_TOKEN
docker compose pull              # pull all pinned demo-<tag> images

# Phase 1 (engineering smoke; PCAP one-shot)
just parse                       # optional: PCAP → JSON only (no upload)
just boot                        # start stack + seed BlueFlow
just capture                     # one-shot PCAP ingest

# Phase 2 pre-flight (VIPER_API_KEY — manual paste, not a just recipe)
docker compose exec viper npm run db:create-test-api-key
export VIPER_API_KEY=<key printed above>
just integrate                   # registers BlueFlow ↔ Viper webhook (§5.3)
just demo                        # live replay + tapirxl listener

# Teardown
just fresh                       # docker compose --profile live down --volumes
```

Required tools:

- `docker` ≥ 24 with Compose v2 plugin
- `just`, `curl`, `jq` (for §5.3 integration registration and healthchecks)

---

## Service Inventory and Image Pins

TapirXL and BlueFlow are pulled as published images from `virtalabsinc/*` on Docker Hub. **Pin exact tags in `compose.yaml`; never use `latest`.** Tag scheme is `demo-<semver>` (e.g. `demo-0.3.1`). Viper, `viper-psql`, and `inngest` are currently built from local source (viper repo); `replay` is built from this repo.

| Service           | Image / Source                                   | Role | Pinned where |
| ----------------- | ------------------------------------------------ | ---- | ------------ |
| `blueflow-psql`   | `postgres:16-alpine`                             | BlueFlow Postgres | upstream tag |
| `blueflow-redis`  | `redis:7-alpine`                                 | BlueFlow Celery broker + result backend | upstream tag |
| `blueflow`        | `virtalabsinc/blueflow:demo-<semver>`            | Django REST API; mounts `/api/assets/upsert/`. Auto-creates `admin/admin`. | `.env`: `BLUEFLOW_TAG` |
| `blueflow-worker` | `virtalabsinc/blueflow:demo-<semver>`            | Celery worker (not started by `just boot`/`just demo`; `CELERY_TASK_ALWAYS_EAGER=True` in dev runs the task inside `blueflow`) | same as `blueflow` |
| `viper-psql`      | built from source (viper repo `docker/db/`)      | Viper Postgres | local build |
| `viper`           | built from source (viper repo `docker/viper/`)   | Viper UI (Better-Auth, Next.js) | local build |
| `inngest`         | built from source (viper repo `docker/inngest/`) | Inngest dev server; drives Viper sync cron and triggered syncs | local build |
| `tapirxl`         | `virtalabsinc/tapirxl:demo-<semver>`             | Parser + Vector shipper. `cap_add: [NET_ADMIN]` | `.env`: `TAPIRXL_TAG` |
| `replay`          | built here (`replay/Dockerfile`)                 | tcpreplay sidecar; shares `tapirxl`'s netns. **`profiles: ["live"]`** | local build |

Image origins:

- TapirXL: built and pushed by `TapirXL/.github/workflows/release.yml` on
  annotated tag `demo-v<semver>`.
- BlueFlow: other TA1 team; coordinate version bumps in advance.
- Viper / `viper-psql` / `inngest`: built from local viper repo source. Coordinate path and tag when a published image ships.
- `replay`: this repo, `replay/Dockerfile`. Ship as `virtalabsinc/replay:demo-<semver>` once stable.

---

## Authentication: BLUEFLOW_API_TOKEN flow

The static demo token is the linchpin between TapirXL and BlueFlow. Both
sides must read **the same value** at startup.

```
.env                                .env
  BLUEFLOW_API_TOKEN=demo-XXX         BLUEFLOW_API_TOKEN=demo-XXX
       │                                       │
       ▼                                       ▼
  blueflow service                       tapirxl service
  ENV: API_TOKEN=$BLUEFLOW_API_TOKEN     ENV: BLUEFLOW_TOKEN=$BLUEFLOW_API_TOKEN
       │                                       │
       ▼                                       ▼
  bootstrap script:                       Vector http sink:
    if [ -n "$BLUEFLOW_API_TOKEN" ]; then     Authorization: Token $BLUEFLOW_TOKEN
      use it                              (configs/upload-vector.toml inside image)
    else
      generate via Token.objects.get_or_create
```

Compose snippet:

```yaml
blueflow:
  environment:
    API_TOKEN: ${BLUEFLOW_API_TOKEN}        # passed to bootstrap.sh
tapirxl:
  environment:
    BLUEFLOW_TOKEN: ${BLUEFLOW_API_TOKEN}   # consumed by Vector
```

**N3 below** is the binding rule: never split these into two values.

---

## Network Topology

Single bridge network `clinical_demo`. Service names resolve via Docker DNS;
no static IPs unless the audience demands them (the reference compose at
`TapirXL/.cursor/context/docker-compose.yaml` shows the static-IP variant).

```
┌────────────────── clinical_demo (bridge) ────────────────────┐
│                                                              │
│  replay  ─netns──►  tapirxl ──http──►  blueflow ──celery─►  │
│  (live profile)     (eth0)            :8000      blueflow-  │
│                                          │       worker     │
│                                          ▼          │       │
│                                   blueflow-psql     │       │
│                                   blueflow-redis    │       │
│                                                     ▼       │
│                                      viper :3000 ◄──┘       │
│                                          │                  │
│                                          ▼                  │
│                                   viper-psql                │
└──────────────────────────────────────────────────────────────┘
   host:8000 → blueflow API
   host:3000 → viper UI
```

- `replay` uses `network_mode: "service:tapirxl"` — packets land on tapirxl's eth0.
- `tapirxl` is the only service with `cap_add: [NET_ADMIN]`. Required for raw-socket capture (Phase 2).
- Host-published ports only on `blueflow:8000` and `viper:3000`.

---

## Demo Phases

| Phase | Audience | Mode | Command |
| ----- | -------- | ---- | ------- |
| **1** | Engineering / QA | `TAPIRXL_MODE=pcap` (one-shot mounted PCAP) | `just capture` |
| **2** | Audience | `TAPIRXL_MODE=live` + `replay` profile (live netns capture) | `just demo` |

Phase 1 must pass cleanly before Phase 2 work begins. Phase 1 does not need
the `replay` service, the §5.3 BlueFlow ↔ Viper webhook, or any Viper UI walk-through.

Phase 2 narrative: `PLAYBOOK.md` Phase 2. Pre-flight is `just integrate`
(§5.3 Steps A–C); do not start Phase 2 until those run cleanly on the current
volume set.

---

## Hard Rules (enforce always)

| # | Rule |
| --- | --- |
| **N1** | Pin exact `demo-<semver>` tags in `compose.yaml`. **Never `latest`.** Demo image versions are listed in `.env`; CI / `just` targets must read them from there, not hardcode. |
| **N2** | All VMP component images are consumed as published images. Do **not** `build:` TapirXL inside this repo. The only image built locally is `replay`. |
| **N3** | `BLUEFLOW_API_TOKEN` from `.env` is **the** authentication seam. It populates `blueflow.environment.API_TOKEN` and `tapirxl.environment.BLUEFLOW_TOKEN` from the same value. Do not introduce a second token, do not generate one at runtime, do not commit it as a literal. |
| **N4** | `cap_add: [NET_ADMIN]` lives on `tapirxl` only. Do not add it to `replay`; the shared netns inherits it. |
| **N5** | `replay` is gated by `profiles: ["live"]` so `docker compose up` (default) brings up the Phase 1 stack only. Do not change this without updating `just capture`. |
| **N6** | The PCAP under `pcap/synthetic_philips_demo.pcap` is the canonical fixture. Replacing it requires regenerating `golden_synthetic_philips_assets.jsonl` in TapirXL — coordinate the bump there first. |
| **N7** | The compose file does **not** mutate TapirXL behaviour by remounting Vector configs. The `tapirxl:demo-<tag>` image bakes `upload-vector.toml` (long-running) and `upload-vector.stdin.toml` (one-shot, was `upload-vector.pcap.toml` in `demo-0.3.0`); rely on `TAPIRXL_MODE` to select the right one. |
| **N8** | `tapirxl` mounts the PCAP read-only (`:ro`). The container runs as uid 10001 — never `chmod`/`chown` the host directory to fix mount perms; either rely on world-readable bits or fix the file owner. |
| **N9** | Healthchecks are required on `blueflow-psql`, `blueflow-redis`, `blueflow`, `viper-psql`, `viper`. `depends_on: { ...: { condition: service_healthy } }` is the merge gate, not optimistic ordering. |
| **N10** | Volumes for state are named (`tapirxl-spool`, `blueflow-pgdata`, `viper-pgdata`). Anonymous volumes are forbidden — `docker compose down --volumes` must reliably reset the demo. |
| **N11** | Phase 2 audience demo requires §5.3 (BlueFlow ↔ Viper webhook registration) to run **before** ingest. Encode this as `just integrate`; never expect the presenter to run curl by hand. |
| **N12** | `latest`-tagged images may exist on Docker Hub for convenience, but the demo `compose.yaml` MUST use the immutable `demo-<semver>` tag. CI guard: `grep -E ':latest' compose.yaml` must return empty. |

---

## Image Contracts (what each image MUST satisfy)

These are the binding promises external images make to the demo. Failures
here are upstream bugs, not compose tweaks.

### `virtalabsinc/tapirxl:demo-0.3.1`

- Single ENTRYPOINT switching on `$TAPIRXL_MODE`:
  - `pcap` (default) → `tapirxl parse $TAPIRXL_PCAP_PATH --json | vector --config-toml /etc/vector/upload-vector.stdin.toml`, then exits.
  - `live` → long-running raw-socket capture on `$TAPIRXL_INTERFACE`. Verified working in `demo-0.3.1`.
- Bakes Vector configs in `/etc/vector/`:
  - `upload-vector.toml` (compose long-running, file source)
  - `upload-vector.stdin.toml` (one-shot, stdin source — was `upload-vector.pcap.toml` in `demo-0.3.0`)
  - `upload-vector.vrl` (shared translation; `$UPLOAD_VECTOR_VRL_PATH` already set)
- Reads from env: `BLUEFLOW_URL`, `BLUEFLOW_TOKEN`, `TAPIRXL_PCAP_PATH` (pcap mode), `TAPIRXL_INTERFACE` (live mode).
- Non-root user uid 10001.

Authoritative version of this contract: `TapirXL/packaging/docker/README.md` "Unified demo image" + `demo_playbook.md §4`.

### `virtalabsinc/blueflow:demo-0.3.1`

- Auto-creates `admin/admin` on first boot (`DEFAULT_USERNAME` + `DEFAULT_PASSWORD`).
- Runs migrations when `RUN_MIGRATIONS=1`.
- Honors `API_TOKEN` env var: if set, the bootstrap installs that exact value as the `admin` user's DRF token (`Token.objects.get_or_create`); otherwise generates one and prints to stdout. **The demo requires the env-var path** so the token is deterministic across container restarts (N3).
- Bundles the `redis` Python package (fixed in `demo-0.3.1`; the `uv pip install redis` workaround is no longer needed).
- Exposes `PUT /api/assets/upsert/` accepting the `AssetUpsertPayload` shape from `TapirXL/configs/upload-vector.vrl`. Must accept `Authorization: Token <hex>` (DRF, not Bearer) and `Content-Type: application/json`.
- Healthcheck on `/api/`.

### `viper:demo-0.1.0`

- Better-Auth + Next.js UI on port 3000.
- tRPC endpoint `/api/trpc/integrations.create` for §5.3 Step A.
- REST endpoint `/api/v1/assets/integrationUpload` for BlueFlow's webhook callback (§5.3 Step B).
- Healthcheck on `/api/`.

### `virtalabsinc/replay:demo-0.1.0`

- ~20 MB image: `alpine` + `tcpreplay`.
- Runs `tcpreplay --intf1=eth0 --loop=$REPLAY_LOOP --multiplier=$REPLAY_RATE $REPLAY_PCAP`.
- Exits `0` when `REPLAY_LOOP=0` (one pass); loops forever when `1`.
- Reads `REPLAY_PCAP`, `REPLAY_RATE`, `REPLAY_LOOP` from env.
- No NET_ADMIN of its own (inherits from shared netns).

---

## Phase 1 — PCAP smoke (engineering only)

```fish
docker compose pull
docker compose up -d \
  blueflow-psql blueflow-redis blueflow \
  viper-psql viper

# Wait for healthchecks.
docker compose ps   # all should show (healthy)

# Sanity-check BlueFlow + auth.
curl -sS -H "Authorization: Token $BLUEFLOW_API_TOKEN" \
  http://127.0.0.1:8000/api/assets/ | jq .count   # expect 0

# One-shot ingest (TAPIRXL_MODE=pcap is the default in the image).
docker compose run --rm tapirxl

# Verify upsert.
curl -sS -H "Authorization: Token $BLUEFLOW_API_TOKEN" \
  http://127.0.0.1:8000/api/assets/ | jq '.count, .results[].display_name'
```

**Pass criteria** (matches TapirXL CI smoke):

- 8 × `201 Created` on first run, 8 × `200 OK` on re-run (idempotent).
- All MAC addresses present in `GET /api/assets/`, with `manufacturer`, `model`, `category`, `open_ports_tcp`, `external_keys.tapirxl_confidence` populated.

---

## Phase 2 — Live replay + Viper push (audience demo)

Pre-flight (§5.3) is mandatory before ingest. After Phase 2 boot:

```fish
docker compose --profile live up -d tapirxl replay
docker compose logs -f tapirxl blueflow
```

Audience-visible state changes:

1. BlueFlow `GET /api/assets/` populates as TapirXL classifies.
2. Viper UI at `http://127.0.0.1:3000/` mirrors BlueFlow within seconds (Celery webhook).

Manual `sync` is forbidden during the talk track — if Viper stays empty, the integration registration (§5.3) is the first place to look, not TapirXL.

---

## Common Failure Modes

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `tapirxl` exits with `401` | `BLUEFLOW_API_TOKEN` mismatch between `blueflow` and `tapirxl` | Both must reference `${BLUEFLOW_API_TOKEN}` from `.env` (N3) |
| `tapirxl` exits with `415 Unsupported Media Type` | Stale demo image without explicit `Content-Type` header | `docker compose pull tapirxl` |
| Vector logs `failed to lookup address information: blueflow` | Services not on the same network | `docker network inspect tapirxl-demo_default`; both must be members |
| Phase 1 container hangs (180s+) | Compose accidentally mounting `upload-vector.toml` (file source) over the stdin config | N7: never override the image's baked configs in pcap mode |
| `just capture` exits 78 with no output | `init/tapirxl-pretty-ingest.sh` is referencing an old config name. In `demo-0.3.1` the one-shot config is `upload-vector.stdin.toml` (renamed from `upload-vector.pcap.toml`). | Ensure the script references `/etc/vector/upload-vector.stdin.toml`. |
| BlueFlow has assets, Viper stays empty | §5.3 webhook not registered, or sync never triggered | Re-run `just integrate`; check `just logs` |
| Celery 4xx to Viper callback | Stale `auth_token` / wrong `webhook_url` | Wipe Postgres volumes, re-register from scratch (`just fresh && just integrate`) |
| Replay starts before tapirxl is listening | `depends_on: service_started` is too eager for live mode | Add a healthcheck to tapirxl's live mode; increase replay startup sleep |
| `WARN ... file too small to fingerprint` | Vector file source race (compose long-running mode only) | Benign; ignore. Pcap mode does not have this. |

---

## What NOT to Do

- Do NOT build `tapirxl`, `blueflow`, or `viper` from source in this repo. Pull pinned images.
- Do NOT use `latest` tags in `compose.yaml`. Demo stability depends on immutable digests.
- Do NOT split `BLUEFLOW_API_TOKEN` into two distinct values for `blueflow` and `tapirxl`. The token is one fact, sourced from `.env`.
- Do NOT bind-mount Vector configs from this repo over the baked image configs. The image owns its config selection via `TAPIRXL_MODE`.
- Do NOT `--network=host` in Phase 2. Use the dedicated bridge so `replay` can share `tapirxl`'s netns.
- Do NOT write integration registration steps (§5.3) into the README only. Encode them as `just integrate`; presenters do not curl by hand.
- Do NOT add `cap_add: [NET_ADMIN]` to any service other than `tapirxl`.
- Do NOT commit the `.env` file. Commit `.env.example` with placeholder token values; agents and operators copy it to `.env` locally.
- Do NOT introduce a Phase 1.5 mode. The boundary between Phase 1 (engineering) and Phase 2 (audience) is the `live` profile + `TAPIRXL_MODE`.
- Do NOT modify the canonical PCAP without coordinating a TapirXL golden regenerate (N6).
- Do NOT bake credentials, API tokens, or webhook secrets into committed YAML/scripts. Everything sensitive flows through `.env`.

---

## Cross-Team Coordination (TA1)

Track these in your repo's issue tracker; they're the demo's open blockers across TA1 teams.

| ID | Item | Owner | Blocking |
| --- | --- | --- | --- |
| **C2** | `virtalabsinc/blueflow:demo-<tag>` honors `BLUEFLOW_API_TOKEN` env var (env-driven, not runtime-generated) | TA1 BlueFlow | N3 / clean Phase 1 boot |
| **C3** | `virtalabsinc/viper:demo-<tag>` published with stable tRPC + integrationUpload contract | TA1 Viper | Phase 2 |
| **C4** | BlueFlow no-op short-circuit on identical-state writes | TA1 BlueFlow | Phase 2 hygiene (eliminates duplicate `historicalasset` rows) |
| **C7** | Talk-track timing pass with stopwatch | Demo presenter | Phase 2 rehearsal |

TapirXL-side items (A1–A3, B1, B2) live in `TapirXL/.cursor/context/demo_critical_path.md` and are **not** this repo's concern.

---

## When to Update This File

- New service added to `compose.yaml` → add row to Service Inventory table.
- New `BLUEFLOW_*` or `VIPER_*` env var introduced → update Authentication section.
- Image contract changes (e.g. TapirXL adds a new `TAPIRXL_MODE` value) → mirror it under Image Contracts.
- New common failure → add a row to Common Failure Modes; never remove rows for failures still possible.

When `PLAYBOOK.md` (local operator runbook) drifts from this file, update this
file in the same PR.
