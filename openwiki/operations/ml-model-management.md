---
type: operations
title: ML Model Management
description: How ML models are fetched at build time via get_models.sh, stored in volumes for face recognition reference images, and used by mlapi for object detection and face recognition.
tags: [ml, models, object-detection, face-recognition, mlapi, opencv, docker, build, volumes]
verified:
  - by: openwiki/0.7.3
    at: 2026-11-03T01:11:51.876Z
sources:
  - id: openwiki-source-b79fbbd921df689b4bbdc82f
    resource: repo://docker-compose.yml
  - id: openwiki-source-bb1ebe868e35e9e500714501
    resource: repo://Dockerfile
generated: { by: "openwiki/0.7.3", at: "2026-11-03T01:11:51.876Z" }
---

# ML Model Management

This document describes how machine learning models are acquired, stored, and used in the ZoneMinder container stack. It covers the **build-time model download** (`get_models.sh`), the **persistent volumes** for face recognition reference data (`known_faces` / `unknown_faces`), and the **model update strategy** (rebuild vs. volume mount).

---

## Model Acquisition at Build Time (`get_models.sh`)

During the Docker build, the `mlapi` repository is cloned and its `get_models.sh` script executes to download pre-trained model weights. These weights are **baked into the image** — they are not stored in Docker volumes and do not persist across image rebuilds.

```dockerfile
# From Dockerfile (lines 95-105)
WORKDIR /usr/src/app/mlapi
RUN git clone https://github.com/ZoneMinder/mlapi.git .
RUN pip3 install --no-cache-dir -r requirements.txt
RUN ./get_models.sh
```

### What `get_models.sh` Downloads

The script (from the upstream `ZoneMinder/mlapi` repository) fetches:

| Model | Files | Purpose |
|-------|-------|---------|
| **YOLOv4-tiny (object detection)** | `yolov4-tiny.weights`, `yolov4-tiny.cfg`, `coco.names` | General object detection (person, car, dog, etc.) via OpenCV DNN |
| **Face detector (OpenCV DNN)** | `opencv_face_detector_uint8.pb`, `opencv_face_detector.pbtxt` | Detects face bounding boxes in frames |
| **Face embedding (OpenFace)** | `nn4.small2.v1.t7` (Torch7 model) | Computes 128-d embeddings for face recognition |

These files are placed in the mlapi working directory (`/usr/src/app/mlapi/`) and loaded at runtime by the Flask application.

### Implications

- **Models are immutable at runtime** — You cannot update YOLO weights or face models by replacing files in a volume; the container reads from the image layer.
- **Updating models requires a rebuild** — Change the `get_models.sh` script (or the mlapi git reference), then `docker-compose build --no-cache zoneminder`.
- **OpenCV version pinning** — The Dockerfile pins `OPENCV_VERSION=4.6.0` in the builder stage. The DNN module API is stable across 4.x, but if you upgrade OpenCV you must rebuild the `opencv_builder` stage and verify mlapi compatibility.

---

## Face Recognition Volumes: `known_faces` / `unknown_faces`

Unlike model weights, **face reference images** (the photos of known people used for recognition) and **unknown face crops** (unrecognized faces saved for review) are stored in Docker named volumes so they survive container recreation.

### Volume Definitions (docker-compose.yml)

```yaml
volumes:
  - known_faces:/var/lib/zmeventnotification/known_faces
  - unknown_faces:/var/lib/zmeventnotification/unknown_faces
```

### `known_faces` Volume

- **Mount path:** `/var/lib/zmeventnotification/known_faces`
- **Purpose:** Stores reference images for known individuals. Each person gets a subdirectory (e.g., `known_faces/John/`, `known_faces/Jane/`).
- **Population:** Manually curated by administrators. Images can be added via:
  - ZoneMinder UI (Face recognition → Add face)
  - Directly placing JPEG/PNG files in the volume (e.g., `docker cp photo.jpg zoneminder:/var/lib/zmeventnotification/known_faces/John/`)
- **Usage at runtime:** On mlapi startup (or when the `/train` endpoint is called), the face recognition module loads all images under this directory, computes embeddings using the OpenFace model (`nn4.small2.v1.t7`), and caches them in memory for fast comparison.

### `unknown_faces` Volume

- **Mount path:** `/var/lib/zmeventnotification/unknown_faces`
- **Purpose:** When face detection finds a face that does **not** match any known person (similarity below `face_min_confidence` threshold in `mlapiconfig.ini`), the cropped face image is saved here with a timestamped filename (e.g., `unknown_20240115_143022_1.jpg`).
- **Operational use:** Operators periodically review this directory. To "teach" the system a new person, move/copy a crop from `unknown_faces/` into a subdirectory under `known_faces/<name>/` and trigger a reload (restart mlapi or call `/train`).

### Volume Persistence

Both volumes are **Docker named volumes** (`known_faces`, `unknown_faces`), backed by the Docker volume driver (default `local`). Data persists across:

- Container stop/start
- Container removal/recreation (`docker-compose down && docker-compose up -d`)
- Image rebuilds (as long as the volume is not explicitly removed)

---

## Model Update Strategy: Rebuild vs. Volume Mount

