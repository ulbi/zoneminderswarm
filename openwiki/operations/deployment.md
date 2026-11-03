---
type: operations-guide
title: Deployment Guide
description: Environment variables, .env file schema, docker-compose commands, and healthcheck behavior for production deployment of the containerized ZoneMinder stack.
tags: [deployment, docker, environment-variables, healthcheck, operations]
verified:
  - by: openwiki/0.7.3
    at: 2026-11-03T01:11:51.876Z
sources:
  - id: openwiki-source-7b43f8d2fe7b509c09f79842
    resource: repo://docker-compose.override.yml
  - id: openwiki-source-b79fbbd921df689b4bbdc82f
    resource: repo://docker-compose.yml
  - id: openwiki-source-bb1ebe868e35e9e500714501
    resource: repo://Dockerfile
  - id: openwiki-source-5d695310956ecb9efe1c98b1
    resource: repo://Dockerfile.mosquitto
  - id: openwiki-source-c2b3664f893d9b2ac46e6e62
    resource: repo://entrypoint_mosquitto.sh
  - id: openwiki-source-e9906b078522ed0a08c64ff1
    resource: repo://entrypoint.sh
  - id: openwiki-source-23775c3de52f3ab95a13cb8b
    resource: repo://README.md
generated: { by: "openwiki/0.7.3", at: "2026-11-03T01:11:51.876Z" }
---

# Deployment Guide

This document covers the production deployment of the containerized ZoneMinder stack, including required environment variables, `.env` file schema, Docker Compose commands, port mappings, and healthcheck behavior.

## Architecture Overview

The stack consists of three services orchestrated via Docker Compose:

| Service | Image | Purpose |
|---------|-------|---------|
| `db` | `mariadb:10.9` | MariaDB database for ZoneMinder metadata and events |
| `zoneminder` | Built from `Dockerfile` | ZoneMinder web UI, API, and event processing |
| `eclipse-mosquitto` | Built from `Dockerfile.mosquitto` | MQTT broker for event notification |

All services share the `zoneminder_network` (overlay, attachable) and persist data via named volumes.

## Port Mappings

The `docker-compose.override.yml` exposes the following host ports:

| Host Port | Container Port | Service | Protocol | Description |
|-----------|----------------|---------|----------|-------------|
| 7080 | 80 | zoneminder | HTTP | ZoneMinder web UI and REST API |
| 7000 | 9000 | zoneminder | HTTP | ZoneMinder live stream / WebSocket port |
| 1883 | 1883 | eclipse-mosquitto | MQTT | Standard MQTT listener for event clients |
| 9001 | 9001 | eclipse-mosquitto | WebSocket | MQTT over WebSocket (if enabled in mosquitto.conf) |

> **Note**: The base `docker-compose.yml` does not declare `ports`; they are added exclusively by the override file. This allows the same base compose file to be used in swarm mode (where ports are managed differently) while the override provides host-port bindings for standalone development or single-host production.

## Required Environment Variables (`.env` Schema)

Create a `.env` file in the project root (alongside `docker-compose.yml`) with the following variables. All are required unless marked optional.

| Variable | Description | Example |
|----------|-------------|---------|
| `MYSQL_ROOT_PASSWORD` | Root password for MariaDB. Used by the entrypoint to create the ZoneMinder database and user. | `strong_root_pw` |
| `MYSQL_DATABASE` | Name of the ZoneMinder database to create. | `zm` |
| `MYSQL_USER` | Database user for ZoneMinder to connect as. | `zmuser` |
| `MYSQL_PASSWORD` | Password for `MYSQL_USER`. | `zmuser_pw` |
| `TZ` | Timezone for all containers (PHP, system, database). Must be a valid IANA zone. | `Europe/Berlin` |
| `MQTT_USER` | Username for MQTT authentication (used by `zmeventnotification`). | `mqtt_user` |
| `MQTT_PASSWORD` | Password for MQTT authentication. | `mqtt_pass` |
| `ZM_USER` | ZoneMinder web UI username (typically `admin`). Used by `zmeventnotification` to call the ZoneMinder API. | `admin` |
| `ZM_PASSWORD` | Password for `ZM_USER`. | `admin_pw` |

