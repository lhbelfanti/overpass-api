#!/bin/bash

set -eo pipefail
shopt -s nullglob

echo "Running Overpass with params:"
echo "OVERPASS_PLANET_URL=${OVERPASS_PLANET_URL}"
echo "OVERPASS_DIFF_URL=${OVERPASS_DIFF_URL}"
echo "OVERPASS_UPDATES_ENABLED=${OVERPASS_UPDATES_ENABLED}"
echo "OVERPASS_UPDATE_SLEEP=${OVERPASS_UPDATE_SLEEP}"
echo "OVERPASS_RATE_LIMIT=${OVERPASS_RATE_LIMIT}"
echo "OVERPASS_SPACE=${OVERPASS_SPACE}"
echo "OVERPASS_TIME=${OVERPASS_TIME}"
echo "OVERPASS_MAX_TIMEOUT=${OVERPASS_MAX_TIMEOUT}"
echo "OVERPASS_MAX_ELEMENT_LIMIT=${OVERPASS_MAX_ELEMENT_LIMIT}"
echo "OVERPASS_FCGI_MAX_REQUESTS=${OVERPASS_FCGI_MAX_REQUESTS}"
echo "OVERPASS_FCGI_MAX_ELAPSED_TIME=${OVERPASS_FCGI_MAX_ELAPSED_TIME}"
echo "OVERPASS_MAX_SPACE_LIMIT=${OVERPASS_MAX_SPACE_LIMIT}"
echo "OVERPASS_REGEXP_ENGINE=${OVERPASS_REGEXP_ENGINE}"
echo "OVERPASS_LOG_LEVEL=${OVERPASS_LOG_LEVEL}"
echo "OVERPASS_SHARED_NAME_SUFFIX=${OVERPASS_SHARED_NAME_SUFFIX}"
echo "OVERPASS_HEALTHCHECK=${OVERPASS_HEALTHCHECK}"
echo "OVERPASS_STOP_AFTER_INIT=${OVERPASS_STOP_AFTER_INIT}"
echo ""

OVERPASS_FLUSH_SIZE=16
PLANET_FILE_PATH=/db/planet.osm.bz2

# this is used by other processes, so needs to be exported
export OVERPASS_MAX_TIMEOUT=${OVERPASS_MAX_TIMEOUT:-1000s}


for f in /docker-entrypoint-initdb.d/*; do
	case "$f" in
	*.sh)
		if [[ -x "$f" ]]; then
			echo "$0: running $f"
			"$f"
		else
			echo "$0: sourcing $f"
			# shellcheck disable=SC1090 # ignore SC1090 (unable to follow file) because they are dynamically provided
			. "$f"
		fi
		;;
	*) echo "$0: ignoring $f" ;;
	esac
	echo
done

if [[ ! -f /db/init_done ]]; then
	echo "No database directory. Initializing"

  echo "# Netscape HTTP Cookie File" >/db/cookie.jar
  echo "" >>/db/cookie.jar
	chown overpass /db/cookie.jar

  echo "Downloading planet file: ${OVERPASS_PLANET_URL}"
  EXTENSION=$(echo "${OVERPASS_PLANET_URL##*.}")
  CURL_STATUS_CODE=$(curl -L -b /db/cookie.jar -o "${PLANET_FILE_PATH}" -w "%{http_code}" "${OVERPASS_PLANET_URL}")
  # try again until it's allowed
  while [ "$CURL_STATUS_CODE" = "429" ]; do
    echo "Server responded with 429 Too many requests. Trying again in 5 minutes..."
    sleep 300
    CURL_STATUS_CODE=$(curl -L -b /db/cookie.jar -o "${PLANET_FILE_PATH}" -w "%{http_code}" "${OVERPASS_PLANET_URL}")
  done
  # for `file:///` scheme curl returns `000` HTTP status code
  if [[ $CURL_STATUS_CODE = "200" || $CURL_STATUS_CODE = "000" ]]; then
    (
      if [[ $EXTENSION = "pbf" ]]; then
        echo "Running preprocessing commands:"

        echo "mv ${PLANET_FILE_PATH} /db/planet.osm.pbf"
        mv "${PLANET_FILE_PATH}" /db/planet.osm.pbf

        echo "osmium cat -o ${PLANET_FILE_PATH} /db/planet.osm.pbf"
        osmium cat -o "${PLANET_FILE_PATH}" /db/planet.osm.pbf

        echo "rm /db/planet.osm.pbf"
        rm /db/planet.osm.pbf
      fi &&
      # init_osm3s -- Creates database
      # update_overpass -- Updates database
      # osm3s_query -- Generates areas
      echo "Creating database" \
      && /opt/overpass/bin/init_osm3s.sh "${PLANET_FILE_PATH}" /db/db /opt/overpass \
        --version="$(osmium fileinfo -e -g data.timestamp.last "${PLANET_FILE_PATH}")" \
        --compression-method=gz \
        --map-compression-method=gz \
        --flush-size=${OVERPASS_FLUSH_SIZE} \
        --use-osmium \
      && echo "Database created. Now updating it." \
      && cp -r /opt/overpass/rules /db/db \
      && chown -R overpass:overpass /db/* && \
      if [[ "$OVERPASS_UPDATES_ENABLED" = "1" ]]; then
        echo "Updating database" \
        /opt/overpass/bin/update_overpass.sh -O "${PLANET_FILE_PATH}"
      else
        echo "The database will not be updated due the value of the env variable OVERPASS_UPDATES_ENABLED=$OVERPASS_UPDATES_ENABLED"
      fi &&
      echo "Generating areas..." \
      && /opt/overpass/bin/osm3s_query --progress --rules --db-dir=/db/db </db/db/rules/areas.osm3s \
      && echo "Adding /db/init_done file" \
      && touch /db/init_done \
      && echo "Removing downloaded planet file ${PLANET_FILE_PATH}" \
      && rm "${PLANET_FILE_PATH}" \
      && echo "Running chown -R overpass:overpass /db/*" \
      && chown -R overpass:overpass /db/*
    ) || (
      echo "Failed to process planet file"
      exit 1
    )
    echo ""
    if [[ "${OVERPASS_STOP_AFTER_INIT}" == "false" ]]; then
      echo "Overpass container ready to receive requests"
    else
      echo "Overpass container initialization complete. Exiting due the value of the env variable OVERPASS_STOP_AFTER_INIT=$OVERPASS_STOP_AFTER_INIT"
      exit 0
    fi
    echo ""

  elif [[ $CURL_STATUS_CODE = "403" ]]; then
    echo "Access denied when downloading planet file. Check your OVERPASS_PLANET_URL, this image doesn't support authentication"
    cat /db/cookie.jar
    exit 1
  else
    echo "Failed to download planet file. HTTP status code: ${CURL_STATUS_CODE}"
    cat "${PLANET_FILE_PATH}"
    exit 1
  fi
else
  echo ""
  echo "Database already initialized. If it is an error, delete the /db/init_done file to run the download process again"
  echo ""
fi

# shellcheck disable=SC2016 # ignore SC2016 (variables within single quotes) as this is exactly what we want to do here
envsubst '${OVERPASS_MAX_TIMEOUT}' </etc/nginx/nginx.conf.template >/etc/nginx/nginx.conf

echo "Starting supervisord process"
exec /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf
