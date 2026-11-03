---
type: quickstart
title: Quickstart
description: Entry point for coding agents. Maps common tasks (deploy, debug, extend ML, configure events) to the relevant wiki pages.
tags: [quickstart, task-router, onboarding, deployment, debugging, ml, events]
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
generated: { by: "openwiki/0.7.3", at: "2026-11-03T01:11:51.876Z" }
---

# Quickstart

This page is a **task router** for coding agents working on the containerized ZoneMinder stack. It maps common workflows to the detailed wiki pages that explain the mechanisms, configuration, and extension points.

The stack consists of three services on a shared overlay network:
- **MariaDB** (`db`) — persistent database
- **ZoneMinder** (`zoneminder`) — surveillance application, ML API, event hooks
- **Eclipse Mosquitto** (`eclipse-mosquitto`) — MQTT broker for event notifications

Two Compose files define the stack:
- `docker-compose.yml` — base service definitions, volumes, network
- `docker-compose.override.yml` — build config and host port mappings (7080→80, 7000→9000, 1883→1883, 9001→9001)

---

## Task → Wiki Page Map

| Task | Start Here | Key Details |
|------|------------|-------------|
<!-- openwiki: broken internal link [../operations/deployment.md] file "../operations/deployment.md" does not exist. Fix the href or restore the target, then delete this comment. -->
| **Deploy / bring up the stack** | [Deployment Guide](../operations/deployment.md) | `.env` schema, `docker-compose up -d`, port mappings, healthcheck |
<!-- openwiki: broken internal link [../architecture/system-overview.md] file "../architecture/system-overview.md" does not exist. Fix the href or restore the target, then delete this comment. -->
| **Understand the service topology** | [System Overview](../architecture/system-overview.md) | Three-service architecture, network/volume layout, inter-service communication |
<!-- openwiki: broken internal link [../operations/entrypoint-flow.md] file "../operations/entrypoint-flow.md" does not exist. Fix the href or restore the target, then delete this comment. -->
| **Trace container startup (PID 1)** | [Entrypoint Flow](../operations/entrypoint-flow.md) | `entrypoint.sh` phases: config seeding, timezone, DB bootstrap, MQTT config, service launch |
<!-- openwiki: broken internal link [../operations/troubleshooting.md#1-database-connection-failures] file "../operations/troubleshooting.md" does not exist. Fix the href or restore the target, then delete this comment. -->
| **Debug database issues** | [Troubleshooting → DB](../operations/troubleshooting.md#1-database-connection-failures) | `netcat` wait loop, `zm_create.sql` import, credential mapping, volume persistence |
<!-- openwiki: broken internal link [../operations/troubleshooting.md#2-configuration-not-persisting] file "../operations/troubleshooting.md" does not exist. Fix the href or restore the target, then delete this comment. -->
| **Debug config persistence** | [Troubleshooting → Config](../operations/troubleshooting.md#2-configuration-not-persisting) | Named volumes vs bind mounts, first-run seeding guard, permission expectations |
<!-- openwiki: broken internal link [../operations/ml-model-management.md] file "../operations/ml-model-management.md" does not exist. Fix the href or restore the target, then delete this comment. -->
| **Extend / swap ML models** | [ML Model Management](../operations/ml-model-management.md) | Build-time `get_models.sh`, immutable model weights in image, face volumes for runtime data |
<!-- openwiki: broken internal link [../architecture/ml-pipeline.md] file "../architecture/ml-pipeline.md" does not exist. Fix the href or restore the target, then delete this comment. -->
| **Understand the ML inference pipeline** | [ML/AI Pipeline](../architecture/ml-pipeline.md) | `mlapi` Flask + OpenCV DNN, YOLO object detection, face embeddings, hook → MQTT flow |
<!-- openwiki: broken internal link [../integrations/event-notifications.md] file "../integrations/event-notifications.md" does not exist. Fix the href or restore the target, then delete this comment. -->
| **Configure event notifications / MQTT** | [Event Notifications & MQTT](../integrations/event-notifications.md) | `zmeventnotification` server + hook, `secrets.ini` rewrite, Mosquitto password auth, topic flow |
<!-- openwiki: broken internal link [../operations/troubleshooting.md] file "../operations/troubleshooting.md" does not exist. Fix the href or restore the target, then delete this comment. -->
| **Debug ML API / event hook failures** | [Troubleshooting → ML/Events](../operations/troubleshooting.md) | `mlapi` health, hook script execution, MQTT publish/subscribe, `MLAPI_SECRET_KEY` rotation |
<!-- openwiki: broken internal link [../architecture/container-design.md] file "../architecture/container-design.md" does not exist. Fix the href or restore the target, then delete this comment. -->
| **Modify container build (OpenCV, ZM version, Perl deps)** | [Container Design](../architecture/container-design.md) | Multi-stage Dockerfile: OpenCV builder → ZM base → mlapi → zmeventnotification → entrypoint |
<!-- openwiki: broken internal link [../integrations/database.md] file "../integrations/database.md" does not exist. Fix the href or restore the target, then delete this comment. -->
| **Manage database schema / credentials** | [Database Integration](../integrations/database.md) | `zm_create.sql` bootstrap, connection config, table-count initialization check |

---

## Common Commands

```bash
# Start the stack (builds images on first run)
docker-compose up -d

# View logs for a specific service
docker-compose logs -f zoneminder
docker-compose logs -f db
docker-compose logs -f eclipse-mosquitto

# Stop and remove containers (keeps volumes)
docker-compose down

# Stop and remove everything including volumes (destructive)
docker-compose down -v

# Rebuild ZoneMinder image after Dockerfile changes
docker-compose build --no-cache zoneminder

# Execute commands inside the zoneminder container
docker-compose exec zoneminder bash

# Test MariaDB connectivity from zoneminder container
docker-compose exec zoneminder mysql -h db -u "$ZM_DB_USER" -p"$ZM_DB_PASS" "$ZM_DB_NAME" -e "SELECT 1;"

# Inspect volume contents
docker run --rm -v zm_config:/data alpine ls -la /data
docker run --rm -v known_faces:/data alpine ls -la /data
```

---

## Required `.env` File

Create `.env` in the project root (alongside `docker-compose.yml`) with:

```bash
MYSQL_ROOT_PASSWORD=<strong_root_pw>
MYSQL_DATABASE=zm
MYSQL_USER=zmuser
MYSQL_PASSWORD=<zmuser_pw>
TZ=Europe/Berlin
MQTT_USER=mqtt_user
MQTT_PASSWORD=<mqtt_pass>
ZM_USER=admin
ZM_PASSWORD=<admin_pw>
```

All variables are required. The `zoneminder` entrypoint consumes them to configure `/etc/zm/zm.conf`, `/etc/zm/secrets.ini`, and `/etc/zm/zmeventnotification.ini` at every startup.

---

## Access Points

| Service | URL | Notes |
|---------|-----|-------|
| ZoneMinder Web UI | http://localhost:7080/zm/ | Login with `ZM_USER` / `ZM_PASSWORD` |
| ZoneMinder API / Streams | http://localhost:7000/ | WebSocket / live stream port |
| MQTT Broker | localhost:1883 | Auth: `MQTT_USER` / `MQTT_PASSWORD` |
| MQTT over WebSocket | localhost:9001 | If enabled in mosquitto.conf |

---

## Architecture at a Glance

<!-- openwiki: mermaid parse failed and this diagram was converted to a text fence so it does not break rendering. Fix the diagram source and restore the mermaid fence. Parser error: Heuristic: an unescaped angle bracket inside a label breaks rendering; rephrase the label. -->
```text
flowchart LR
    subgraph Host["Host Ports"]
        H1["7080 → 80 (HTTP)"]
        H2["7000 → 9000 (WS)"]
        H3["1883 → 1883 (MQTT)"]
        H4["9001 → 9001 (WS)"]
    end

    subgraph Net["zoneminder_network (overlay)"]
        DB[("db<br/>MariaDB 10.9<br/>3306")]
        ZM["zoneminder<br/>ZoneMinder 1.36<br/>mlapi, hook, zmeventnotification"]
        MQ["eclipse-mosquitto<br/>MQTT Broker<br/>1883, 9001"]
    end

    H1 -.-> ZM
    H2 -.-> ZM
    H3 -.-> MQ
    H4 -.-> MQ

    ZM -->|DB| DB
    ZM -->|Events| MQ
    MQ -.->|Consume| ZM
```

---

## Next Steps

<!-- openwiki: broken internal link [../operations/deployment.md] file "../operations/deployment.md" does not exist. Fix the href or restore the target, then delete this comment. -->
1. **First deploy**: Follow [Deployment Guide](../operations/deployment.md) to create `.env` and run `docker-compose up -d`.
2. **Verify health**: Check `docker-compose ps` — all three services should be `Up`. ZoneMinder healthcheck hits `http://localhost/zm/`.
3. **Explore the UI**: Open http://localhost:7080/zm/, add a camera, trigger an event.
4. **Observe events**: Subscribe to MQTT topic `zoneminder/#` to see enriched event payloads from the hook.
<!-- openwiki: broken internal link [../operations/ml-model-management.md] file "../operations/ml-model-management.md" does not exist. Fix the href or restore the target, then delete this comment. -->
5. **Extend ML**: To update YOLO weights or face models, see [ML Model Management](../operations/ml-model-management.md) — requires image rebuild.
6. **Customize config**: ZoneMinder config lives in the `zm_config` volume. Changes via UI persist; manual edits to `/etc/zm/` inside the container also persist across restarts.

---

## Related Pages

<!-- openwiki: broken internal link [../architecture/system-overview.md] file "../architecture/system-overview.md" does not exist. Fix the href or restore the target, then delete this comment. -->
- [System Overview](../architecture/system-overview.md) — Service topology, network, volumes
<!-- openwiki: broken internal link [../architecture/container-design.md] file "../architecture/container-design.md" does not exist. Fix the href or restore the target, then delete this comment. -->
- [Container Design](../architecture/container-design.md) — Multi-stage Dockerfile breakdown
<!-- openwiki: broken internal link [../architecture/ml-pipeline.md] file "../architecture/ml-pipeline.md" does not exist. Fix the href or restore the target, then delete this comment. -->
- [ML/AI Pipeline](../architecture/ml-pipeline.md) — Inference flow, model paths, `MLAPI_SECRET_KEY`
<!-- openwiki: broken internal link [../integrations/event-notifications.md] file "../integrations/event-notifications.md" does not exist. Fix the href or restore the target, then delete this comment. -->
- [Event Notifications & MQTT](../integrations/event-notifications.md) — Hook/server, Mosquitto config, secrets.ini
<!-- openwiki: broken internal link [../integrations/database.md] file "../integrations/database.md" does not exist. Fix the href or restore the target, then delete this comment. -->
- [Database Integration](../integrations/database.md) — Schema bootstrap, credentials, initialization
<!-- openwiki: broken internal link [../operations/deployment.md] file "../operations/deployment.md" does not exist. Fix the href or restore the target, then delete this comment. -->
- [Deployment Guide](../operations/deployment.md) — `.env` schema, compose commands, healthcheck
<!-- openwiki: broken internal link [../operations/entrypoint-flow.md] file "../operations/entrypoint-flow.md" does not exist. Fix the href or restore the target, then delete this comment. -->
- [Entrypoint Flow](../operations/entrypoint-flow.md) — Phase-by-phase startup trace
<!-- openwiki: broken internal link [../operations/ml-model-management.md] file "../operations/ml-model-management.md" does not exist. Fix the href or restore the target, then delete this comment. -->
- [ML Model Management](../operations/ml-model-management.md) — Build-time models, runtime face volumes
<!-- openwiki: broken internal link [../operations/troubleshooting.md] file "../operations/troubleshooting.md" does not exist. Fix the href or restore the target, then delete this comment. -->
- [Troubleshooting](../operations/troubleshooting.md) — Symptom→cause→fix for DB, config, ML, MQTT
