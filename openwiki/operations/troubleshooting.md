---
type: "Reference"
title: "Troubleshooting"
openwiki_generated: true
verified:
  - by: openwiki/0.7.3
    at: 2026-11-03T01:11:51.876Z
sources:
  - id: openwiki-source-b79fbbd921df689b4bbdc82f
    resource: repo://docker-compose.yml
  - id: openwiki-source-bb1ebe868e35e9e500714501
    resource: repo://Dockerfile
  - id: openwiki-source-c2b3664f893d9b2ac46e6e62
    resource: repo://entrypoint_mosquitto.sh
  - id: openwiki-source-e9906b078522ed0a08c64ff1
    resource: repo://entrypoint.sh
generated: { by: "openwiki/0.7.3", at: "2026-11-03T01:11:51.876Z" }
---


# Troubleshooting

This guide maps observable symptoms to root causes in the containerized ZoneMinder stack. Each section references the relevant `entrypoint.sh` phase or Docker Compose volume definition so you can trace the failure to the exact initialization step.

## Quick Diagnostic Commands

```bash
# Check container status
docker-compose ps

# View logs for a specific service
docker-compose logs -f zoneminder
docker-compose logs -f db
docker-compose logs -f eclipse-mosquitto

# Inspect volume contents
docker run --rm -v zm_config:/data alpine ls -la /data
docker run --rm -v known_faces:/data alpine ls -la /data
docker run --rm -v unknown_faces:/data alpine ls -la /data

# Test DB connectivity from zoneminder container
docker-compose exec zoneminder mysql -h db -u "$ZM_DB_USER" -p"$ZM_DB_PASS" "$ZM_DB_NAME" -e "SELECT 1;"

# Test MQTT broker
docker-compose exec eclipse-mosquitto mosquitto_sub -u "$MQTT_USER" -P "$MQTT_PASSWORD" -t '#' -C 1 -v
```

---

## 1. Database Connection Failures

### Symptom
- `zoneminder` container logs show `Waiting for MariaDB server to start...` repeating indefinitely
- Or: `ERROR 2003 (HY000): Can't connect to MySQL server on 'db:3306'`
- ZoneMinder web UI shows "Could not connect to database"

### Root Causes & Fixes

| Cause | Evidence | Fix |
|-------|----------|-----|
| **MariaDB not healthy** | `docker-compose ps` shows `db` service `Exit 1` or `Restarting` | Check `docker-compose logs db`. Common: missing `.env` variables (`MYSQL_ROOT_PASSWORD`, `MYSQL_DATABASE`, etc.) or insufficient memory. |
| **Network partition** | `zoneminder` cannot resolve `db` hostname | Both services must share `zoneminder_network`. Verify `docker-compose.yml` networks section and that `docker-compose up` was run (not `docker run` standalone). |
| **Wrong credentials** | Entrypoint reaches DB but `mysql -u "$ZM_DB_USER" -p"$ZM_DB_PASS"` fails | Ensure `.env` `MYSQL_USER`/`MYSQL_PASSWORD` match `ZM_DB_USER`/`ZM_DB_PASS` passed to `zoneminder` service. The compose file maps them 1:1. |
| **DB volume corrupted** | `db` starts but schema missing; `table_count` = 0 on every restart | Run `docker-compose down -v` to wipe `db_data` volume, then `docker-compose up -d` to reinitialize from `zm_create.sql`. |

### Entrypoint Phase Mapping
The DB wait-and-init logic lives in **Phase 3** of `entrypoint.sh`:
- Lines 35–47: `netcat -z ${ZM_DB_HOST} 3306` loop
- Lines 49–65: `table_count` check, `CREATE DATABASE/USER/GRANT`, `zm_create.sql` import
- Lines 67–70: `ZM_OPT_USE_EVENTNOTIFICATION=1` update
- Lines 72–75: `zm.conf` credential rewrite

If the container exits before `service zoneminder start`, the failure is in this phase.

---

## 2. Configuration Not Persisting

### Symptom
- Changes to ZoneMinder settings (via web UI) disappear after container restart
- `/etc/zm/zm.conf` reverts to defaults on every start
- Face recognition `known_faces` appear empty after recreate

### Root Causes & Fixes