| Artifact | Stored In | Update Mechanism |
|----------|-----------|------------------|
| **YOLO weights** (`.weights`, `.cfg`, `.names`) | Image layer (`/usr/src/app/mlapi/`) | **Rebuild image** — modify `get_models.sh` or mlapi repo ref, then `docker-compose build --no-cache zoneminder` |
| **Face detector prototxt/model** | Image layer (`/usr/src/app/mlapi/`) | **Rebuild image** — same as above |
| **Face embedding model** (`nn4.small2.v1.t7`) | Image layer (`/usr/src/app/mlapi/`) | **Rebuild image** — same as above |
| **OpenCV libraries / Python bindings** | Image layer (`/usr/local/` from builder stage) | **Rebuild builder stage** — change `OPENCV_VERSION`, rebuild full image |
| **Known face reference images** | `known_faces` volume (`/var/lib/zmeventnotification/known_faces/`) | **Runtime** — add/remove files in volume; trigger mlapi reload |
| **Unknown face crops** | `unknown_faces` volume (`/var/lib/zmeventnotification/unknown_faces/`) | **Runtime** — written by mlapi automatically; manually reviewed/moved |

### Why This Split?

- **Model weights** are large, versioned artifacts that should be reproducible. Baking them into the image ensures every container runs the exact same model version.
- **Face reference data** is operational state that grows over time as you enroll new people. Volumes let you manage this without rebuilding images.

---

## OpenCV Version Pinning and Rebuild Implications

The Dockerfile uses a **multi-stage build** with a dedicated `opencv_builder` stage:

```dockerfile
# Stage 1: opencv_builder
FROM ubuntu:22.04 as opencv_builder
ENV OPENCV_VERSION=4.6.0
# ... downloads, compiles, installs to /usr/local

# Stage 2: final
FROM ubuntu:22.04
COPY --from=opencv_builder /usr/local /usr/local
```

### Pinned Version

- `OPENCV_VERSION=4.6.0` is hardcoded in the `ENV` directive.
- OpenCV contrib modules are fetched from the matching tag (`opencv_contrib-4.6.0`), enabling the `face` module (facerec, Fisherfaces, LBPH) used by mlapi for face recognition.

### Rebuild Triggers

| Change | Required Action |
|--------|-----------------|
| Update `OPENCV_VERSION` (e.g., 4.6.0 → 4.8.0) | `docker-compose build --no-cache` — rebuilds `opencv_builder` stage and final stage |
| Modify `get_models.sh` or mlapi git URL | `docker-compose build --no-cache zoneminder` — re-runs model download |
| Change mlapi Python `requirements.txt` | `docker-compose build --no-cache zoneminder` — re-installs Python deps |
| Add/remove face reference images | **No rebuild** — edit `known_faces` volume directly |

### Compatibility Notes

- mlapi uses OpenCV's **DNN module** (`cv2.dnn.readNetFromDarknet`, `readNetFromTensorflow`, `readNetFromTorch`). These APIs are stable across OpenCV 4.x.
- The `face` module (from contrib) provides `cv2.face.LBPHFaceRecognizer_create()` and `cv2.face.FisherFaceRecognizer_create()` — mlapi uses the Torch embedding model (`nn4.small2.v1.t7`) via `cv2.dnn.readNetFromTorch`, not the classic `face` recognizers, so it is less sensitive to contrib module changes.
- If you upgrade OpenCV, test that mlapi starts and `/detect` returns results before deploying.

---

## Runtime Configuration for Models

mlapi reads model paths from its config file (`/usr/src/app/mlapi/mlapiconfig.ini`). The default paths point to the build-time download location:

```ini
# Example mlapiconfig.ini sections (from upstream mlapi)
[general]
listen_port = 5000

[object]
model_config = /usr/src/app/mlapi/yolov4-tiny.cfg
model_weights = /usr/src/app/mlapi/yolov4-tiny.weights
model_labels = /usr/src/app/mlapi/coco.names

[face]
face_detection_model = /usr/src/app/mlapi/opencv_face_detector_uint8.pb
face_detection_proto = /usr/src/app/mlapi/opencv_face_detector.pbtxt
face_recognition_model = /usr/src/app/mlapi/nn4.small2.v1.t7
face_min_confidence = 0.6
```

These paths are **not overridden at runtime** — they point into the image filesystem. To use different model files, you would need to either:
- Rebuild the image with a custom `get_models.sh` that places files at these paths, or
- Mount a volume over `/usr/src/app/mlapi/` (not recommended — hides the baked-in models and breaks reproducibility).

---

## Operational Checklist

- [ ] **Initial deployment:** Run `docker-compose up -d` — models download at build, volumes created empty.
- [ ] **Enroll known faces:** Add reference images to `known_faces/<person>/` via UI or `docker cp`.
- [ ] **Trigger face training:** Restart mlapi (or call `POST /train` if exposed) to reload embeddings.
- [ ] **Review unknown faces:** Check `unknown_faces/` periodically; promote good crops to `known_faces/`.
- [ ] **Model updates:** To upgrade YOLO or face models, edit `get_models.sh` in the mlapi repo (or fork), update the Dockerfile git clone URL if needed, then `docker-compose build --no-cache zoneminder && docker-compose up -d`.
- [ ] **OpenCV upgrades:** Change `OPENCV_VERSION` in Dockerfile, full rebuild, validate mlapi health.

---

## Related Pages

- [ML/AI Pipeline](../architecture/ml-pipeline.md) — End-to-end inference flow, hook → mlapi → MQTT
- [Event Notifications & MQTT](../integrations/event-notifications.md) — zmeventnotification hook/config, MQTT topic flow
- [Container Design](../architecture/container-design.md) — Multi-stage Dockerfile, OpenCV builder stage
