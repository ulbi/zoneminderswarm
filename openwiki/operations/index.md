# Files

- [Deployment Guide](deployment.md) - Environment variables, .env file schema, docker-compose commands, and healthcheck behavior for production deployment of the containerized ZoneMinder stack.
- [Entrypoint Flow](entrypoint-flow.md) - Phase-by-phase trace of entrypoint.sh (PID 1): config seeding from /org/etc/zm, timezone/PHP setup, database wait and bootstrap, the exec "$@" handoff and its command-override caveat, MQTT and secrets.ini configuration, and service startup.
- [ML Model Management](ml-model-management.md) - How ML models are fetched at build time via get_models.sh, stored in volumes for face recognition reference images, and used by mlapi for object detection and face recognition.
- [Troubleshooting](troubleshooting.md) - Symptom-to-root-cause troubleshooting map for the containerized ZoneMinder stack: database connection failures, config persistence issues, MQTT/event notification failures, ML/hook failures, and timezone/port issues, each tied to the exact entrypoint.sh phase, exec boundary, or compose definition that causes it.
