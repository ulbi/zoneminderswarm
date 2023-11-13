# Zoneminder containerized

This is a containerized Zoneminder installation. It uses an external database.
The environment variables for the services are set in an `.env` file.

## Services

### db

The `db` service runs a MariaDB database version 10.9. It has the following environment variables:

- `MYSQL_ROOT_PASSWORD`: The root password for the MariaDB database.
- `MYSQL_DATABASE`: The name of the database to create.
- `MYSQL_USER`: The name of the database user.
- `MYSQL_PASSWORD`: The password for the database user.

The `db` service uses a volume called `db_data` to store the database data, and it is connected to the `zoneminder_network` network.

### zoneminder

The `zoneminder` service builds a ZoneMinder image from a Dockerfile in the same directory as the Docker Compose file. It has the following environment variables:

- `ZM_DB_HOST`: The hostname of the database service (`db` in this case).
- `MYSQL_ROOT_PASSWORD`: The root password for the MariaDB database.
- `ZM_DB_NAME`: The name of the database to connect to.
- `ZM_DB_USER`: The name of the database user.
- `ZM_DB_PASS`: The password for the database user.
- `ZM_SERVER_HOST`: The hostname of the ZoneMinder service (`zoneminder` in this case).

The `zoneminder` service exposes the ports `80` and `9000` from Zonemindery, and uses the volumes `zm_config`, `known_faces`, and `unknown_faces` to store configuration and face recognition data. It also uses a `tmpfs` volume for shared memory with a size of approximately 400MB. Finally, it depends on the `db` service and is connected to the `zoneminder_network` network.

## Volumes

The Docker Compose file creates the following volumes:

- `db_data`: The volume used by the `db` service to store the MariaDB database data.
- `zm_config`: The volume used by the `zoneminder` service to store the ZoneMinder configuration.
- `known_faces`: The volume used by the `zoneminder` service to store known face recognition data.
- `unknown_faces`: The volume used by the `zoneminder` service to store unknown face recognition data.
- `mosquitto_data`: The volume used by the `eclipse-mosquitto` service to store the data for mosquitto.

## Networks

The Docker Compose file creates the following network:

- `zoneminder_network`: The network used by both services to communicate with each other.

## Running the Services

To run the services, create an `.env` file in the same directory as the Docker Compose file with the following contents:
```
MYSQL_ROOT_PASSWORD=<root_password>
MYSQL_DATABASE=<database_name>
MYSQL_USER=<database_user>
MYSQL_PASSWORD=<database_password>
TZ=Europe/Berlin
MQTT_USER=<mqtt_user>
MQTT_PASSWORD=<mqtt_pass>
ZM_USER=<ZM User - often admin>
ZM_PASSWORD=<password for the ZM user - used to connect the eventservice>
```

Replace the values with your desired values.

Then, in the same directory, run the following command:
```
docker-compose up -d
```
This will start the services in detached mode, allowing them to run in the background. To stop the services, run:

```
docker-compose down
```

This will stop and remove the containers created by the Docker Compose file.
