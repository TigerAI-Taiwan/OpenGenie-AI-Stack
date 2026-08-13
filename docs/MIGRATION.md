# Migration guide — v2.0.0 to v3.0.0

**Applies to:** upgrading an existing v2.x install to **v3.0.0**.
**Fresh installs do not need this document** — follow the README instead.

The three deployment stacks (`amd-compose-stack`, `nvidia-compose-stack`,
`arm64-compose-stack`) have been merged into one `deployments/compose-stack/`.
The platform is now selected at run time by `TIGER_PLATFORM` instead of by
which directory you deploy from.

v3.0.0 is a **breaking** release. Six changes need action on an existing
machine, and two of them stop services from working until you act:

| # | Change | Action required |
|:-:|---|---|
| 1 | Ollama moves to a named volume | Copy your models, or they re-download |
| 2 | OpenWebUI worker containers removed | Set `OWUI_UVICORN_WORKERS` |
| 3 | Lemonade is AMD-only | NVIDIA/ARM64: uninstall the systemd units |
| 4 | **MQTT requires authentication** | **Set `MQTT_USERNAME` / `MQTT_PASSWORD` or MQTT stops working** |
| 5 | env file precedence reversed | Check for keys defined in two places |
| 6 | `.env.example` is per platform | Copy the one matching your hardware |

Back up before you start. Every section below is ordered so you can work
straight down the page.

---

## TL;DR

```bash
# 1. Back up first. Do not skip this.
sudo bash deployments/compose-stack/08-backup-recovery/resource/_shared/backup-tigerai.sh

# 2. Move your Ollama models (amd and nvidia only — see below)
# 3. Merge your .env
# 4. Redeploy
sudo -E bash deployments/tiger-deploy.sh
sudo -E bash deployments/compose-stack/master-deploy.sh all
```

The rest of this document explains what changed and why each step matters.

---

## 1. Ollama models move to a named volume

**Affects: AMD and NVIDIA. ARM64 users are already on the new layout.**

The AMD and NVIDIA stacks bind-mounted the host directory `/var/lib/ollama`
into the Ollama container. All three platforms now use a Docker named volume,
`ollama_data`, which is what the ARM64 stack already did.

Nothing is deleted by the upgrade, but the container will come up pointing at
an **empty** store and re-download every model on first use. If you have tens
of gigabytes of models, copy them across first.

```bash
# Stop the AI interface so nothing writes during the copy
sudo -E bash deployments/compose-stack/03-ai-interface-ollama-openwebui-redis/deploy.sh down

# Create the named volume and copy the old contents into it
docker volume create 03-ai-interface-ollama-openwebui-redis_ollama_data
docker run --rm \
  -v /var/lib/ollama:/from:ro \
  -v 03-ai-interface-ollama-openwebui-redis_ollama_data:/to \
  alpine sh -c 'cd /from && cp -a . /to/'

# Verify: this should list your models
docker run --rm \
  -v 03-ai-interface-ollama-openwebui-redis_ollama_data:/data \
  alpine ls /data/models/manifests/registry.ollama.ai/library
```

The volume name is `<module directory>_<volume>`, because Compose prefixes
named volumes with the project name and the project name comes from the module
directory. If you renamed the module directory, adjust accordingly.

`/var/lib/ollama` is left untouched. Delete it once you have confirmed the new
setup works.

If you would rather not move anything, keep the old behaviour by adding this to
`deployments/compose-stack/03-ai-interface-ollama-openwebui-redis/docker-compose.<your platform>.yaml`:

```yaml
services:
  ollama:
    volumes:
      - /var/lib/ollama:/root/.ollama
```

---

## 2. OpenWebUI no longer runs worker containers

**Affects: everyone.**

Previously OpenWebUI scaled by running extra containers — two fixed ones
(`openwebui-worker-01`, `openwebui-worker-02`) on NVIDIA, one scalable
`openwebui-worker` on AMD and ARM64. Those are gone. There is now a single
`openwebui-main` container running several uvicorn worker processes inside it,
plus a short-lived `openwebui-migrate` container that applies database
migrations before `openwebui-main` starts.

Why: uvicorn spawns its workers rather than forking them, so every worker
imports the application from scratch — and OpenWebUI runs its Alembic
migrations at import time. With N worker containers or N in-container workers
you got N concurrent `alembic upgrade head` runs against one database, and the
losing runs failed **silently** (the error is caught and logged, and the
process serves traffic anyway). Running migrations once, up front, in a
container that is allowed to fail loudly removes that race.