### Variable Propagation

- `db` service receives: `MYSQL_ROOT_PASSWORD`, `MYSQL_DATABASE`, `MYSQL_USER`, `MYSQL_PASSWORD`, `TZ`
- `zoneminder` service receives: all of the above plus `ZM_DB_HOST=db`, `ZM_SERVER_HOST=zoneminder`, `MQTT_HOST=eclipse-mosquitto`
- `eclipse-mosquitto` service receives: `MQTT_USER`, `MQTT_PASSWORD`

The `zoneminder` entrypoint script (`entrypoint.sh`) consumes these variables to:
1. Set system and PHP timezone
2. Wait for MariaDB to become reachable
3. Initialize the ZoneMinder database schema if empty
4. Enable `ZM_OPT_USE_EVENTNOTIFICATION` in the DB
5. Write DB credentials into `/etc/zm/zm.conf`
6. Configure `/etc/zm/zmeventnotification.ini` for MQTT (server, username, password, retain)
7. Update `/etc/zm/secrets.ini` with `ZM_USER`, `ZM_PASSWORD`, and a generated `MLAPI_SECRET_KEY`

## Docker Compose Commands

### Start the Stack (Detached)

```bash
docker-compose up -d
```

This builds the `zoneminder` and `eclipse-mosquitto` images (first run only), creates volumes and networks, and starts all three containers.

### Stop and Remove Containers (Keep Volumes)

```bash
docker-compose down
```

Stops and removes containers but preserves named volumes (`db_data`, `zm_config`, `zm_cache`, `known_faces`, `unknown_faces`, `mosquitto_data`).

### Stop and Remove Everything Including Volumes

```bash
docker-compose down -v
```

⚠️ **Destructive**: Deletes all persisted data (database, ZoneMinder config, face recognition data, Mosquitto data).

### View Logs

```bash
# All services
docker-compose logs -f

# Single service
docker-compose logs -f zoneminder
```

### Rebuild After Dockerfile Changes

```bash
docker-compose build --no-cache zoneminder
docker-compose up -d
```

### Execute Commands in Running Container

```bash
# ZoneMinder shell
docker-compose exec zoneminder bash

# MariaDB shell
docker-compose exec db mysql -u root -p
```

## Healthcheck Behavior

The `zoneminder` service defines a `HEALTHCHECK` in its `Dockerfile`:

```dockerfile
HEALTHCHECK --interval=1m --timeout=10s --retries=3 \
    CMD curl -f http://localhost/zm/ || exit 1
```

### Parameters

| Parameter | Value | Meaning |
|-----------|-------|---------|
| `--interval` | `1m` | Run the check every 60 seconds |
| `--timeout` | `10s` | Fail the check if `curl` takes longer than 10 seconds |
| `--retries` | `3` | Mark container unhealthy after 3 consecutive failures |

### Endpoint

The check hits `http://localhost/zm/` inside the container (port 80). This is the ZoneMinder web root served by Apache. A successful HTTP 2xx response indicates:

- Apache is running
- ZoneMinder PHP application bootstraps without fatal errors
- Database connectivity is functional (ZoneMinder refuses to start without DB)

### Observing Health Status

```bash
# Check health status of all containers
docker-compose ps

# Inspect detailed health history
docker inspect --format='{{json .State.Health}}' $(docker-compose ps -q zoneminder) | jq
```

### Healthcheck Failure Modes

| Symptom | Likely Cause |
|---------|--------------|
| `curl: (7) Failed to connect to localhost port 80` | Apache not started or crashed |
| `curl: (22) The requested URL returned error: 500` | PHP fatal error, missing DB, or ZoneMinder misconfiguration |
| Timeout after 10s | Apache hung, high load, or deadlock |