| Cause | Evidence | Fix |
|-------|----------|-----|
| **Volumes not declared/attached** | `docker-compose ps` shows containers up but `docker volume ls` missing `zm_config`, `known_faces`, `unknown_faces` | Ensure `docker-compose.yml` `volumes:` section lists all five named volumes and `zoneminder` service `volumes:` mounts them. Run `docker-compose up -d` (not `docker run`). |
| **First-run seeding overwrites** | `entrypoint.sh` Phase 1 copies `/org/etc/zm/*` → `/etc/zm` every boot | This only runs when `/etc/zm` is **empty** (`ls -A` returns nothing). If your volume mount is correct, the directory won't be empty on restart. Verify mount target: `/etc/zm` (not `/etc/zm/` with trailing slash issues). |
| **Bind mount vs named volume** | Using `-v ./config:/etc/zm` in a custom override but host directory is empty | Named volumes (`zm_config:`) are managed by Docker and persist across `down`/`up`. Bind mounts require pre-populated host dirs. Prefer named volumes for config. |
| **Permission mismatch on volume** | `ls -la /etc/zm` inside container shows `root:root` but ZoneMinder runs as `www-data` | The Dockerfile/entrypoint does not chown volumes. If you pre-seed a volume on host, ensure UID/GID matches container user (typically `www-data` = 33:33). Or let entrypoint seed on first run (empty volume). |

### Volume Definitions (docker-compose.yml)
```yaml
volumes:
  - zm_config:/etc/zm
  - zm_cache:/var/cache/zoneminder
  - known_faces:/var/lib/zmeventnotification/known_faces
  - unknown_faces:/var/lib/zmeventnotification/unknown_faces
  - type: tmpfs
    target: /dev/shm
    tmpfs:
      size: 400000000
```

**Expected permissions** (after first successful init):
- `/etc/zm`: owned by `root:root` (config files read by `www-data` via Apache)
- `/var/cache/zoneminder`: owned by `www-data:www-data` (writable by ZM processes)
- `/var/lib/zmeventnotification/known_faces` & `unknown_faces`: owned by `www-data:www-data` (mlapi/hook writes crops here)

---

## 3. ML API (mlapi) Not Starting / Object Detection Failing

### Symptom
- `zmeventnotification` hook logs show `Connection refused` or `401 Unauthorized` when calling `http://localhost:9000/detect`
- No detection results in MQTT events
- `mlapi` process not visible in `ps aux` inside container

### Root Causes & Fixes

| Cause | Evidence | Fix |
|-------|----------|-----|
| **mlapi not launched** | `entrypoint.sh` has mlapi start line **commented out** (line 78: `#python3 /usr/src/app/mlapi/mlapi.py -c mlapiconfig.ini`) | Uncomment or add a process manager (supervisord, systemd-in-container) to run mlapi as a background service. The current entrypoint only starts Apache + ZoneMinder. |
| **OpenCV missing / wrong build** | `ImportError: libopencv_dnn.so.4.6` or `cv2.dnn` not available | Dockerfile builds OpenCV 4.6.0 from source in builder stage and copies to `/usr/local`. Verify `COPY --from=opencv_builder /usr/local /usr/local` succeeded. Check `python3 -c "import cv2; print(cv2.__version__)"` inside container. |
| **Model weights missing** | mlapi starts but detection returns empty results | Models (YOLO weights, face embeddings) are expected in `/usr/src/app/mlapi/` or configured via `mlapiconfig.ini`. Ensure they're baked into the image or mounted via a volume. |
| **MLAPI_SECRET_KEY mismatch** | Hook logs `401 Unauthorized` | Entrypoint regenerates `MLAPI_SECRET_KEY` on **every startup** (Phase 5, `openssl rand -base64 32`). The hook reads it from `/etc/zm/secrets.ini` at runtime. If mlapi runs in a **separate container**, it must share the same `zm_config` volume or you must pin a fixed secret via `.env` and modify entrypoint. |
| **Port 9000 not listening** | `netstat -tlnp` inside container shows no `:9000` | mlapi defaults to port 9000. Check `mlapiconfig.ini` `port` setting. The `docker-compose.override.yml` exposes host `7000 → 9000` for external access. |

### Entrypoint Phase Mapping
- **Phase 5 (lines 80–115)**: `secrets.ini` rewrite including `MLAPI_SECRET_KEY` generation
- **MLAPI start**: Currently **absent** from entrypoint (commented placeholder at line 78)

> **Note**: The Dockerfile clones `mlapi` from GitHub and installs Python deps, but the runtime entrypoint does not launch it. This is a known gap — mlapi must be started via a process supervisor or a dedicated sidecar container.

---

## 4. MQTT Authentication Failures

### Symptom
- `zmeventnotification` logs: `MQTT connection refused: bad username or password`
- Mosquitto logs: `Client <unknown> disconnected, not authorised.`
- External clients (Home Assistant) cannot subscribe to `zoneminder/#`

### Root Causes & Fixes

