# NonaShield / PayShield — Installation & Deployment Scripts

One-step installers and Docker Compose definitions for standing up the full
PayShield/NonaShield stack (nginx edge gateway + backend + supporting
infrastructure) on a customer's own infrastructure — Windows, Ubuntu, generic
Linux, or a fresh AWS EC2 (Ubuntu) instance.

This repo is **generic, reusable installation tooling**. It is a separate
thing from the actual live production/demo deployment mechanism
(`payshield-backend/deploy.sh`) — see [Two Different AWS Paths](#two-different-aws-paths-read-this-first)
below before touching anything AWS-related.

## Two tiers

| Tier | Services | Use case |
|---|---|---|
| **minimal** | nginx, backend, postgres, redis (4 services) | Fast setup, evaluation, lightweight production without Kafka-based audit streaming. `ENABLE_KAFKA_AUDIT=false` — the backend never tries to reach Redpanda, so there's no partial/broken dependency, this tier is genuinely self-contained. |
| **full** | All 13–15 services: nginx, backend, postgres, redis, redpanda, neo4j, minio, mqtt, vault, ollama, airflow, prometheus, grafana (+ ingestion/processor on some platforms) | Full fraud-graph analysis (Neo4j), Kafka-based audit trail (Redpanda), evidence object storage (MinIO), analyst LLM features (Ollama), job scheduling (Airflow), and observability (Prometheus/Grafana). |

Both tiers share the same nginx edge security pipeline (RASP/behavioral/geo
ingestion, trust verification) and the same core backend (enrollment, threat
ingestion, SOC dashboard) — the difference is purely in which supporting
infrastructure is present.

## Platform matrix

| Platform | Minimal | Full |
|---|---|---|
| Windows | `install-windows-minimal.ps1` + `docker-compose.minimal.windows.yml` | `install-windows.ps1` + `docker-compose.full.windows.yml` |
| Ubuntu | `install-ubuntu.sh` (`PAYSHIELD_TIER=minimal`) + `docker-compose.minimal.ubuntu.yml` | `install-ubuntu.sh` (`PAYSHIELD_TIER=full`, default) + `docker-compose.full.ubuntu.yml` |
| Generic Linux (any distro, Docker pre-installed) | `install-linux.sh` (`PAYSHIELD_TIER=minimal`) + `docker-compose.minimal.linux.yml` | `install-linux.sh` (`PAYSHIELD_TIER=full`, default) + `docker-compose.full.linux.yml` |
| AWS EC2 — Ubuntu AMI | `install-ubuntu.sh` (`PAYSHIELD_TIER=minimal`) + `docker-compose.minimal.aws-ubuntu.yml` | `install-ubuntu.sh` (`PAYSHIELD_TIER=full`) + `docker-compose.full.aws-ubuntu.yml` |

`install-windows.ps1` is the original, proven, working installer and is
never modified — `install-windows-minimal.ps1` is a separate script derived
from it. Likewise, every `docker-compose.*.yml` in this repo is a copy
derived from the proven originals in `payshield-backend/` (`docker-compose.yml`
for full, `docker-compose.minimal.yml` for minimal) with only platform-specific
notes added — the actual service definitions are never hand-edited to differ
between platforms.

After changing either original, regenerate all eight copies (each keeps its
own header) with `python tools/sync_compose.py`; `python tools/sync_compose.py
--check` exits non-zero when any copy is out of date.

## Two different AWS paths — read this first

There are **two, deliberately separate** ways this stack ends up running on AWS:

**`payshield-backend/deploy.sh` (Amazon Linux)** — the real, already-running,
months-proven production/demo deployment. Targets Amazon Linux 2023
(`dnf`/`firewalld`/`ec2-user`), stores secrets in AWS Secrets Manager, uses
`.env.demo.local`, installs to `/opt/nonashield`, and runs against a fixed
Elastic IP configured in `deploy-config.sh`. **Nothing in this repo touches,
modifies, or supersedes that deployment.**

**`install-ubuntu.sh` + this repo's `*.aws-ubuntu.yml` files (Ubuntu)** — a
separate, generic, reusable installer for a **new** customer's own Ubuntu-AMI
EC2 instance (or any Ubuntu box, cloud or on-premises). Uses `apt`/`ufw`, the
`ubuntu` user (not `ec2-user` — that's Amazon Linux's default user), a plain
`.env` file, and installs to `/opt/payshield` (not `/opt/nonashield`).

**Never run `install-ubuntu.sh` against the EC2 instance `deploy.sh`
manages.** Pick based on which OS the target instance is actually running —
Amazon Linux always means `deploy.sh`; Ubuntu always means this repo.

## Quick start

For the exact step-by-step sequence to run on a **new machine** (path
verification, clearing a stale `.env`, then the install command itself), see
[SETUP.md](SETUP.md).

### Windows (PowerShell, as Administrator)

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force

# Full stack (all services)
.\install-windows.ps1

# Minimal stack (nginx + backend + postgres + redis only)
.\install-windows-minimal.ps1
```

Or double-click `installation.bat`, which delegates to `install-windows.ps1`.

### Ubuntu (bare metal, VM, or a new AWS EC2 Ubuntu-AMI instance)

```bash
# Full stack (default)
sudo bash install-ubuntu.sh

# Minimal stack
sudo PAYSHIELD_TIER=minimal bash install-ubuntu.sh
```

### Generic Linux (any distro with Docker already installed)

```bash
# Full stack (default)
sudo bash install-linux.sh

# Minimal stack
sudo PAYSHIELD_TIER=minimal bash install-linux.sh
```

### After install (any platform)

```bash
# Start
docker compose -f <docker-compose.*.yml> --env-file .env up -d
# or, on Windows: start-demo.bat

# Reset demo data (drops volumes, re-migrates, re-seeds)
# on Windows: reset-demo.bat
docker compose -f <docker-compose.*.yml> down -v
docker compose -f <docker-compose.*.yml> up -d
docker exec payshield-backend alembic upgrade head
```

## Environment variables

Exported before running `install-ubuntu.sh` / `install-linux.sh`, or passed
as `-Action`/parameters on the Windows scripts:

| Variable | Values | Default | Meaning |
|---|---|---|---|
| `PAYSHIELD_ENV` | `development` \| `uat` \| `production` | `development` | Sets `APP_ENV` in the generated `.env`. Controls demo-vs-live backend behavior (see `payshield-backend/app/config/environment.py`). |
| `PAYSHIELD_TIER` | `full` \| `minimal` | `full` | Which service set and compose file to use. |
| `PAYSHIELD_DOMAIN` | any hostname | `localhost` | Hostname baked into the generated nginx TLS certificate. |
| `INSTALL_DIR` | any path | `/opt/payshield` | Where the stack is cloned/copied to (Linux/Ubuntu only). |
| `SKIP_OLLAMA` | `1` to skip | unset | Skips the ~4 GB LLaMA3 model pull — speeds up full-tier dev setup. No effect on minimal tier (Ollama isn't part of it). |
| `USE_AWS_SM` | `true` \| `false` | `false` in the generated `.env` | Whether the backend sources secrets from AWS Secrets Manager. **Not required** — a customer without an AWS account sets/leaves this `false` and supplies secrets directly via `.env`; the backend refuses to start in `uat`/`production` either way if `API_SECRET_KEY`/`JWT_SECRET`/`NEO4J_PASSWORD` are still placeholder values, regardless of which path supplies the real ones. |

Every install script generates its own `.env` with cryptographically random
secrets on first run (`API_SECRET_KEY`, `JWT_SECRET`, `BACKEND_API_KEY`,
`CSRF_SECRET`, `EDGE_INTERNAL_SECRET`, a JWT RSA key pair, and per-service
passwords for Postgres/Neo4j/MinIO/Grafana/Airflow on the full tier) — it
will not overwrite an existing `.env`.

Two things every tier needs that are **not** auto-generated — set these in
`.env` yourself before `up`:

- `SSL_DIR` — directory containing `fullchain.pem` + `privkey.pem` for nginx TLS.
- `GEOIP_DIR` — directory containing MaxMind `GeoLite2-*.mmdb` files (geo
  enrichment / ASN reputation blocking in the nginx edge pipeline).

## `install-*.sh` actions

Pass as the first argument (Linux/Ubuntu scripts) or via `-Action` (Windows):

| Action | Effect |
|---|---|
| `install` / `up` | Full install (checks Docker, generates env, TLS, starts the stack) — default |
| `down` | Stop containers, keep data |
| `destroy` | Stop containers **and delete all volumes/data** |
| `restart` | Restart all containers |
| `logs` | Tail all service logs |
| `status` | Container status |
| `health` | HTTP health-check all services |
| `migrate` | Run Alembic DB migrations |
| `update` | Pull latest images + rebuild |
| `uninstall` | Remove containers and volumes (does not touch Docker itself) |
| `shell` | (Windows only) Open a bash shell inside the backend container |

## Repo contents

```
install-windows.ps1                     Full-tier Windows installer (proven, never modified)
install-windows-minimal.ps1             Minimal-tier Windows installer (derived from the above)
install-ubuntu.sh                       Ubuntu installer, both tiers via PAYSHIELD_TIER
install-linux.sh                        Generic-Linux installer, both tiers via PAYSHIELD_TIER
installation.bat / start-demo.bat / reset-demo.bat   Windows convenience wrappers

docker-compose.full.windows.yml         Full tier — copy of payshield-backend/docker-compose.yml
docker-compose.full.ubuntu.yml          Full tier — same, Ubuntu-specific notes
docker-compose.full.linux.yml           Full tier — same, generic-Linux notes
docker-compose.full.aws-ubuntu.yml      Full tier — same, for a NEW AWS EC2 Ubuntu-AMI instance

docker-compose.minimal.windows.yml      Minimal tier — copy of payshield-backend/docker-compose.minimal.yml
docker-compose.minimal.ubuntu.yml       Minimal tier — same, Ubuntu-specific notes
docker-compose.minimal.linux.yml        Minimal tier — same, generic-Linux notes
docker-compose.minimal.aws-ubuntu.yml   Minimal tier — same, for a NEW AWS EC2 Ubuntu-AMI instance
```

## Related repositories

- [`nonashield-backend`](https://github.com/NonaShield/nonashield-backend) — the FastAPI backend these scripts deploy.
- [`nonashield-apigateway`](https://github.com/NonaShield/nonashield-apigateway) — the nginx/OpenResty edge gateway these scripts deploy.
- [`nonashield-sdk`](https://github.com/NonaShield/nonashield-sdk) — the Kotlin Multiplatform mobile SDK that talks to this stack.
