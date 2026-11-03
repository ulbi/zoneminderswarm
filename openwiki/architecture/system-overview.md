---
type: architecture
title: System Overview
description: High-level architecture of the three-service stack (MariaDB, ZoneMinder, Mosquitto) and their network/volume topology.
tags: [architecture, docker-compose, networking, volumes, zoneminder, mariadb, mosquitto]
verified:
  - by: openwiki/0.7.3
    at: 2026-11-03T01:11:51.876Z
sources:
  - id: openwiki-source-7b43f8d2fe7b509c09f79842
    resource: repo://docker-compose.override.yml
  - id: openwiki-source-b79fbbd921df689b4bbdc82f
    resource: repo://docker-compose.yml
  - id: openwiki-source-5d695310956ecb9efe1c98b1
    resource: repo://Dockerfile.mosquitto
  - id: openwiki-source-c2b3664f893d9b2ac46e6e62
    resource: repo://entrypoint_mosquitto.sh
  - id: openwiki-source-e9906b078522ed0a08c64ff1
    resource: repo://entrypoint.sh
generated: { by: "openwiki/0.7.3", at: "2026-11-03T01:11:51.876Z" }
---

# System Overview

This document describes the high-level architecture of the containerized ZoneMinder deployment consisting of three services orchestrated via Docker Compose: **MariaDB** (database), **ZoneMinder** (video surveillance application), and **Eclipse Mosquitto** (MQTT broker for event notifications).

The stack is defined across two Compose files:
- `docker-compose.yml` — base service definitions, environment, volumes, and the shared overlay network
- `docker-compose.override.yml` — build configuration and host port mappings for the ZoneMinder and Mosquitto services

---

## Service Topology

<!-- openwiki: mermaid parse failed and this diagram was converted to a text fence so it does not break rendering. Fix the diagram source and restore the mermaid fence. Parser error: Heuristic: an unescaped angle bracket inside a label breaks rendering; rephrase the label. -->
```text
flowchart LR
    subgraph "Host Network"
        H1["Port 7080<br/>(HTTP → ZoneMinder:80)"]
        H2["Port 7000<br/>(WebSocket → ZoneMinder:9000)"]
        H3["Port 1883<br/>(MQTT → Mosquitto:1883)"]
        H4["Port 9001<br/>(WS → Mosquitto:9001)"]
    end

    subgraph "zoneminder_network (overlay, attachable)"
        direction TB
        DB[("db<br/>MariaDB 10.9<br/>3306")]
        ZM["zoneminder<br/>ZoneMinder 1.36<br/>80, 9000"]
        MQ["eclipse-mosquitto<br/>Mosquitto 2.x<br/>1883, 9001"]
    end

    H1 -.->|HTTP| ZM
    H2 -.->|WebSocket| ZM
    H3 -.->|MQTT| MQ
    H4 -.->|WebSocket| MQ

    ZM -->|DB queries| DB
    ZM -->|Event publish| MQ
    MQ -.->|Event consume| ZM
```

**Caption:** Service topology showing host port mappings, the shared overlay network, and inter-service communication paths.

---

## Services

| Service | Image / Build | Internal Ports | Host Ports | Purpose |
|---------|---------------|----------------|------------|---------|
| `db` | `mariadb:10.9` | 3306 | — | Persistent relational database for ZoneMinder configuration, events, and metadata |
| `zoneminder` | `build: Dockerfile` (multi-stage) | 80 (HTTP), 9000 (WebSocket/API) | 7080 → 80, 7000 → 9000 | Video surveillance frontend, API, event processing, ML inference |
| `eclipse-mosquitto` | `build: Dockerfile.mosquitto` | 1883 (MQTT), 9001 (WebSocket) | 1883 → 1883, 9001 → 9001 | MQTT broker for real-time event notifications between ZoneMinder and external consumers |

### MariaDB (`db`)

- **Role**: Authoritative data store for ZoneMinder.
- **Configuration**: Database name, user, and passwords supplied via environment variables from `.env` (`MYSQL_DATABASE`, `MYSQL_USER`, `MYSQL_PASSWORD`, `MYSQL_ROOT_PASSWORD`).
- **Persistence**: Volume `db_data` mounted at `/var/lib/mysql`.
- **Network**: Attached to `zoneminder_network`; reachable at hostname `db` on port 3306.
- **Initialization**: The ZoneMinder entrypoint (`entrypoint.sh`) waits for MariaDB to accept connections, creates the schema via `zm_create.sql` on first run, and enables the `ZM_OPT_USE_EVENTNOTIFICATION` option.

### ZoneMinder (`zoneminder`)

- **Role**: Core surveillance application — camera management, recording, motion detection, event review, and ML-based object detection.
- **Build**: Multi-stage `Dockerfile` compiling OpenCV 4.6.0, installing the ZoneMinder ML API (`mlapi`), ZoneMinder 1.36 from the `iconnor` PPA, and `zmeventnotification` (Perl event server + hook scripts).
- **Configuration**: Entirely via environment variables mapped into `/etc/zm/zm.conf`, `/etc/zm/secrets.ini`, and `/etc/zm/zmeventnotification.ini` by the entrypoint script at container start.
- **Shared Memory**: `tmpfs` mount at `/dev/shm` (400 MB) for high-performance frame passing between capture, analysis, and streaming components.
- **Persistence**: Named volumes for config (`zm_config`), cache (`zm_cache`), and face recognition datasets (`known_faces`, `unknown_faces`).
- **Network**: Attached to `zoneminder_network`; hostname `zoneminder`.
- **Dependencies**: Requires `db` (MariaDB) and `eclipse-mosquitto` (MQTT) to be healthy before full operation.

### Eclipse Mosquitto (`eclipse-mosquitto`)