The entrypoint script starts Apache via `service apache2 start` and ZoneMinder via `service zoneminder start` before entering `tail -f /dev/null`. If either service fails to start, the healthcheck will catch it within the first interval.

## Volumes and Data Persistence

| Volume | Mount Point (Container) | Content |
|--------|-------------------------|---------|
| `db_data` | `/var/lib/mysql` (db) | MariaDB data files |
| `zm_config` | `/etc/zm` (zoneminder) | ZoneMinder configuration (`zm.conf`, `zmeventnotification.ini`, `secrets.ini`) |
| `zm_cache` | `/var/cache/zoneminder` (zoneminder) | Cached images, thumbnails, analysis data |
| `known_faces` | `/var/lib/zmeventnotification/known_faces` (zoneminder) | Face recognition reference images |
| `unknown_faces` | `/var/lib/zmeventnotification/unknown_faces` (zoneminder) | Unrecognized face captures |
| `mosquitto_data` | `/mosquitto/data` (eclipse-mosquitto) | MQTT persistence (messages, subscriptions) |

The `zoneminder` service also mounts a `tmpfs` at `/dev/shm` (size ~400 MB) for shared memory used by ZoneMinder's `zmc` and `zma` processes.

## First-Time Initialization Flow

On first startup (when `/etc/zm` is empty), the `zoneminder` entrypoint performs:

1. **Config seeding**: Copies `/org/etc/zm/*` → `/etc/zm/`
2. **Timezone setup**: Writes `TZ` to `/etc/timezone`, updates all `php.ini` files
3. **Database wait**: Blocks until `netcat -z db 3306` succeeds
4. **Schema initialization**: If `zm` database has zero tables, runs:
   ```sql
   CREATE DATABASE IF NOT EXISTS zm;
   CREATE USER IF NOT EXISTS 'zmuser'@'%' IDENTIFIED BY '...';
   GRANT ALL PRIVILEGES ON zm.* TO 'zmuser'@'%';
   FLUSH PRIVILEGES;
   ```
   Then imports `/usr/share/zoneminder/db/zm_create.sql`
5. **Feature enable**: Sets `ZM_OPT_USE_EVENTNOTIFICATION = 1` in DB
6. **Config rewrite**: Updates `/etc/zm/zm.conf` with DB credentials from env
7. **MQTT config**: Enables and configures `[mqtt]` section in `zmeventnotification.ini`
8. **Secrets update**: Sets `ZM_USER`, `ZM_PASSWORD`, generates `MLAPI_SECRET_KEY` in `secrets.ini`
9. **Service start**: Starts `apache2` and `zoneminder` system services

Subsequent restarts skip the database initialization (tables already exist) but re-apply config rewrites in case environment variables changed.

## Production Checklist

- [ ] Use strong, unique passwords for all `*_PASSWORD` variables
- [ ] Set `TZ` to your local timezone for correct event timestamps
- [ ] Provision persistent storage for named volumes (bind mounts or external volume drivers)
- [ ] Configure reverse proxy (Traefik, Nginx) in front of port 7080 with TLS termination
- [ ] Restrict MQTT ports (1883, 9001) to trusted networks only
- [ ] Monitor `docker-compose ps` health status; alert on `unhealthy` state
- [ ] Schedule regular backups of `db_data` and `zm_config` volumes
- [ ] Consider enabling MQTT TLS in `mosquitto.conf` for production (requires custom config mount)

## Related Pages

- [System Overview](../architecture/system-overview.md) — High-level architecture and service interactions
- [Entrypoint Flow](../operations/entrypoint-flow.md) — Detailed entrypoint script walkthrough
- [Troubleshooting](../operations/troubleshooting.md) — Common deployment issues and resolutions
