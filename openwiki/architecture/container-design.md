---
type: architecture
title: Container Design
description: Multi-stage Dockerfile architecture for ZoneMinder (OpenCV builder stage, ZoneMinder 1.36 runtime, mlapi, zmeventnotification, Apache) plus the runtime-configured mosquitto MQTT broker image.
tags: [docker, container, build, orchestration, zoneminder, mosquitto]
verified:
  - by: openwiki/0.7.3
    at: 2026-11-03T05:30:36.749Z
sources:
  - id: openwiki-source-79b37831c9c81206da1d88ec
    resource: repo://.github/dependabot.yml
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
generated: { by: "openwiki/0.7.3", at: "2026-11-03T05:30:36.749Z" }
---

# Container Design

This document details the multi-stage Dockerfile architecture used to build the ZoneMinder container image. The build process creates a self-contained image with ZoneMinder, OpenCV (built from source), the ML API for object detection, and the zmeventnotification event server, all orchestrated by a single entrypoint script. A second, much smaller image wraps `eclipse-mosquitto` and generates its broker configuration at startup.

The stack is built from the repository root: `docker-compose.override.yml` provides `build` contexts and host port mappings for both custom images (`Dockerfile` for `zoneminder`, `Dockerfile.mosquitto` for `eclipse-mosquitto`), while the base `docker-compose.yml` defines environment, volumes, and the shared `zoneminder_network` overlay network. `.github/dependabot.yml` schedules weekly Docker ecosystem dependency updates for the root directory, covering the base-image pins in both Dockerfiles.

## Build Stages Overview

```mermaid
flowchart TD
    A["Stage 1: opencv_builder on ubuntu:22.04"] -->|"copies /usr/local"| B["Stage 2: final runtime image on ubuntu:22.04"]
    B --> C["Install ZM and Python base packages"]
    C --> D["Install mlapi build dependencies"]
    D --> E["Copy OpenCV from builder stage"]
    E --> F["Clone mlapi, pip install requirements, run get_models.sh"]
    F --> G["Add ZM PPA, install zoneminder, remove mysql-server"]
    G --> H["Install Perl deps, clone zmeventnotification, run install.sh"]
    H --> I["Enable Apache modules and zoneminder conf"]
    I --> J["Copy entrypoint.sh"]
    J --> K["Back up /etc/zm to /org/etc/zm"]
    K --> L["HEALTHCHECK, EXPOSE 80 9000, ENTRYPOINT"]
```

**Caption:** Multi-stage Dockerfile build pipeline from OpenCV compilation to the final ZoneMinder runtime image.

---

## Stage 1: OpenCV Builder (`opencv_builder`)

**Base:** `ubuntu:22.04` (line 2 of the `Dockerfile`)
**Purpose:** Compile OpenCV 4.6.0 with contrib modules from source.

### Key Characteristics

- Installs build toolchain: `build-essential`, `cmake`, `pkg-config`, and media codec libraries (`libjpeg-dev`, `libtiff-dev`, `libpng-dev`, `libavcodec-dev`, `libavformat-dev`, `libswscale-dev`, `libv4l-dev`, `libxvidcore-dev`, `libx264-dev`, `libgtk-3-dev`, `libatlas-base-dev`, `gfortran`), plus `python3-dev`, `wget`, `unzip`.
- Downloads OpenCV and OpenCV contrib source archives from GitHub (pinned to `OPENCV_VERSION=4.6.0` via an `ENV` variable).
- Configures CMake with:
  - `RELEASE` build type
  - Install prefix `/usr/local`
  - Extra modules path pointing to the contrib modules
  - Python 3 bindings enabled (`BUILD_opencv_python3=ON`), Python 2 disabled
  - CUDA disabled (`WITH_CUDA=OFF`) — although `ENABLE_FAST_MATH=1` and `WITH_CUBLAS=1` are also set, they have no GPU effect without CUDA
  - TBB enabled for parallelism (`WITH_TBB=ON`)
  - Docs, examples, tests, and perf tests disabled (`BUILD_DOCS=OFF`, `BUILD_EXAMPLES=OFF`, `BUILD_TESTS=OFF`, `BUILD_PERF_TESTS=OFF`)
- Runs `make -j$(nproc)` for parallel compilation.
- Installs to `/usr/local` and runs `ldconfig`.

