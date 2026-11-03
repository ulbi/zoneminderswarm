---
type: integration
title: Database Integration
description: Documents the MariaDB schema bootstrap (zm_create.sql), connection configuration, root vs app user separation, and table-count initialization check used by the ZoneMinder container.
tags: [database, mariadb, schema, initialization, credentials, zone-minder]
verified:
  - by: openwiki/0.7.3
    at: 2026-11-03T01:11:51.876Z
sources:
  - id: openwiki-source-b79fbbd921df689b4bbdc82f
    resource: repo://docker-compose.yml
  - id: openwiki-source-e9906b078522ed0a08c64ff1
    resource: repo://entrypoint.sh
generated: { by: "openwiki/0.7.3", at: "2026-11-03T01:11:51.876Z" }
---

# Database Integration

This page describes how the ZoneMinder container provisions and connects to its MariaDB backend. The flow is implemented in the container's `entrypoint.sh` and driven by environment variables supplied via `docker-compose.yml`.

## Architecture Overview

```mermaid
flowchart TD
    subgraph Compose["docker-compose.yml"]
        DB[(db: mariadb:10.9)]
        ZM[zoneminder service]
    end

    subgraph Entrypoint["entrypoint.sh (zoneminder container)"]
        Wait[Wait for DB port 3306]
        Count[Count tables in ZM_DB_NAME]
        Bootstrap[Bootstrap: CREATE DB, CREATE USER, GRANT, import zm_create.sql]
        ConfigDB[UPDATE Config SET ZM_OPT_USE_EVENTNOTIFICATION=1]
        WriteConf[Write /etc/zm/zm.conf from env]
    end

    ZM -->|ZM_DB_HOST=db| DB
    ZM --> Wait
    Wait --> Count
    Count -->|table_count = 0| Bootstrap
    Count -->|table_count > 0| ConfigDB
    Bootstrap --> ConfigDB
    ConfigDB --> WriteConf
    WriteConf -->|exec "$@"| ZM_Runtime[ZoneMinder runtime]
```

## Credentials & User Separation

Two distinct database identities are used:

| Role | Username | Password Source | Purpose |
|------|----------|-----------------|---------|
| **Root** | `root` | `MYSQL_ROOT_PASSWORD` | One-time bootstrap: `CREATE DATABASE`, `CREATE USER`, `GRANT ALL PRIVILEGES`, `FLUSH PRIVILEGES` |
| **App** | `ZM_DB_USER` | `ZM_DB_PASS` (== `MYSQL_PASSWORD`) | Day-to-day operations: schema import, runtime queries, `UPDATE Config` |

The `docker-compose.yml` maps the same secret to both `MYSQL_PASSWORD` (for the MariaDB container's `MYSQL_USER`/`MYSQL_PASSWORD`) and `ZM_DB_PASS` (for the ZoneMinder container's app user), so the app user's password is identical in both containers.

## Bootstrap Sequence (First Run)

1. **Wait for MariaDB** – `netcat -z ${ZM_DB_HOST} 3306` loops until the DB port accepts connections.
2. **Table-count check** –  
   ```sql
   SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = '$ZM_DB_NAME';
   ```
   - If **> 0 tables**: assume schema already exists; skip bootstrap.
   - If **0 tables**: proceed to bootstrap.
3. **Root-privileged provisioning** (executed as MySQL `root`):
   ```sql
   CREATE DATABASE IF NOT EXISTS ${ZM_DB_NAME};
   CREATE USER IF NOT EXISTS '${ZM_DB_USER}'@'%' IDENTIFIED BY '${ZM_DB_PASS}';
   GRANT ALL PRIVILEGES ON ${ZM_DB_NAME}.* TO '${ZM_DB_USER}'@'%';
   FLUSH PRIVILEGES;
   ```
4. **Schema import** – As the app user:
   ```bash
   mysql -u ${ZM_DB_USER} -p${ZM_DB_PASS} -h ${ZM_DB_HOST} ${ZM_DB_NAME} < /usr/share/zoneminder/db/zm_create.sql
   ```
   The `zm_create.sql` file is installed by the `zoneminder` Debian package into `/usr/share/zoneminder/db/`.
5. **Enable Event Notification** – Always run (even on existing schemas):
   ```sql
   UPDATE Config SET Value = '1' WHERE Name = 'ZM_OPT_USE_EVENTNOTIFICATION';
   ```
   This toggle activates the `zmeventnotification` pathway used by the ML/AI hook pipeline.
6. **Write runtime config** – `sed` replaces placeholders in `/etc/zm/zm.conf` with the actual `ZM_DB_HOST`, `ZM_DB_USER`, `ZM_DB_PASS`, `ZM_DB_NAME` values.

## Environment Variables

| Variable | Source | Consumed By | Notes |
|----------|--------|-------------|-------|
| `MYSQL_ROOT_PASSWORD` | `.env` / shell | `db` service, `entrypoint.sh` (bootstrap) | Root password for MariaDB container |
| `MYSQL_DATABASE` | `.env` | `db` service (creates DB), `entrypoint.sh` (`ZM_DB_NAME`) | Default DB name |
| `MYSQL_USER` | `.env` | `db` service (creates user), `entrypoint.sh` (`ZM_DB_USER`) | App username |
| `MYSQL_PASSWORD` | `.env` | `db` service (sets user password), `entrypoint.sh` (`ZM_DB_PASS`) | App password |
| `ZM_DB_HOST` | `docker-compose.yml` (hard-coded `db`) | `entrypoint.sh`, `zm.conf` | Service name of MariaDB container |
| `ZM_DB_NAME` | `docker-compose.yml` (`${MYSQL_DATABASE}`) | `entrypoint.sh`, `zm.conf` | |
| `ZM_DB_USER` | `docker-compose.yml` (`${MYSQL_USER}`) | `entrypoint.sh`, `zm.conf` | |
| `ZM_DB_PASS` | `docker-compose.yml` (`${MYSQL_PASSWORD}`) | `entrypoint.sh`, `zm.conf` | |

## Configuration Toggle: `ZM_OPT_USE_EVENTNOTIFICATION`

The `Config` table row `ZM_OPT_USE_EVENTNOTIFICATION` is forced to `'1'` on every container start (bootstrap or not). This enables the **Event Notification Server** (`zmeventnotification.pl`) which:

- Receives alarm/event hooks from ZoneMinder
- Publishes to MQTT (Mosquitto) for external consumers
- Invokes the ML API (`mlapi.py`) for object/face recognition

If you disable this flag manually in the DB, the hook pipeline will not fire.

## Failure Modes & Invariants

| Scenario | Behavior |
|----------|----------|
| MariaDB not yet listening | `entrypoint.sh` blocks in `until netcat …` loop (1 s intervals) |
| `zm_create.sql` missing | `mysql … < …` fails → container exits (no fallback) |
| `ZM_OPT_USE_EVENTNOTIFICATION` update fails | Silent failure (no `|| exit` guard); hook pipeline may be disabled |
| Schema already exists but corrupted | Table-count > 0 → bootstrap skipped → runtime errors likely |
| Root password mismatch | `CREATE DATABASE/USER/GRANT` fails → bootstrap aborts |

## Operational Notes

- **Idempotency**: The `CREATE DATABASE IF NOT EXISTS` / `CREATE USER IF NOT EXISTS` / `GRANT` statements are safe to re-run, but the table-count guard prevents re-importing `zm_create.sql`.
- **Secrets rotation**: Changing `MYSQL_PASSWORD`/`MYSQL_ROOT_PASSWORD` in `.env` requires recreating the `db` volume or manually rotating passwords inside MariaDB; the entrypoint does not handle credential rotation.
- **Healthcheck**: The container's `HEALTHCHECK` (in `Dockerfile`) probes `http://localhost/zm/`; it does **not** verify DB connectivity directly.
- **Timezone**: `TZ` is propagated to PHP via `php.ini` edits in `entrypoint.sh` so timestamps in the DB match the host.

## Related Pages

- [System Overview](../architecture/system-overview.md) – Container topology and data flows
- [Entrypoint Flow](../operations/entrypoint-flow.md) – Full startup sequence including MQTT/ML wiring
- [Troubleshooting](../operations/troubleshooting.md) – Common DB connection and schema issues
