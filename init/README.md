# Demo init scripts

Scripts under `init/` fall into two groups. Host scripts are invoked by `just` from the repo root. Container scripts are bind-mounted at `/demo-init` and run inside BlueFlow or TapirXL containers.

## Host (runs on machine with Docker)

| Script                    | `just` recipe     | Role                                                                       |
| ------------------------- | ----------------- | -------------------------------------------------------------------------- |
| `parse.sh`                | `parse`           | PCAP → JSON only (no BlueFlow upload)                                      |
| `capture.sh`              | `capture`         | One-shot PCAP ingest (`docker compose run tapirxl`; run after `just boot`) |
| `integrate.sh`            | `integrate`       | B3 backfill + `register-viper.sh`                                          |
| `backfill-last-pinged.sh` | _(via integrate)_ | Stamp `Asset.last_pinged` before Viper sync (B3)                           |
| `register-viper.sh`       | _(via integrate)_ | BlueFlow ↔ Viper integration ceremony                                      |
| `check.sh`                | `check`           | Asset counts from BlueFlow and Viper APIs                                  |
| `demo-telemetry-stream.sh`| `demo` (tail)     | Line-at-a-time tapirxl log → `jq` on host (avoids pipe buffering)          |

## Container (runs inside compose services)

| Script                       | Invoked from                                               | Role                                                            |
| ---------------------------- | ---------------------------------------------------------- | --------------------------------------------------------------- |
| `seed-blueflow.sh`           | `just boot` / `just demo` → `docker compose exec blueflow` | Admin user + API token from env; activates `core` waffle switch |
| `tapirxl-demo-entrypoint.sh` | `compose.yaml` `tapirxl` entrypoint                        | Image entrypoint fork; tees InventoryRecord JSON to stderr when `TAPIRXL_TELEMETRY=1` (`just demo`) |
| `tapirxl-pretty-ingest.sh`   | `just capture` → `docker compose run tapirxl`              | Pretty-printed ingest + Vector upload                           |

**Viper API key** is not a `just` recipe. After Phase 1 (`just boot` + `just capture`):

```bash
docker compose exec viper npm run db:create-test-api-key
export VIPER_API_KEY=<key printed above>
just integrate
```