**Set the worker count with `OWUI_UVICORN_WORKERS`**, not by scaling the
service:

```ini
# deployments/compose-stack/.env
OWUI_UVICORN_WORKERS=2
```

`docker compose up --scale openwebui-worker=N` no longer applies to this
module.

The old worker containers are removed automatically on the next
`deploy.sh down` or `deploy.sh restart`, which now pass `--remove-orphans`. If
you upgraded some other way and still see them:

```bash
docker rm -f openwebui-worker-01 openwebui-worker-02 openwebui-worker
```

Related settings that come with this change, all overridable in `.env`:

| Variable | Default | Purpose |
|---|---|---|
| `OWUI_UVICORN_WORKERS` | `2` | uvicorn processes inside `openwebui-main` |
| `OWUI_VECTOR_DB` | `qdrant` | Chroma is a local SQLite file and is not safe across processes; Qdrant (phase 05) is |
| `OWUI_DB_POOL_SIZE` | `5` | Caps idle DB connections per process |
| `OWUI_DB_POOL_MAX_OVERFLOW` | `5` | Caps burst DB connections per process |
| `OWUI_USER_ACTIVE_INTERVAL` | `300` | Throttles the `last_active_at` write |

> Phase 03 deploys before phase 05, so Qdrant does not exist yet the first time
> OpenWebUI starts. That is expected: OpenWebUI starts normally, `/health`
> returns 200 and chat works. Only RAG queries fail until phase 05 is up, and
> no restart is needed afterwards.

---

## 3. Lemonade is now AMD-only

**Affects: NVIDIA and ARM64. AMD is unchanged.**

`06-ai-core-lemonade` is a Vulkan/ROCm inference engine and is deployed on AMD
alone. On NVIDIA and ARM64 the module now exits immediately with a skip
message, and LLM inference is Ollama in phase 03.

The NVIDIA and ARM64 stacks used to ship their own copy of this module, which
installed native systemd units (`lemonade-edu`, `lemonade-rag`,
`lemonade-embed`). That was never intended — neither platform's
`.env.example` defines a single Lemonade variable, so those units ran entirely
on hardcoded fallbacks.

**The upgrade does not remove the units for you.** They will keep running,
holding VRAM, unmanaged by any module. Remove them by hand:

```bash
# NVIDIA / ARM64 only
sudo systemctl disable --now lemonade-edu lemonade-rag lemonade-embed
sudo rm -f /etc/systemd/system/lemonade-{edu,rag,embed}.service
sudo rm -f /usr/local/bin/tiger-mode-edu /usr/local/bin/tiger-mode-rag
sudo systemctl daemon-reload
sudo systemctl reset-failed

# Confirm nothing is left listening on 8800 / 8801 / 8802
ss -ltnp | grep -E ':(8800|8801|8802)' || echo "clear"
```

Downloaded model files under `MODELS_DIR` are left alone. Delete them once you
are sure you do not want to roll back.

Health checks and monitoring follow the same rule: the Lemonade probes now
live in the AMD entry points only, so NVIDIA and ARM64 no longer report
Lemonade as a failing service.

---

## 4. The MQTT broker now requires authentication

**Affects: everyone. This will break MQTT until you set credentials.**

The broker previously ran with `allow_anonymous true` and no password file,
generated onto the host by `deploy.sh`. Anything that could reach port 1883
could publish and subscribe — while the healthcheck passed credentials that
were never checked.

Set these in `deployments/compose-stack/.env` **before** redeploying:

```ini
MQTT_USERNAME=tigerai
MQTT_PASSWORD=<pick something>
```

Every consumer uses this one pair: the mosquitto healthcheck,
`tiger-monitor.sh`, and `monitor_device.py`. The password file is generated
inside the container at start-up and never touches the host.

If you leave the defaults, the broker comes up as `tigerai` / `CHANGE_ME` —
authenticated, but with a password everyone can read in this document.

The old host-side config at `<BASE_DIR>/mosquitto/config/mosquitto.conf` is no
longer mounted and has no effect. Delete it once the new setup works.

### The `LANDING_LOCAL_MQTT_*` variables are gone

`monitor_device.py` used to read `LANDING_LOCAL_MQTT_HOST` / `_PORT` / `_USER`
/ `_PASSWORD`. Those names were vestigial — there is no landing component in
this stack — and they are now `MQTT_HOST`, `MQTT_PORT`, `MQTT_USERNAME`,
`MQTT_PASSWORD`, shared with everything else.

