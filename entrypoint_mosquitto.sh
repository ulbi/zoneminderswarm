#!/bin/sh -x
# Generate password file
mkdir -p /mosquitto/config

cat <<EOF > /mosquitto/config/mosquitto.conf
listener 1883
password_file /mosquitto/config/password_file
persistence true
persistence_location /mosquitto/data/
log_type all
log_type debug
log_dest stdout
EOF

touch /mosquitto/config/password_file
mosquitto_passwd -b /mosquitto/config/password_file $MQTT_USER $MQTT_PASSWORD
# Start Mosquitto
/usr/sbin/mosquitto -c /mosquitto/config/mosquitto.conf