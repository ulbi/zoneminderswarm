#!/bin/bash

################################################################################################
#
# check for first time config - if so set it up
#
################################################################################################
if [ -z "$(ls -A /etc/zm)" ]; then
   cp -R /org/etc/zm/* /etc/zm/
fi

################################################################################################
#
# set the timezone correctly
#
################################################################################################
if [ -n "$TZ" ]; then
    echo $TZ > /etc/timezone
    rm -rf /etc/localtime
    ln -s /usr/share/zoneinfo/$TZ /etc/localtime
    dpkg-reconfigure --frontend noninteractive tzdata

    find /etc -name "php.ini" | while read -r filepath
    do
        # Check if date.timezone is set (commented or uncommented)
        grep -q "^[;]*\s*date.timezone " "${filepath}"
        
        if [ $? -eq 0 ]; then
            # If date.timezone is found (either commented or uncommented), change its value
            # and uncomment it if necessary
            sed -i "s|^[;]*\s*date.timezone .*|date.timezone = ${TZ}|g" "${filepath}"
        else
            # If date.timezone is not found at all, add it
            echo "date.timezone = ${TZ}" >> "${filepath}"
        fi
    done
fi


################################################################################################
#
# Check and if required setup the DB
#
################################################################################################
until netcat -z ${ZM_DB_HOST} 3306; do
  echo "Waiting for MariaDB server to start..."
  sleep 1
done

# Use MySQL to count tables in the database
table_count=$(mysql -h "$ZM_DB_HOST" -u "$ZM_DB_USER" -p"$ZM_DB_PASS" -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = '$ZM_DB_NAME';" -s)

# Check if there are tables in the database
if [ "$table_count" -gt 0 ]; then
  echo "There are $table_count tables in the $ZM_DB_NAME database"
  # Perform actions on the existing tables
else
  echo "There are no tables in the $ZM_DB_NAME database"
  # Perform actions when there are no tables
  # Create the user and database in MariaDB
  mysql -u root -p${MYSQL_ROOT_PASSWORD} -h ${ZM_DB_HOST} -e "CREATE DATABASE IF NOT EXISTS ${ZM_DB_NAME}; CREATE USER IF NOT EXISTS '${ZM_DB_USER}'@'%' IDENTIFIED BY '${ZM_DB_PASS}'; GRANT ALL PRIVILEGES ON ${ZM_DB_NAME}.* TO '${ZM_DB_USER}'@'%'; FLUSH PRIVILEGES;"
  # Import the zm_create.sql file into the database
  mysql -u ${ZM_DB_USER} -p${ZM_DB_PASS} -h ${ZM_DB_HOST} ${ZM_DB_NAME} < /usr/share/zoneminder/db/zm_create.sql
fi

# Update the ZoneMinder configuration
mysql -u ${ZM_DB_USER} -p${ZM_DB_PASS} -h ${ZM_DB_HOST} ${ZM_DB_NAME} -e \
"UPDATE Config SET Value = '1' WHERE Name = 'ZM_OPT_USE_EVENTNOTIFICATION';"

# Execute the main ZoneMinder command
exec "$@"


# Replace the values in zm.conf
sed -i "s/ZM_DB_HOST=.*/ZM_DB_HOST=$ZM_DB_HOST/" /etc/zm/zm.conf
sed -i "s/ZM_DB_USER=.*/ZM_DB_USER=$ZM_DB_USER/" /etc/zm/zm.conf
sed -i "s/ZM_DB_PASS=.*/ZM_DB_PASS=$ZM_DB_PASS/" /etc/zm/zm.conf
sed -i "s/ZM_DB_NAME=.*/ZM_DB_NAME=$ZM_DB_NAME/" /etc/zm/zm.conf



################################################################################################
#
# Start the Machine Learning Service
#
################################################################################################
#python3 /usr/src/app/mlapi/mlapi.py -c mlapiconfig.ini

################################################################################################
#
# Check and configure the event system
#
################################################################################################
if [ -e "/etc/zm/zmeventnotification.ini" ]; then
  # is mosquitto installed?
  if [ -n "$MQTT_HOST" ]; then
    sed -i "/\[mqtt\]/,/^\[/ s/^#*\s*enable\s*=.*/enable = yes/" /etc/zm/zmeventnotification.ini
    sed -i "/\[mqtt\]/,/^\[/ s/^#*\s*server\s*=.*/server = $MQTT_HOST/" /etc/zm/zmeventnotification.ini
    sed -i "/\[mqtt\]/,/^\[/ s/^#*\s*username\s*=.*/username = $MQTT_USER/" /etc/zm/zmeventnotification.ini
    sed -i "/\[mqtt\]/,/^\[/ s/^#*\s*password\s*=.*/password = $MQTT_PASSWORD/" /etc/zm/zmeventnotification.ini
    sed -i "/\[mqtt\]/,/^\[/ s/^#*\s*retain\s*=.*/retain = yes/" /etc/zm/zmeventnotification.ini
    sed -i "/\[ssl\]/,/^\[/ s/^#*\s*enable\s*=.*/enable = no/" /etc/zm/zmeventnotification.ini
  fi
  # adjust the secrets.ini
  sed -i 's|https://portal/|http://zoneminder/|g' /etc/zm/secrets.ini
  sed -i "s/^ZM_USER=.*/ZM_USER=${ZM_USER}/" /etc/zm/secrets.ini
  sed -i "s/^ZM_PASSWORD=.*/ZM_PASSWORD=${ZM_PASSWORD}/" /etc/zm/secrets.ini
  SECRET_KEY=$(openssl rand -base64 32)
  if grep -q 'MLAPI_SECRET_KEY' /etc/zm/secrets.ini; then
    sed -i "s/^MLAPI_SECRET_KEY=.*/MLAPI_SECRET_KEY=${SECRET_KEY}/" /etc/zm/secrets.ini
  else
    echo "MLAPI_SECRET_KEY=${SECRET_KEY}" >> /etc/zm/secrets.ini
  fi



  # Start the event notification server
  #cd /opt/zmeventnotification
  #./zmeventnotification.pl --debug --config /etc/zm/zmeventnotification.ini
fi

# Start ZoneMinder
service apache2 start
service zoneminder start


# Keep the container running
tail -f /dev/null