This stage is the heaviest part of the build; caching it separately lets the final stage rebuild quickly when only runtime layers change.

### Output Artifact

The entire `/usr/local` tree (headers, libraries, Python bindings) is copied into the final stage via:

```dockerfile
COPY --from=opencv_builder /usr/local /usr/local
```

This avoids shipping the build toolchain in the final image while providing a fully-featured OpenCV installation.

---

## Stage 2: Final Runtime Image

**Base:** `ubuntu:22.04` (fresh, minimal)
**Purpose:** Assemble all runtime components on top of a clean base. The image version is controlled by the `ZONEMINDERVERSION=1.36` `ENV` variable, which also selects the PPA suffix.

### Layer Sequence

1. **Base packages & Python stack** — `software-properties-common`, `wget`, `git`, `libmysqlclient-dev`, `mysql-client`, followed by `apt-get upgrade -y`, then `python3-pip`, `python3-dev`, `python3-setuptools`, `python3-wheel`, `python3-mysql.connector`, `netcat`, `curl`.

2. **ML API build dependencies** — `gcc`, `cmake`, `libev-dev`, `libevdev2`, `build-essential`, `libopenblas-dev`, `liblapack-dev`, `libblas-dev`, `git`, `wget` (the BLAS/LAPACK/OpenBLAS libraries back NumPy/SciPy used by mlapi).

3. **OpenCV from builder** — `COPY --from=opencv_builder /usr/local /usr/local` (see above).

4. **mlapi (ZoneMinder Machine Learning API)** — `WORKDIR /usr/src/app/mlapi`, then `git clone https://github.com/ZoneMinder/mlapi.git .` (clones into the workdir), installs Python requirements via `pip3 install --no-cache-dir -r requirements.txt`. The `get_models.sh` script then downloads YOLO/object detection model weights. (A commented-out `opencv-python-headless` pip install remains for reference.)

5. **ZoneMinder installation** — Adds the `ppa:iconnor/zoneminder-1.36` PPA (via `add-apt-repository -y ppa:iconnor/zoneminder-${ZONEMINDERVERSION}`), installs the `zoneminder` package, removes `mysql-server` (an external MariaDB is used), runs `apt-get autoremove`, and installs `vim` for debugging.

6. **zmeventnotification (Event Notification Server)** — Installs Perl dependencies (`libmodule-build-perl`, `libyaml-perl`, `make`, `libprotocol-websocket-perl`, `libjson-perl`, `liblwp-protocol-https-perl`) plus CPAN modules (`Net::WebSocket::Server`, `Net::MQTT::Simple`, `Config::Inifiles`, `Config::IniFiles`, `Crypt::MySQL`, `Crypt::Eksblowfish::Bcrypt`). Clones `https://github.com/zoneminder/zmeventnotification` to `/opt/zmeventnotification` and runs `install.sh` with flags:
   - `--install-es` — Event Server
   - `--install-hook` — Event hook script
   - `--install-config` — Configuration files
   - `--no-interactive` — Unattended
   - `--hook-config-upgrade` — Upgrade hook config
   - `--no-pysudo` — No sudo for Python

   These Perl modules must be present before `install.sh` runs; they are what the event server needs for WebSocket and MQTT transport at runtime.

7. **Apache configuration** — `a2enmod cgi`, `a2enmod rewrite`, and `a2enconf zoneminder`.

8. **Entrypoint** — Copies `entrypoint.sh` to `/usr/local/bin/`, makes executable.

