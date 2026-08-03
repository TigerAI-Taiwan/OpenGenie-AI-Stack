# OpenGenie compose-stack change record

> Source: Open-AI-Stack `feat/remove-node-red` (merge-base `e775fb0`).
> Filtered out: the proprietary portal/gateway/bridge directories, image digest pins, licensed n8n
> features (licensing / federated-auth / event forwarding), the portal env vars, **and — per this run — all
> MQTT host power-agent / mosquitto-hardening items** (`power_agent.py`, `setup-power-agent.sh`, `acl.file`,
> `mosquitto.conf`, the `05-rag-stack` compose/env MQTT changes, and the `MQTT_*` auth additions in
> `tiger-monitor.sh` / `master-deploy.sh`).
> Applies to the same three compose stacks in OpenGenie (`{nvidia,amd,arm64}-compose-stack/`).

## Summary

| Concern | Files (per stack) | What changed |
|---|---|---|
| **Remove Node-RED** | `00-system-setup-*/deploy.sh`, `07-validation-stack/check-health.sh`, `09-monitoring-alerting/tiger-monitor.sh`, `08-backup-recovery/{backup,restore}-tigerai.sh`, `master-deploy.sh` | Drop the native Node-RED install, its health/monitor probes, its backup/restore paths, and renumber step counters |
| **Per-database isolation — n8n** | `04-automation-n8n/{deploy.sh,docker-compose.yaml}`, `.env.example` | n8n moves off the shared `tigerai` DB + `n8n` schema onto a dedicated `n8n` database (`public` schema); `deploy.sh` `ensure_db` creates it |
| **Per-database isolation — OpenWebUI** | `03-ai-interface-ollama-openwebui-redis/{deploy.sh,docker-compose.yaml}`, `.env.example` | OpenWebUI moves off `tigerai` + `search_path=openwebui` onto a dedicated `openwebui` database; `deploy.sh` `ensure_db` creates it |
| **Drop per-schema bootstrap** | `02-database-postgres-pgadmin/deploy.sh` | Remove `init_schemas()` (per-DB replaces per-schema) |
| **DB-rename migrations** | `migrations/n8n-db-rename-migration.sh`, `migrations/openwebui-db-rename-migration.sh` (new, stack root) | Idempotent, force-stop, atomic migration from the old schema-in-`tigerai` layout to the dedicated DBs |
| **Dynamic multi-DB backup/restore** | `08-backup-recovery/{backup,restore}-tigerai.sh` | Backup enumerates every non-template DB dynamically (`db_<name>.sql.gz`); restore loops per-DB with a legacy single-DB fallback + confirmation gate + path manifest |
| **Grafana PostgreSQL backend** | `10-observability-grafana/{deploy.sh,docker-compose.yaml}`, `.env.example` | Grafana switches its internal state store from SQLite to a dedicated `grafana` PostgreSQL database; `deploy.sh` `ensure_db` creates it |

Consistency: backup/restore scripts and both migration scripts are **byte-identical across all three
stacks**. The n8n/OpenWebUI DB edits and the Grafana `GF_DATABASE_*` block are the **same edit** in each
stack (unrelated per-stack md5 deltas are pre-existing GPU/layout differences). Node-RED removal is the
same change applied to each stack's own host-setup script (`00-system-setup-nvidia-docker` for
nvidia/arm64, `00-system-setup-rocm-docker` for amd).

---

## Details

### 1. Remove Node-RED

**Why.** The native Node-RED install broke (upstream renamed the installer asset) and Node-RED is no longer
part of the stack. Removed from host setup, health checks, monitoring, backup/restore, and the deploy step
counters.

**Where.** Each stack's host-setup `deploy.sh`, plus `07-validation-stack/check-health.sh`,
`09-monitoring-alerting/tiger-monitor.sh`, `08-backup-recovery/{backup,restore}-tigerai.sh`,
`master-deploy.sh`.

Host setup (`00-system-setup-nvidia-docker/deploy.sh`; amd is `00-system-setup-rocm-docker/deploy.sh`) —
delete the whole `install_nodered()` function, its call in main, the three `NODE_RED_*` config vars, and
fix the `[n/6]` → `[n/5]` step labels (amd: `[n/4]` → `[n/3]`):

```bash
# delete these config vars near the top:
NODE_RED_MAX_OLD_SPACE=${NODE_RED_MAX_OLD_SPACE:-"1024"}
NODE_RED_SETTINGS_FILE=${NODE_RED_SETTINGS_FILE:-"/root/.node-red/settings.js"}
NODE_RED_PASS=${NODE_RED_PASS:-"tigerai"}

# delete the entire "install_nodered()" function (native install + bcrypt password
# injection into settings.js) and its call in the main sequence:
install_nodered      # <-- remove this call
```

Health check (`07-validation-stack/check-health.sh`) — drop the probe:

```bash
check_endpoint "Node-RED (Native)" "http://$TARGET_HOST:1880" "200" || true   # <-- remove
```

Monitor (`09-monitoring-alerting/tiger-monitor.sh`) — drop from the service list:

```bash
"Node-RED:http://$TARGET_HOST:1880"   # <-- remove from SERVICES=( ... )
```

Backup (`08-backup-recovery/backup-tigerai.sh`) — remove the `backup_nodered()` function and its call
(covered in full by the rewrite in §6). Restore (`restore-tigerai.sh`) — remove `restore_nodered()`, the
`NODERED_DATA` var, and the `nodered` case/usage token (also covered in §6).

---

### 2. Per-database isolation — n8n

**Why.** n8n shared the `tigerai` database via an `n8n` schema. A dedicated `n8n` database (default `public`
schema) isolates it from other services — a shared DB previously caused a cross-service schema wipe.

**Where.** `04-automation-n8n/docker-compose.yaml` (main + worker) and `04-automation-n8n/deploy.sh`.

`docker-compose.yaml` — both `n8n-main` and `n8n-worker` environment blocks:

```yaml
      - DB_POSTGRESDB_DATABASE=${DB_POSTGRESDB_DATABASE:-n8n}
      - DB_POSTGRESDB_SCHEMA=${DB_POSTGRESDB_SCHEMA:-public}
```

`deploy.sh` — change the defaults and replace the schema-creation helper with a DB-creation helper:

```bash
export DB_POSTGRESDB_DATABASE="${DB_POSTGRESDB_DATABASE:-n8n}"
export DB_POSTGRESDB_SCHEMA="${DB_POSTGRESDB_SCHEMA:-public}"

# --- 1) Ensure dedicated n8n database exists ---
ensure_db() {
    LOG "🔍 Ensuring dedicated PostgreSQL database '$DB_POSTGRESDB_DATABASE' for n8n..."
    local PG_CONTAINER=${DB_POSTGRESDB_HOST:-postgres}
    if ! docker ps --format '{{.Names}}' | grep -qx "$PG_CONTAINER"; then
        ERROR "PostgreSQL container '$PG_CONTAINER' not found. Please deploy infrastructure first."
    fi
    # CREATE DATABASE has no IF NOT EXISTS and cannot run in a transaction — SELECT-guard (idempotent).
    local DB_EXISTS
    DB_EXISTS=$(docker exec -i "$PG_CONTAINER" /usr/bin/env PGPASSWORD="$DB_POSTGRESDB_PASSWORD" \
        psql -U "$DB_POSTGRESDB_USER" -d postgres -tAc \
        "SELECT 1 FROM pg_database WHERE datname='$DB_POSTGRESDB_DATABASE';" 2>/dev/null || true)
    if [ "$DB_EXISTS" = "1" ]; then
        LOG "✅ Database '$DB_POSTGRESDB_DATABASE' already exists — skipping creation."
    else
        LOG "Creating database '$DB_POSTGRESDB_DATABASE' (owner $DB_POSTGRESDB_USER)..."
        docker exec -i "$PG_CONTAINER" /usr/bin/env PGPASSWORD="$DB_POSTGRESDB_PASSWORD" \
            psql -U "$DB_POSTGRESDB_USER" -d postgres \
            -c "CREATE DATABASE $DB_POSTGRESDB_DATABASE OWNER $DB_POSTGRESDB_USER;" \
            || ERROR "Failed to create database '$DB_POSTGRESDB_DATABASE'."
        LOG "✅ Database '$DB_POSTGRESDB_DATABASE' created."
    fi
    # Schema 'public' already exists in every new database — no schema creation needed.
}
```

Then call `ensure_db` (was `check_db_schema`) in the `all`, `main`, and `worker` cases.

---

### 3. Per-database isolation — OpenWebUI

**Why.** OpenWebUI used `tigerai` with `?options=-csearch_path=openwebui`. Alembic ignores the search-path
option, so migrations landed in `public` while the ORM looked in `openwebui` — crash loop. A dedicated
`openwebui` database fixes it.

**Where.** `03-ai-interface-ollama-openwebui-redis/docker-compose.yaml` (all three OpenWebUI services) and
`03-ai-interface-ollama-openwebui-redis/deploy.sh`.