> The old default port was **9013**, which nothing in this stack listens on.
> `monitor_device.py` could never connect to the broker. It defaults to 1883
> now. If you had set `LANDING_LOCAL_MQTT_PORT` to something that worked,
> carry the value over to `MQTT_PORT`.

---

## 5. Environment file precedence is reversed

**Affects: anyone who keeps a `.env` in a module directory.**

| | Old | New |
|---|---|---|
| Highest priority | `deployments/.env` | `<module>/.env` |
| | `<stack>/.env` | `<stack>/.env` |
| | `<stack>/tiger-tuning.env` | `<stack>/tiger-tuning.env` |
| Lowest priority | `<module>/.env` | — |

Two changes at once:

1. **The order flipped.** It used to be outer-overrides-inner; a value in the
   stack-level `.env` beat the same key in a module's `.env`. Now the more
   specific file wins, which is the conventional direction.
2. **`deployments/.env` is gone.** Only the NVIDIA stack's modules ever read
   it. Move anything you kept there into
   `deployments/compose-stack/.env`.

If you only ever used the stack-level `.env` — the documented setup — nothing
changes for you. If you set the same key in both a module `.env` and the stack
`.env`, the module value now wins where it used to lose, **and nothing will
warn you about it.** Check before upgrading:

```bash
# List keys defined in more than one place
cat deployments/*-compose-stack/.env deployments/*-compose-stack/*/.env 2>/dev/null \
  | grep -vE '^\s*#|^\s*$' | cut -d= -f1 | sort | uniq -d
```

---

## 6. `.env.example` is now per platform

`deployments/compose-stack/` ships `.env.amd.example`, `.env.nvidia.example`
and `.env.arm64.example`. They are deliberately not merged into one file: the
platforms define different keys, and some keys must be *absent* rather than
empty on a given platform.

Copy the one matching your hardware:

```bash
cp deployments/compose-stack/.env.nvidia.example deployments/compose-stack/.env
```

Then merge in the values from your old `deployments/<platform>-compose-stack/.env`.

> Do not put inline comments in `.env`. A `#` with no preceding space is
> treated as part of the value by Compose's `--env-file`, while the shell's
> `source` tries to execute it. The two halves of the stack then disagree
> about what the value is, and only one of them complains.

---

## 7. Deployment commands

The entry point is unchanged in spirit, but there is one stack instead of three
and it needs `TIGER_PLATFORM`:

```bash
# Detects the platform, exports TIGER_PLATFORM, runs the hardware advisor
sudo -E bash deployments/tiger-deploy.sh

# Then the full deployment
sudo -E bash deployments/compose-stack/master-deploy.sh all
```

To run a single module directly, set the platform yourself:

```bash
TIGER_PLATFORM=nvidia sudo -E bash \
  deployments/compose-stack/02-database-postgres-pgadmin/deploy.sh all
```

`master-deploy.sh` refuses to guess the platform. If `TIGER_PLATFORM` is unset
it stops with an error rather than picking one, because guessing wrong pulls
the wrong GPU image.

Two subcommands that previously existed on only some platforms are now
available everywhere: `restart` (was ARM64 only) and `restore` (was AMD and
NVIDIA only).

### Scheduled jobs carry the platform

The nightly VRAM purge cron entry and the `tiger-monitor` systemd unit now
carry `TIGER_PLATFORM` explicitly, because cron and systemd both start with a
nearly empty environment. This is baked in when the installer runs.

**If you change platform, re-run the installers.** Editing `.env` does not
update an already-installed cron entry or unit file, and both will keep
looking completely normal:

```bash
sudo -E bash deployments/compose-stack/08-backup-recovery/deploy.sh
sudo -E bash deployments/compose-stack/09-monitoring-alerting/deploy.sh
```

---

## 8. Module renames and moved files

**`00-system-setup-rocm-docker` and `00-system-setup-nvidia-docker` are now one
module**, `00-system-setup-gpu-driver-and-docker`. The per-platform installers
moved to `resource/<platform>/install.sh`; there is no shared body, because
installing ROCm, CUDA on x86 and CUDA on aarch64 have little in common.

**Scripts you may have invoked directly have moved into `resource/`:**

