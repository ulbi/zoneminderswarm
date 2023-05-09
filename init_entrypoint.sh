#!/bin/bash

# Wait for the db container to be ready
until netcat -z ${ZM_DB_HOST} 3306; do
  echo "Waiting for MariaDB server to start..."
  sleep 1
done

# Create the user and database in MariaDB
mysql -u root -p${MYSQL_ROOT_PASSWORD} -h ${ZM_DB_HOST} -e "CREATE DATABASE IF NOT EXISTS ${ZM_DB_NAME}; CREATE USER IF NOT EXISTS '${ZM_DB_USER}'@'%' IDENTIFIED BY '${ZM_DB_PASS}'; GRANT ALL PRIVILEGES ON ${ZM_DB_NAME}.* TO '${ZM_DB_USER}'@'%'; FLUSH PRIVILEGES;"

# Copy the zm_create.sql file to the shared volume
cp /usr/share/zoneminder/db/zm_create.sql /init-scripts/zm_create.sql

# Import the zm_create.sql file into the database
mysql -u ${ZM_DB_USER} -p${ZM_DB_PASS} -h ${ZM_DB_HOST} ${ZM_DB_NAME} < /init-scripts/zm_create.sql

# Run an infinite loop to keep the container running
while true; do
  sleep 3600
done
