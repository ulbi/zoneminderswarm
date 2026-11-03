# Files

- [Database Integration](database.md) - Documents the MariaDB schema bootstrap (zm_create.sql), connection configuration (zm.conf), root vs app user separation, the table-count initialization check, and ZM_OPT_USE_EVENTNOTIFICATION enabling used by the ZoneMinder container.
- [Event Notifications & MQTT](event-notifications.md) - How zmeventnotification integrates with ZoneMinder, MQTT broker configuration (Mosquitto password auth, persistence), runtime rewriting of zmeventnotification.ini and secrets.ini, the event hook flow, and MQTT topic consumption by external clients.