9. **Config backup** — Creates `/org/etc/zm` and copies `/etc/zm/*` into it (see [Config Backup Pattern](#config-backup-pattern-orgetczm)). This runs after the entrypoint is copied, so the backup captures whatever the ZoneMinder and zmeventnotification packages placed in `/etc/zm`.

10. **Healthcheck & ports** — `HEALTHCHECK` hits `http://localhost/zm/` every 60s; `EXPOSE 80 9000`.

11. **Entrypoint declaration** — `ENTRYPOINT ["entrypoint.sh"]`.

---

## Config Backup Pattern: `/org/etc/zm`

The Dockerfile creates a pristine copy of the default ZoneMinder configuration at image build time:

```dockerfile
RUN mkdir -p /org/etc/zm
RUN cp -R /etc/zm/* /org/etc/zm/
```

### Runtime Behavior (entrypoint.sh)

On container startup, the entrypoint checks whether the runtime config volume (`/etc/zm`) is empty:

```bash
if [ -z "$(ls -A /etc/zm)" ]; then
   cp -R /org/etc/zm/* /etc/zm/
fi
```

### Purpose

- **First-run initialization:** When a fresh `zm_config` volume is mounted, `/etc/zm` is empty. The entrypoint seeds it from `/org/etc/zm` so ZoneMinder starts with valid defaults.
- **Persistence:** On subsequent starts, the volume already contains customized config; the `if` guard preserves user changes.
- **Immutability of defaults:** `/org/etc/zm` remains a read-only reference; never modified at runtime.

### Files Preserved

Key configuration files in `/etc/zm` (and thus backed up to `/org/etc/zm`):
- `zm.conf` — Core ZoneMinder settings (DB credentials, paths, options)
- `zmeventnotification.ini` — Event notification server config
- `secrets.ini` — API keys, ML API secret, ZoneMinder web credentials
- Apache/SSL configs under `/etc/zm/conf.d/` (if present)

---

## Mosquitto Image (second build)

`Dockerfile.mosquitto` is a thin wrapper around the official broker image:

```dockerfile
FROM eclipse-mosquitto:latest
COPY entrypoint_mosquitto.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT [ "/entrypoint.sh" ]
```

Unlike the ZoneMinder image, no broker configuration is baked in. `entrypoint_mosquitto.sh` generates it at every container start:

1. Ensures `/mosquitto/config` exists.
2. Writes `/mosquitto/config/mosquitto.conf` via a heredoc with:
   - `listener 1883`
   - `password_file /mosquitto/config/password_file`
   - `persistence true`, `persistence_location /mosquitto/data/`
   - `log_type all` / `log_type debug` and `log_dest stdout`
3. Touches the `password_file`, then populates it with `mosquitto_passwd -b` using the `$MQTT_USER` / `$MQTT_PASSWORD` environment variables (provided by `docker-compose.yml`).
4. Starts the broker in the foreground: `/usr/sbin/mosquitto -c /mosquitto/config/mosquitto.conf`.

The `mosquitto_data` named volume mounted at `/mosquitto/data` makes the broker's persistence directory survive restarts; the generated `mosquitto.conf` and `password_file` are recreated each start from the current environment variables.

**Note:** the generated configuration defines only the `listener 1883` TCP listener — it does not enable a WebSocket listener. The `9001:9001` mapping in `docker-compose.override.yml` is therefore not served by this image unless you add a `listener 9001` / `protocol websockets` block to the heredoc in `entrypoint_mosquitto.sh`.

---

## tmpfs Shared Memory for ZoneMinder

ZoneMinder uses `/dev/shm` for shared memory buffers between capture, analysis, and streaming processes. The docker-compose.yml mounts a `tmpfs` volume sized at ~400 MB:

```yaml
volumes:
  - type: tmpfs
    target: /dev/shm
    tmpfs:
      size: 400000000  # ~400 MB
```

### Sizing Considerations

- **Formula:** `num_cameras × resolution × color_depth × buffer_count`
- **Default 400 MB** suits ~4–6 1080p cameras with modest buffer counts.
- **Increase** if you see `shmget` failures or "No space left on device" in ZM logs.
- **Decrease** for memory-constrained hosts (minimum ~64 MB for a single low-res camera).

The `tmpfs` mount is backed by host RAM (not disk), so size directly consumes container memory limit. Ensure the container's memory limit (if set) exceeds this value.

---

## Entrypoint Orchestration

`entrypoint.sh` is the single PID 1 process that initializes the environment and launches all services.

### Execution Flow

```mermaid
sequenceDiagram
    participant E as entrypoint.sh
    participant FS as Filesystem (/etc/zm)
    participant DB as MariaDB (db:3306)
    participant ZM as ZoneMinder Services
    participant MQTT as MQTT Broker

    E->>FS: Seed config from /org/etc/zm if empty
    E->>E: Set timezone (TZ env) in /etc/timezone & php.ini
    E->>DB: Wait for TCP port 3306 (netcat loop)
    E->>DB: Check table count in ZM_DB_NAME
    alt Tables exist
        E->>DB: Skip schema init
    else Empty DB
        E->>DB: CREATE DATABASE, USER, GRANT
        E->>DB: Import /usr/share/zoneminder/db/zm_create.sql
    end
    E->>DB: Enable ZM_OPT_USE_EVENTNOTIFICATION = 1
    E->>FS: Rewrite zm.conf with runtime DB credentials
    E->>FS: Configure zmeventnotification.ini (MQTT section)
    E->>FS: Rewrite secrets.ini (ZM_USER, ZM_PASSWORD, MLAPI_SECRET_KEY)
    E->>ZM: service apache2 start
    E->>ZM: service zoneminder start
    E->>E: tail -f /dev/null (keep PID 1 alive)
```

**Caption:** Entrypoint initialization sequence from config seeding to service startup.

### Detailed Steps

| Phase | Action | Details |
|-------|--------|---------|
| **Config seeding** | `cp -R /org/etc/zm/* /etc/zm/` | Only if `/etc/zm` empty (first run on volume). |
| **Timezone** | `TZ` → `/etc/timezone`, `/etc/localtime`, all `php.ini` `date.timezone` | Uses `dpkg-reconfigure tzdata`; appends `date.timezone` to php.ini files where missing. |
| **DB wait** | `netcat -z ${ZM_DB_HOST} 3306` loop | Blocks until MariaDB accepts connections. |
| **DB init** | `mysql` table count check | Creates schema + user + imports `zm_create.sql` if empty. |
| **Feature flag** | `UPDATE Config SET Value='1' WHERE Name='ZM_OPT_USE_EVENTNOTIFICATION'` | Enables event notification integration. |
| **Command handoff** | `exec "$@"` | See caveat below. |
| **zm.conf rewrite** | `sed` replacements for `ZM_DB_HOST`, `ZM_DB_USER`, `ZM_DB_PASS`, `ZM_DB_NAME` | Runtime values override baked-in defaults. |
| **zmeventnotification.ini** | If `MQTT_HOST` set: enable MQTT section, set server/user/password/retain, disable SSL | Dynamic config for event server. |
| **secrets.ini** | Replace portal URL, `ZM_USER`, `ZM_PASSWORD`, generate `MLAPI_SECRET_KEY` | `openssl rand -base64 32` for ML API auth. |
| **Service start** | `service apache2 start` → `service zoneminder start` | Apache serves ZM web UI; ZM daemons start capture/analysis. |
| **Keep alive** | `tail -f /dev/null` | Prevents container exit; PID 1 stays alive. |

### The `exec "$@"` Handoff

Midway through the script, right after the event-notification feature flag, the entrypoint runs `exec "$@"`. Because the image declares `ENTRYPOINT ["entrypoint.sh"]` with no `CMD`, `$@` is empty, and `exec` with no command in bash is a no-op — the script simply continues with the config rewrites and service startup. However, if you launch the image with a command override (`docker run ... <image> <command>`), `exec` replaces the shell with that command and **skips everything after it**: the `zm.conf`/`secrets.ini` rewrites, the MQTT configuration, and the `service apache2`/`service zoneminder` startup. Keep this in mind when overriding the command; the entrypoint's final `tail -f /dev/null` is what actually keeps PID 1 alive in the normal path.

### Environment Variables Consumed

| Variable | Used By | Required |
|----------|---------|----------|
| `TZ` | Timezone setup | No (defaults to UTC) |
| `ZM_DB_HOST` | DB wait, zm.conf, schema init | Yes |
| `ZM_DB_NAME` | DB init, zm.conf | Yes |
| `ZM_DB_USER` | DB init, zm.conf | Yes |
| `ZM_DB_PASS` | DB init, zm.conf | Yes |
| `MYSQL_ROOT_PASSWORD` | DB creation (root login) | Yes |
| `ZM_USER` | secrets.ini, ZM auth | Yes |
| `ZM_PASSWORD` | secrets.ini, ZM auth | Yes |
| `MQTT_HOST` | zmeventnotification.ini MQTT enable | No |
| `MQTT_USER` | zmeventnotification.ini; also mosquitto password file | If MQTT_HOST set |
| `MQTT_PASSWORD` | zmeventnotification.ini; also mosquitto password file | If MQTT_HOST set |

### Services NOT Started by Entrypoint

- **ML API (`mlapi.py`)** — Commented out in entrypoint (`#python3 /usr/src/app/mlapi/mlapi.py -c mlapiconfig.ini`). Typically run as a separate container or process.
- **zmeventnotification.pl** — Commented out (`#./zmeventnotification.pl ...`). The install.sh sets up systemd-style service files; in this container it's expected to be started via ZoneMinder's `zmtrigger.pl` hook or a separate supervisor.

---

## Network Ports

| Port | Service | Notes |
|------|---------|-------|
| 80 | Apache / ZoneMinder Web UI | Exposed by `Dockerfile`; host mapping `7080:80` in override file |
| 9000 | ZoneMinder API / WebSocket | Exposed by `Dockerfile`; host mapping `7000:9000` in override file |
| 1883 | Mosquitto MQTT listener | Generated by `entrypoint_mosquitto.sh`; host mapping `1883:1883` |
| 9001 | Mosquitto WebSocket | Mapped in the override file, but the generated `mosquitto.conf` defines no WebSocket listener — mapping is inert as shipped |

The ZoneMinder container exposes 80 and 9000. The MQTT broker runs in a separate `eclipse-mosquitto` container (see `docker-compose.yml`).

---

## Volumes

| Volume | Mount Path | Purpose |
|--------|------------|---------|
| `zm_config` | `/etc/zm` | ZoneMinder config (seeded from `/org/etc/zm`) |
| `zm_cache` | `/var/cache/zoneminder` | Cached images, thumbnails, video |
| `known_faces` | `/var/lib/zmeventnotification/known_faces` | Face recognition reference images |
| `unknown_faces` | `/var/lib/zmeventnotification/unknown_faces` | Unrecognized face crops |
| `mosquitto_data` | `/mosquitto/data` | Mosquitto broker persistence (used by the generated `persistence_location`) |
| `tmpfs` | `/dev/shm` | Shared memory for ZM buffers (~400 MB) |

---

## Healthcheck

```dockerfile
HEALTHCHECK --interval=1m --timeout=10s --retries=3 \
    CMD curl -f http://localhost/zm/ || exit 1
```

- Probes the ZoneMinder web root every 60 seconds.
- 10-second timeout, 3 retries before marking unhealthy.
- Depends on Apache being up; will fail during initial DB init phase (acceptable).
- The mosquitto image defines no HEALTHCHECK; rely on the MQTT listener being reachable.

---

## Extending the Image / Changing Build Behavior

### Adding Custom OpenCV Modules

Modify the `opencv_builder` stage CMake flags (e.g., enable `WITH_CUDA=ON`, add `-D OPENCV_EXTRA_MODULES_PATH=...` for local modules).

### Pinning Versions

- `OPENCV_VERSION` arg in the builder stage (an `ENV` line, not an `ARG` — change the line to re-pin).
- `ZONEMINDERVERSION` (PPA suffix) in the final stage — controls both the PPA name and effectively the ZoneMinder 1.36 package series.
- mlapi / zmeventnotification Git refs (currently `master` via `git clone`); pin to tags for reproducibility.
- mlapi Python dependencies come from the cloned repo's `requirements.txt`; model weights are fetched by `./get_models.sh`.

### Mosquitto Configuration Changes

Edit the heredoc inside `entrypoint_mosquitto.sh` to add listeners (e.g., a WebSocket listener on 9001), TLS, or ACLs — there is no baked-in config to modify.

### Dependency Automation

`.github/dependabot.yml` schedules weekly `docker`-ecosystem updates for the repository root, so the `FROM` base-image pins in both Dockerfiles (and `eclipse-mosquitto:latest`) are monitored for updates. Git clones (`mlapi`, `zmeventnotification`) are unpinned and not covered by Dependabot.

### Multi-Arch Builds

Use `docker buildx` with `--platform linux/amd64,linux/arm64`. The OpenCV build stage is the heaviest; consider pre-built OpenCV base images for ARM to reduce build time.

---

## Related Pages

- [ML Pipeline](ml-pipeline.md) — ML API model loading and inference flow.
- [System Overview](system-overview.md) — Full architecture diagram and service relationships.
- [Entrypoint Flow](../operations/entrypoint-flow.md) — Detailed entrypoint.sh execution trace and troubleshooting.
- [Deployment Guide](../operations/deployment.md) — Compose commands, environment variables, and port mappings.
