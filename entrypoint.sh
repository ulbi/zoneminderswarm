#!/bin/bash

if [ -z "$(ls -A /etc/zm)" ]; then
   cp -R /org/etc/zm/* /etc/zm/
fi

# Wait for the db container to be ready
until netcat -z ${ZM_DB_HOST} 3306; do
  echo "Waiting for MariaDB server to start..."
  sleep 1
done

# Create the user and database in MariaDB
mysql -u root -p${MYSQL_ROOT_PASSWORD} -h ${ZM_DB_HOST} -e "CREATE DATABASE IF NOT EXISTS ${ZM_DB_NAME}; CREATE USER IF NOT EXISTS '${ZM_DB_USER}'@'%' IDENTIFIED BY '${ZM_DB_PASS}'; GRANT ALL PRIVILEGES ON ${ZM_DB_NAME}.* TO '${ZM_DB_USER}'@'%'; FLUSH PRIVILEGES;"

# check whether the DB is initialized
if mysql -u ${ZM_DB_USER} -p${ZM_DB_PASS} -h ${ZM_DB_HOST} -e "use ${ZM_DB_NAME};" 2>/dev/null; then
  echo "Database exists"
else
  echo "Database does not exist"
  # Perform actions when the database does not exist
  # Import the zm_create.sql file into the database
  mysql -u ${ZM_DB_USER} -p${ZM_DB_PASS} -h ${ZM_DB_HOST} ${ZM_DB_NAME} < /usr/share/zoneminder/db/zm_create.sql
fi


# Start ZoneMinder
service apache2 start
service zoneminder start

# Start the event notification server
#cd /opt/zmeventnotification
#./zmeventnotification.pl --config /etc/zm/zmeventnotification.ini

# Keep the container running
tail -f /dev/null
