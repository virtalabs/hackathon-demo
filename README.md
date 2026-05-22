# PATCH VMP Demo

ARPA-H Hackathon demo of the **PATCH Vulnerability Mitigation Platform (VMP)** — a TA1 clinical-device intelligence and asset-management stack composed of TapirXL, BlueFlow, and Viper.

**Pipeline:** TapirXL → (Vector HTTP) → BlueFlow → (Celery webhook) → Viper

| Phase           | Mode                      | What it proves                                             |
| --------------- | ------------------------- | ---------------------------------------------------------- |
| **1 — capture** | Mounted PCAP, one-shot    | VMP parse → ship → store, end to end                       |
| **2 — live**    | tcpreplay on shared netns | Real-time VMP classify → BlueFlow → Viper (no manual sync) |

---

## Stack

| Service           | Image                              | Role                                              |
| ----------------- | ---------------------------------- | ------------------------------------------------- |
| `tapirxl`         | `virtalabsinc/tapirxl:demo-<ver>`  | Packet parser + Vector shipper                    |
| `blueflow`        | `virtalabsinc/blueflow:demo-<ver>` | Django REST API; asset store (pin `demo-0.3.4+`)  |
| `blueflow-worker` | same image                         | Celery worker (not started by default; `CELERY_TASK_ALWAYS_EAGER=True` in dev) |
| `blueflow-psql`   | `postgres:16-alpine`               | BlueFlow DB                                       |
| `blueflow-redis`  | `redis:7-alpine`                   | Celery broker                                     |
| `viper`           | built from source (viper repo)     | Next.js UI; mirrors BlueFlow                      |
| `viper-psql`      | built from source (viper repo)     | Viper DB                                          |
| `inngest`         | built from source                  | Background job server for Viper                   |
| `replay`          | built here                         | Alpine + tcpreplay; Phase 2 only (`live` profile) |

**Requires:** `docker` ≥ 24 (Compose v2), `just`, `curl`, `jq`

---

## Directory structure

```
├── compose.yaml               # Canonical VMP stack definition
├── .env.example               # Copy to .env; set BLUEFLOW_API_TOKEN
├── justfile                   # Runbook targets
├── PLAYBOOK.md                # Full step-by-step runbook
├── pcap/synthetic_philips_demo.pcap
├── replay/                    # tcpreplay sidecar image
└── init/                      # host + container scripts (see init/README.md)
```

---

## Usage

```bash
cp .env.example .env       # set BLUEFLOW_API_TOKEN; pin BLUEFLOW_TAG=demo-0.3.4
docker compose pull        # optional; pull pinned TapirXL + BlueFlow images

just fresh                 # optional; wipe volumes before a clean run
just boot                  # Boot stack + seed BlueFlow
just parse                 # Parse only (no BlueFlow upload)
just capture               # Parse and ingest (TapirXL & BlueFlow only)
just check blueflow        # verify assets in BlueFlow

# Phase 2 pre-flight
docker compose exec viper npm run db:create-test-api-key
export VIPER_API_KEY=<key>
just integrate             # Create integration with BlueFlow

just demo                  # live replay → BlueFlow → Viper
just fresh                 # teardown + wipe volumes
```

**Note:** run `just -l` to list all available recipes.

See [`PLAYBOOK.md`](PLAYBOOK.md) for the full runbook and failure modes.
Upstream BlueFlow/Viper workaround history: [`.claude/BLUEFLOW_BUGS.md`](.claude/BLUEFLOW_BUGS.md).