- **Role**: Lightweight MQTT broker for the ZoneMinder event notification pipeline.
- **Build**: Thin wrapper (`Dockerfile.mosquitto`) around `eclipse-mosquitto:latest` that injects a custom entrypoint (`entrypoint_mosquitto.sh`).
- **Configuration**: Entrypoint generates `/mosquitto/config/mosquitto.conf` with password authentication (`MQTT_USER`, `MQTT_PASSWORD` from `.env`), persistence enabled, and debug logging to stdout.
- **Persistence**: Volume `mosquitto_data` mounted at `/mosquitto/data` for message durability across restarts.
- **Network**: Attached to `zoneminder_network`; hostname `eclipse-mosquitto`.
- **Ports**: 1883 (native MQTT) and 9001 (MQTT over WebSocket) exposed to host for external clients.

---

## Network Topology

### `zoneminder_network` (Overlay, Attachable)

```yaml
networks:
  zoneminder_network:
    driver: overlay
    attachable: true
```

- **Driver**: `overlay` — enables multi-host networking if the stack is deployed to a Swarm cluster; on a single host it behaves like a bridge with encrypted control plane.
- **Attachable**: `true` — allows standalone containers (e.g., debugging tools, external MQTT clients, backup jobs) to join the network via `docker network connect zoneminder_network <container>` without being part of the Compose project.
- **Service Discovery**: Docker's embedded DNS resolves service names (`db`, `zoneminder`, `eclipse-mosquitto`) to their container IPs within the network.
- **Isolation**: No ports are published by the base Compose file; only `docker-compose.override.yml` exposes ports to the host. This keeps inter-service traffic off the host network interface.

### Communication Flows

| Direction | Protocol | Purpose |
|-----------|----------|---------|
| `zoneminder` → `db` | MySQL (3306) | Schema, config, events, user auth |
| `zoneminder` → `eclipse-mosquitto` | MQTT (1883) | Publish alarm/event notifications |
| `eclipse-mosquitto` → `zoneminder` | MQTT (1883) | Deliver messages to event server (zmeventnotification) |
| Host → `zoneminder` | HTTP (7080→80) | Web UI, REST API |
| Host → `zoneminder` | WebSocket (7000→9000) | Live view streams, API push |
| Host → `eclipse-mosquitto` | MQTT (1883) | External consumers (Home Assistant, custom apps) |
| Host → `eclipse-mosquitto` | WebSocket (9001) | Browser-based MQTT clients |

---

## Volume Topology

| Volume | Service(s) | Mount Point | Purpose |
|--------|------------|-------------|---------|
| `db_data` | `db` | `/var/lib/mysql` | MariaDB data directory (tables, indexes, logs) |
| `zm_config` | `zoneminder` | `/etc/zm` | ZoneMinder configuration files (zm.conf, secrets.ini, zmeventnotification.ini) |
| `zm_cache` | `zoneminder` | `/var/cache/zoneminder` | Cached images, thumbnails, temporary files |
| `known_faces` | `zoneminder` | `/var/lib/zmeventnotification/known_faces` | Face recognition reference images |
| `unknown_faces` | `zoneminder` | `/var/lib/zmeventnotification/unknown_faces` | Unrecognized face captures for review/training |
| `mosquitto_data` | `eclipse-mosquitto` | `/mosquitto/data` | MQTT message persistence (retained messages, subscriptions) |

All volumes are **named Docker volumes** managed by the Docker engine. They survive `docker-compose down` and are not bind-mounted to the host filesystem, ensuring portability across hosts and backup via `docker volume` tooling.

---

## Port Mapping Summary

| Host Port | Container | Container Port | Protocol | Notes |
|-----------|-----------|----------------|----------|-------|
| 7080 | `zoneminder` | 80 | HTTP | Web UI, REST API |
| 7000 | `zoneminder` | 9000 | WebSocket | Live streams, event push |
| 1883 | `eclipse-mosquitto` | 1883 | MQTT | Native MQTT for external clients |
| 9001 | `eclipse-mosquitto` | 9001 | WebSocket | MQTT over WebSocket (browser clients) |

> **Note**: MariaDB port 3306 is **not** published to the host. Database access is restricted to the overlay network.

---

## Environment Configuration

All secrets and tunables are sourced from a `.env` file at the project root (not committed). Required variables:

```dotenv
MYSQL_ROOT_PASSWORD=<root_password>
MYSQL_DATABASE=<database_name>
MYSQL_USER=<database_user>
MYSQL_PASSWORD=<database_password>
TZ=Europe/Berlin
MQTT_USER=<mqtt_user>
MQTT_PASSWORD=<mqtt_password>
ZM_USER=<zm_username>
ZM_PASSWORD=<zm_password>
```

The entrypoint scripts (`entrypoint.sh`, `entrypoint_mosquitto.sh`) interpolate these into service configuration files at startup, enabling immutable images and environment-specific deployments.

---

## Startup Order & Health

1. **MariaDB** starts first (no dependencies).
2. **Mosquitto** starts in parallel (no dependencies).
3. **ZoneMinder** entrypoint waits for `db:3306` via `netcat` before initializing schema and launching Apache + ZoneMinder services.
4. **Healthcheck**: ZoneMinder container includes a `HEALTHCHECK` hitting `http://localhost/zm/` every 60s. Mosquitto and MariaDB rely on Docker's default liveness (process presence).

---

## Related Pages

- [Container Design](container-design.md) — Multi-stage Dockerfile internals, build pipeline, and image composition
- [Event Notifications](../integrations/event-notifications.md) — MQTT event flow, zmeventnotification configuration, and hook scripts
- [Deployment](../operations/deployment.md) — Operational procedures: bring-up, backup, restore, upgrade