| Cause | Evidence | Fix |
|-------|----------|-----|
| **Password file not generated** | `eclipse-mosquitto` container exits immediately or logs show `password_file` missing | `entrypoint_mosquitto.sh` generates `/mosquitto/config/password_file` via `mosquitto_passwd -b`. Requires `MQTT_USER` and `MQTT_PASSWORD` env vars. Verify they're set in `.env` and passed to `eclipse-mosquitto` service. |
| **Credentials mismatch** | `zoneminder` service uses different `MQTT_USER`/`MQTT_PASSWORD` than `eclipse-mosquitto` | Both services read from the **same** `.env` variables. Ensure single `.env` file; no per-service overrides. |
| **MQTT disabled in zmeventnotification.ini** | Hook/server logs show `MQTT not enabled` | Entrypoint Phase 4 (lines 80–94) enables MQTT section **only if** `MQTT_HOST` is set and `/etc/zm/zmeventnotification.ini` exists. In compose, `MQTT_HOST=eclipse-mosquitto` is injected. If `zmeventnotification.ini` missing (volume not seeded), MQTT stays disabled. |
| **SSL/TLS mismatch** | Entrypoint forces `enable = no` under `[ssl]` section (line 93) | If you need TLS, either: (a) modify entrypoint to not disable SSL, or (b) run a TLS-terminating proxy in front of Mosquitto. |
| **Mosquitto listener config** | `entrypoint_mosquitto.sh` only creates `listener 1883` with password file | For WebSocket (port 9001), add a second listener block in the generated `mosquitto.conf` (currently not present). |

### Entrypoint Phase Mapping
- **Mosquitto entrypoint** (`entrypoint_mosquitto.sh`): Generates `mosquitto.conf` + `password_file` at startup
- **Zoneminder entrypoint Phase 4** (lines 80–94): Rewrites `zmeventnotification.ini` `[mqtt]` section with `server`, `username`, `password`, `retain`
- **Phase 5** (lines 96–105): Rewrites `secrets.ini` portal URL, `ZM_USER`, `ZM_PASSWORD`, `MLAPI_SECRET_KEY`

---

## 5. Volume Permission Issues

### Symptom
- `Permission denied` writing to `/var/cache/zoneminder`, `/var/lib/zmeventnotification/known_faces`, or `/dev/shm`
- ZoneMinder logs: `Unable to write event images`
- Face recognition: `Could not save unknown face crop`

### Expected Ownership & Permissions

| Volume / Path | Expected Owner | Expected Mode | Notes |
|---------------|----------------|---------------|-------|
| `zm_config` → `/etc/zm` | `root:root` | `755` / `644` | Read-only for `www-data`; entrypoint writes here at startup |
| `zm_cache` → `/var/cache/zoneminder` | `www-data:www-data` (33:33) | `755` | ZM writes event images, DB cache |
| `known_faces` → `/var/lib/zmeventnotification/known_faces` | `www-data:www-data` | `755` | mlapi/hook reads reference faces; writes new enrollments |
| `unknown_faces` → `/var/lib/zmeventnotification/unknown_faces` | `www-data:www-data` | `755` | Hook writes unrecognized face crops |
| `tmpfs` → `/dev/shm` | `root:root` (default) | `1777` (tmpfs default) | Shared memory for ZM frame buffers (~400MB) |
| `mosquitto_data` → `/mosquitto/data` | `mosquitto:mosquitto` (UID 1883) | `755` | Mosquitto persistence; handled by broker image |

### Common Fixes

1. **Let entrypoint seed on first run** — Start with **empty** named volumes. The entrypoint copies `/org/etc/zm` → `/etc/zm` (Phase 1) and ZoneMinder creates cache subdirs with correct ownership on first service start.

2. **If pre-seeding volumes on host** — Set ownership before `docker-compose up`:
   ```bash
   # On host (adjust paths to your volume mountpoints)
   sudo chown -R 33:33 /var/lib/docker/volumes/zm_cache/_data
   sudo chown -R 33:33 /var/lib/docker/volumes/known_faces/_data
   sudo chown -R 33:33 /var/lib/docker/volumes/unknown_faces/_data
   ```

3. **Tmpfs size** — If ZoneMinder crashes with `shared memory` errors, increase `size` in compose (currently 400MB). For high-res cameras, try `size: 1000000000` (1GB).

4. **SELinux / AppArmor** — On hosts with SELinux enforcing, add `:Z` or `:z` suffix to volume mounts in compose, or relabel:
   ```bash
   chcon -Rt container_file_t /var/lib/docker/volumes/zm_config/_data
   ```

---

## 6. Timezone / Timestamp Issues

### Symptom
- Event timestamps in ZoneMinder UI are wrong (off by hours)
- PHP logs show `date.timezone` warnings
- MQTT event timestamps don't match local time