`docker-compose.yaml` — `openwebui-main` + both workers, drop the `search_path` option:

```yaml
      - DATABASE_URL=postgresql://${PG_USER:-adm}:${PG_PASS:-tigerai}@${PG_HOST:-postgres}:5432/${OWUI_DB_NAME:-openwebui}
```

`deploy.sh` — replace `check_db_schema()` with a DB-creating `ensure_db()`:

```bash
# --- Ensure the dedicated `openwebui` database exists (DB isolation) ---
ensure_db() {
    LOG "🔍 Verifying PostgreSQL connection and OpenWebUI database..."
    local PG_CONTAINER="${PG_HOST:-postgres}"
    if ! docker ps --format '{{.Names}}' | grep -qx "$PG_CONTAINER"; then
        ERROR "PostgreSQL container '$PG_CONTAINER' not found. Please deploy 02-database first."
    fi
    local DB_USER="${PG_USER:-adm}"
    local DB_NAME="${OWUI_DB_NAME:-openwebui}"
    local DB_EXISTS
    DB_EXISTS=$(docker exec -i "$PG_CONTAINER" /usr/bin/env PGPASSWORD="${PG_PASS:-tigerai}" \
        psql -U "$DB_USER" -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME';")
    if [ "$DB_EXISTS" = "1" ]; then
        LOG "✅ Database '$DB_NAME' already exists."
    else
        LOG "⚠️  Database '$DB_NAME' does not exist. Creating it now..."
        docker exec -i "$PG_CONTAINER" /usr/bin/env PGPASSWORD="${PG_PASS:-tigerai}" \
            psql -U "$DB_USER" -d postgres -c "CREATE DATABASE $DB_NAME OWNER $DB_USER;" \
            || ERROR "Failed to create database '$DB_NAME'."
        LOG "✅ Database '$DB_NAME' created successfully."
    fi
}
```

Call `ensure_db` in both the `all` case and the `openwebui` case.

---

### 4. Drop per-schema bootstrap (`02-database`)

**Why.** With per-database isolation, the old per-schema bootstrap is obsolete.

**Where.** `02-database-postgres-pgadmin/deploy.sh` — delete `init_schemas()` and its two call sites:

```bash
# delete this function entirely:
init_schemas() {
    LOG " Initializing Schemas..."
    docker exec -i postgres psql -U "$PG_USER" -d "$PG_DB_NAME" -c "CREATE SCHEMA IF NOT EXISTS n8n AUTHORIZATION $PG_USER;"
    docker exec -i postgres psql -U "$PG_USER" -d "$PG_DB_NAME" -c "CREATE SCHEMA IF NOT EXISTS openwebui AUTHORIZATION $PG_USER;"
}
# and drop the "init_schemas" calls from the `all` and `postgres` cases.
```

---

### 5. DB-rename migration scripts (new)

**Why.** Existing deployments already hold n8n/OpenWebUI data inside `tigerai` (schemas `n8n` / `openwebui`).
These one-shot scripts migrate that data into the new dedicated databases, safely.

**Where.** Two **new** files at each stack root: `migrations/n8n-db-rename-migration.sh` and
`migrations/openwebui-db-rename-migration.sh`. They are **byte-identical across all three stacks** — copy
them verbatim from the source repo. Key properties:

- **Check-first / idempotent** — detect whether migration already happened and no-op if so.
- **Force-stop the app** before touching data (`docker compose ... stop` + verify no matching container
  is still running), so nothing writes mid-migration.
- **Atomic promote** — dump the source schema, restore into the new DB, then in one transaction:
  `BEGIN; DROP SCHEMA IF EXISTS public CASCADE; ALTER SCHEMA "<src>" RENAME TO public; GRANT ALL ON SCHEMA public TO "<user>"; COMMIT;`
- Preserve migration-state tables (n8n `migrations`, OpenWebUI `alembic_version`) and the app encryption
  keys (`N8N_SECRET` / `OWUI_SECRET_KEY` unchanged), so the app keeps working post-migration.
- Env cascade anchored to the script dir (`../tiger-tuning.env` → `../.env`).

> These are pure ops scripts — no proprietary/MQTT content. Copy the two files as-is.

---

### 6. Dynamic multi-DB backup / restore

**Why.** The old backup dumped a single hard-coded DB (`$PG_DB_NAME`) and Node-RED config. With per-service
databases, backup must cover **every** database automatically.

**Where.** `08-backup-recovery/backup-tigerai.sh` and `restore-tigerai.sh` — **byte-identical across all
three stacks**, copy verbatim. Highlights:

Backup — enumerate DBs dynamically, one gzip per DB, and track completeness:

```bash
backup_db() {
    LOG " [1/3] Dumping PostgreSQL Databases..."
    if ! docker ps --format '{{.Names}}' | grep -qx "$PG_CONTAINER"; then
        WARN "PostgreSQL container '$PG_CONTAINER' not running; skipping DB backup. Backup is INCOMPLETE."
        INCOMPLETE=1; return
    fi
    local db_list
    db_list=$(docker exec "$PG_CONTAINER" psql -U "$PG_USER" -d postgres -tAc \
        "SELECT datname FROM pg_database WHERE datistemplate=false AND datname NOT IN ('postgres')")
    local db
    while IFS= read -r db; do
        [ -z "$db" ] && continue
        LOG "Dumping database '$db'..."
        docker exec "$PG_CONTAINER" pg_dump -U "$PG_USER" "$db" | gzip > "${BACKUP_PATH}/db_${db}.sql.gz"
    done <<< "$db_list"
    LOG " Database dump completed."
}
```

Additional backup hardening in the same rewrite: SCRIPT_DIR-anchored env cascade (works under cron),
a `data-paths.manifest` recording each data archive's source path, basename-collision guard, an
`INCOMPLETE` flag that makes the script exit non-zero when anything was skipped.

Restore — loop over `db_*.sql.gz` (drop+recreate+import each), with a legacy `database.sql.gz →
$PG_DB_NAME` fallback, an interactive confirmation gate (`-y` / `ASSUME_YES=1` to bypass), and
manifest-driven data-dir restore so archives return to their exact recorded paths:

```bash
restore_db() {
    LOG " [1/2] Restoring PostgreSQL Databases..."
    local file db; local dbs=()
    for file in "${RESTORE_DIR}"/db_*.sql.gz; do
        [ -f "$file" ] || continue
        db=$(basename "$file" .sql.gz); db=${db#db_}; dbs+=("$db")
    done
    # ... legacy database.sql.gz fallback + confirm() gate ...
    for db in "${dbs[@]}"; do
        docker exec "$PG_CONTAINER" dropdb -U "$PG_USER" --if-exists "$db"
        docker exec "$PG_CONTAINER" createdb -U "$PG_USER" "$db"
        gunzip -c "${RESTORE_DIR}/db_${db}.sql.gz" | docker exec -i "$PG_CONTAINER" psql -U "$PG_USER" "$db"
    done
    LOG " Database restoration complete."
}
```

---

### 7. Grafana PostgreSQL backend

**Why.** Grafana used its default SQLite store, so dashboards/state lived in a local volume and did not
survive image upgrades cleanly. Switching to a dedicated `grafana` PostgreSQL database matches the k3s
deployment and makes state durable.

**Where.** `10-observability-grafana/docker-compose.yaml` (grafana service) and
`10-observability-grafana/deploy.sh`.

`docker-compose.yaml` — add the `GF_DATABASE_*` block (and parameterize the admin password):

```yaml
      - GF_SECURITY_ADMIN_PASSWORD=${GRAFANA_PASS:-tigerai}
      - GF_USERS_ALLOW_SIGN_UP=false
      # Use PostgreSQL as Grafana's internal DB (mirror k3s) so schema/state
      # survive image upgrades without relying on the local SQLite volume.
      - GF_DATABASE_TYPE=postgres
      - GF_DATABASE_HOST=postgres:${PG_PORT:-5432}
      - GF_DATABASE_NAME=${GF_DB_NAME:-grafana}
      - GF_DATABASE_USER=${PG_USER:-adm}
      - GF_DATABASE_PASSWORD=${PG_PASS:-tigerai}
      - GF_DATABASE_SSL_MODE=disable
```

`deploy.sh` — add the standard env-cascade load block plus an `ensure_db` that creates the `grafana`
database before launch:

```bash
ensure_db() {
    local PG_CONTAINER="${PG_CONTAINER:-postgres}"
    local DB_USER="${PG_USER:-adm}"; local DB_PASS="${PG_PASS:-tigerai}"
    local DB_NAME="${GF_DB_NAME:-grafana}"
    LOG " Ensuring dedicated PostgreSQL database '$DB_NAME' for Grafana..."
    if ! docker ps --format '{{.Names}}' | grep -qx "$PG_CONTAINER"; then
        ERROR "PostgreSQL container '$PG_CONTAINER' not found. Please deploy the database stack first."
    fi
    local DB_EXISTS
    DB_EXISTS=$(docker exec -i "$PG_CONTAINER" /usr/bin/env PGPASSWORD="$DB_PASS" \
        psql -U "$DB_USER" -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME';" 2>/dev/null || true)
    if [ "$DB_EXISTS" = "1" ]; then
        LOG " Database '$DB_NAME' already exists — skipping creation."
    else
        docker exec -i "$PG_CONTAINER" /usr/bin/env PGPASSWORD="$DB_PASS" \
            psql -U "$DB_USER" -d postgres -c "CREATE DATABASE \"$DB_NAME\" OWNER \"$DB_USER\";" \
            || ERROR "Failed to create database '$DB_NAME'."
        LOG " Database '$DB_NAME' created."
    fi
}
# ... then call `ensure_db` immediately before `docker compose up -d`.
```

**State migration.** Provisioned datasources/dashboards (from files) auto-recreate on the fresh PG backend.
UI-created state in the old SQLite `grafana.db` is **not** auto-migrated (Grafana has no clean SQLite→PG
path); export UI dashboards to JSON before switching if you need them. The dynamic multi-DB backup (§6)
covers the new `grafana` DB automatically.

---

### 8. `.env.example` (OpenGenie-relevant hunks)

```diff
 # --- 3) AI Interface (Ollama + OpenWebUI HA) ---
-OWUI_SCHEMA=openwebui
+OWUI_DB_NAME=openwebui  # OpenWebUI dedicated DB (public schema; DB isolation from n8n/litellm)

 # n8n DB
-DB_POSTGRESDB_DATABASE=tigerai
+DB_POSTGRESDB_DATABASE=n8n
-DB_POSTGRESDB_SCHEMA=n8n
+DB_POSTGRESDB_SCHEMA=public

 # --- 7) Monitoring & Observability ---
+# Grafana uses PostgreSQL as its internal DB (mirror k3s); this DB is auto-created
+# by 10-observability-grafana/deploy.sh. Reuses PG_USER / PG_PASS / PG_PORT above.
+GF_DB_NAME=grafana

+# --- 8) Backup ---
+PG_CONTAINER=postgres
+# DATA_DIRS: unset backs up everything under BASE_DIR; set (space-separated) to narrow.
+# DATA_DIRS="/home/wrt/TigerAI/node/n8n /home/wrt/TigerAI/qdrant"
```

(Also single-quoted the `CHANGE_ME` password placeholders: `PG_PASS`, `PGADMIN_PASS`, `GRAFANA_PASS`,
`DB_POSTGRESDB_PASSWORD` — cosmetic hardening against special chars.)

---

## Verification (in the OpenGenie repo, per stack)

```bash
# per-database isolation applied
grep -R "DB_POSTGRESDB_DATABASE:-n8n"      deployments/*-compose-stack/04-automation-n8n/docker-compose.yaml
grep -R "OWUI_DB_NAME:-openwebui"          deployments/*-compose-stack/03-ai-interface-*/docker-compose.yaml
grep -RL "search_path"                     deployments/*-compose-stack/03-ai-interface-*/docker-compose.yaml  # should NOT contain it

# Grafana on PG
grep -R "GF_DATABASE_TYPE=postgres"        deployments/*-compose-stack/10-observability-grafana/docker-compose.yaml

# Node-RED fully gone
grep -R "node-red\|nodered\|1880\|NODE_RED" deployments/*-compose-stack/ ; echo "expect: no matches"

# scripts parse; compose renders
bash -n deployments/*-compose-stack/{02,03,04}-*/deploy.sh \
        deployments/*-compose-stack/10-observability-grafana/deploy.sh \
        deployments/*-compose-stack/08-backup-recovery/*.sh \
        deployments/*-compose-stack/migrations/*.sh
docker compose -f deployments/nvidia-compose-stack/04-automation-n8n/docker-compose.yaml config >/dev/null
```

## Caveats

- **Order of operations on existing installs:** run the `migrations/*.sh` scripts (§5) **before** the new
  `ensure_db` deploy path takes over, or the app starts against an empty dedicated DB while the old data
  still sits in `tigerai`. On a fresh install there is no data to migrate — `ensure_db` just creates the
  empty DBs.
- Grafana SQLite→PG is not a data migration (§7) — provisioned content re-creates; export UI dashboards
  first if needed.
- The dynamic backup dumps **every** non-template database, so any future per-service DB is covered with no
  script change — but a bigger/rogue DB will enlarge backups silently.
- This record intentionally **omits** the MQTT host power-agent + mosquitto-hardening work present on the
  branch (excluded by request). If OpenGenie later wants the broker auth/ACL, port those separately.