| Was | Now |
|---|---|
| `07-validation-stack/check-health.sh` | `07-validation-stack/resource/_shared/check-health.sh` |
| `08-backup-recovery/backup-tigerai.sh` | `08-backup-recovery/resource/_shared/backup-tigerai.sh` |
| `08-backup-recovery/restore-tigerai.sh` | `08-backup-recovery/resource/_shared/restore-tigerai.sh` |
| `08-backup-recovery/vram-purge.sh` | `08-backup-recovery/resource/_shared/vram-purge.sh` |
| `09-monitoring-alerting/tiger-monitor.sh` | `09-monitoring-alerting/resource/_shared/tiger-monitor.sh` |
| `05-rag-stack-.../monitor_device.py` | `05-rag-stack-.../resource/_shared/monitor_device.py` |
| `10-observability-grafana/prometheus/prometheus-amd.yml` | `10-observability-grafana/resource/amd/prometheus.yml` |
| `10-observability-grafana/grafana/provisioning/` | `10-observability-grafana/resource/<platform>/grafana/provisioning/` |

Prefer `master-deploy.sh test` and the module `deploy.sh` entry points over
calling these directly — they resolve the paths for you.

> If you wrote your own scripts or cron entries that call the old paths, update
> them. The old paths simply will not exist, so this fails loudly rather than
> silently.

**`monitor_device.py` now reads its `.env` files in the same order as the shell
scripts** (tuning, then stack, then module — module wins). It previously used
the opposite order, giving the stack-level file priority, so the two halves of
the deployment disagreed about the same three files. Only matters if you set
the same MQTT key in more than one place.

**The database rename migration scripts were repaired.** They force-stop the
application before taking the `pg_dump` snapshot by driving its compose file,
and they still referenced `docker-compose.yaml`. Under the merged layout that
file no longer exists, so the stop would have quietly become a no-op and the
application would have kept writing during the dump. They now use
`docker-compose.base.yaml` plus the platform overlay.

---

## 9. Smaller behaviour changes

- **`01-infra` `all` no longer force-recreates containers.** The NVIDIA stack
  used to run `down` followed by `up -d --force-recreate` on every invocation.
  It is now a plain idempotent `up -d`. Use `restart` when you actually want a
  cycle.
- **`02-database` `restart` no longer redeploys.** The AMD stack ran
  `down && deploy.sh all`; it is now `compose restart`, which keeps volumes and
  skips the bootstrap wait.
- **`AMD` users: `PG_IMAGE` still works.** The AMD stack used `PG_IMAGE` where
  the others used `POSTGRES_IMAGE`. Both continue to work on their respective
  platforms.

---

## 10. Fixes you get for free

These were broken before the merge and are fixed by it. No action needed.

- **Health checks on NVIDIA and ARM64 reported Lemonade as failed even when it
  was healthy.** The check used `grep -q "200|401"`, and basic `grep` treats
  `|` literally, so it never matched a real HTTP status.
- **AMD hosts were never actually monitored.** `tiger-monitor.sh` on AMD had an
  empty check function — the systemd service installed correctly and looped
  every 60 seconds doing nothing.
- **NVIDIA never alerted when a service went down.** Only CPU overload raised
  an MQTT alarm; a dead service was recorded in the health report but never
  alerted on.
- **On NVIDIA the backup and recovery scripts were never made executable**,
  because that stack shipped no `deploy.sh` for phase 08.

---

## 11. Known issue: VRAM purge and Lemonade

Not fixed by this migration, and worth knowing about:

- On **AMD**, Lemonade runs as containers, but `vram-purge.sh` releases it with
  `systemctl restart`, which fails and is swallowed. AMD's Lemonade VRAM is not
  actually freed by the nightly purge — only Ollama's is.
- On **NVIDIA and ARM64**, the purge restarts a fixed list (`edu`, `rag`). The
  three Lemonade services are a mutually exclusive mode pair, so in EDU mode
  the purge *starts* `lemonade-rag`, which that mode deliberately stopped.
  `lemonade-embed` is never restarted on any platform.

Until this is addressed, run `tiger-mode-edu` or `tiger-mode-rag` after a purge
if you rely on a specific mode.

---

## Rolling back

The old stacks are still in the repository during the transition. To go back,
check out the previous release and redeploy from
`deployments/<platform>-compose-stack/`. Your PostgreSQL data, named volumes
and `/var/lib/ollama` are all untouched by the upgrade, so a rollback does not
lose data — but if you have run OpenWebUI on the new topology, its database has
been migrated forward and may not be readable by an older OpenWebUI image.
Restore from the backup you took in step 1 if that happens.