### Fix
Ensure `TZ` is set in `.env` to a valid IANA zone (e.g., `Europe/Berlin`, `America/New_York`). Entrypoint Phase 2 (lines 13–33):
1. Writes `$TZ` to `/etc/timezone`
2. Symlinks `/etc/localtime` → `/usr/share/zoneinfo/$TZ`
3. Runs `dpkg-reconfigure tzdata`
4. Updates **all** `php.ini` files (`date.timezone = $TZ`)

If the container was started without `TZ`, restart with it set. The timezone is applied at every boot.

---

## 7. ZoneMinder Service Fails to Start

### Symptom
- `service zoneminder start` returns `FAIL` or container exits after Apache starts
- Logs: `zmc`/`zma`/`zmtrigger` processes die immediately

### Common Causes

| Cause | Check | Fix |
|-------|-------|-----|
| **Database schema version mismatch** | `mysql -e "SELECT Value FROM Config WHERE Name='ZM_DYN_DB_VERSION';"` | If upgrading ZM version, run `zmupdate.pl` manually or ensure entrypoint's `zm_create.sql` matches image version. |
| **Insufficient shared memory** | `df -h /dev/shm` shows 100% used | Increase `tmpfs` size in compose (see Volume Permission Issues). |
| **Apache config error** | `docker-compose exec zoneminder apache2ctl configtest` | Check `/etc/apache2/conf-enabled/zoneminder.conf` — seeded from `/org/etc/zm` on first run. |
| **Missing `zm.conf` DB creds** | `cat /etc/zm/zm.conf | grep ZM_DB_` shows empty values | Entrypoint Phase 3 rewrites these (lines 72–75). If DB wasn't reachable at that point, they stay as placeholders. Restart after DB is up. |

---

## 8. Event Notification Hook Not Triggering

### Symptom
- ZoneMinder events fire (alarms recorded) but no MQTT messages published
- `zmeventnotification.pl --hook` not invoked

### Checks

1. **ZoneMinder `OPT_USE_EVENTNOTIFICATION`** — Entrypoint sets this to `1` in DB (Phase 3, line 69). Verify:
   ```sql
   SELECT Value FROM Config WHERE Name='ZM_OPT_USE_EVENTNOTIFICATION';
   -- Should return 1
   ```

2. **Hook script path in ZoneMinder** — In ZM web UI: Options → Event → `EVENT_HOOK` = `/opt/zmeventnotification/zmeventnotification.pl --hook`

3. **Secrets.ini credentials** — Hook reads `ZM_USER`/`ZM_PASSWORD` from `/etc/zm/secrets.ini` (Phase 5). Must match a valid ZM web user with API access.

4. **MLAPI reachable** — Hook POSTs to `http://localhost:9000/detect`. If mlapi not running (see §3), hook may timeout and skip MQTT publish.

---

## Debugging Checklist (Run in Order)

1. `docker-compose ps` — All three services `Up`?
2. `docker-compose logs db` — MariaDB healthy, no crash loops?
3. `docker-compose logs zoneminder | head -50` — Entrypoint phases completed? Look for:
   - `Seeding config from /org/etc/zm` (first run only)
   - `Waiting for MariaDB server to start...` → `done`
   - `There are N tables in the zm database`
   - `Updating ZoneMinder configuration`
   - `MQTT enabled` (if `MQTT_HOST` set)
   - `Starting Apache` / `Starting ZoneMinder`
4. `docker-compose logs eclipse-mosquitto` — `mosquitto_passwd` ran, broker listening on 1883?
5. `docker-compose exec zoneminder mysql -h db -u "$ZM_DB_USER" -p"$ZM_DB_PASS" "$ZM_DB_NAME" -e "SELECT 1;"` — DB reachable with credentials?
6. `docker-compose exec zoneminder ls -la /etc/zm /var/cache/zoneminder /var/lib/zmeventnotification/` — Volumes mounted, perms OK?
7. `docker-compose exec zoneminder curl -H "Authorization: Bearer $(grep MLAPI_SECRET_KEY /etc/zm/secrets.ini | cut -d= -f2)" http://localhost:9000/health` — mlapi responding? (if running)

---

## Related Pages

- [Entrypoint Flow](../operations/entrypoint-flow.md) — Phase-by-phase trace of `entrypoint.sh`
- [Deployment Guide](../operations/deployment.md) — `.env` schema, compose commands, port mappings
- [Event Notifications & MQTT](../integrations/event-notifications.md) — MQTT broker config, secrets.ini, topic flow
- [ML/AI Pipeline](../architecture/ml-pipeline.md) — mlapi, OpenCV, face recognition volumes, model paths
