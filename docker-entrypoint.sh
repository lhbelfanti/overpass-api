#!/bin/bash

set -eo pipefail
shopt -s nullglob

OVERPASS_FLUSH_SIZE=16

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

  CURL_STATUS_CODE=$(curl -L -b /db/cookie.jar -o /db/planet.osm.bz2 -w "%{http_code}" "${OVERPASS_PLANET_URL}")
  # try again until it's allowed
  while [ "$CURL_STATUS_CODE" = "429" ]; do
    echo "Server responded with 429 Too many requests. Trying again in 5 minutes..."
    sleep 300
    CURL_STATUS_CODE=$(curl -L -b /db/cookie.jar -o /db/planet.osm.bz2 -w "%{http_code}" "${OVERPASS_PLANET_URL}")
  done
  # for `file:///` scheme curl returns `000` HTTP status code
  if [[ $CURL_STATUS_CODE = "200" || $CURL_STATUS_CODE = "000" ]]; then
    (
      EXTENSION=echo "${OVERPASS_PLANET_URL}##*."
      # if extension is pbf, convert to bz2
      if [[ $EXTENSION = "pbf" ]]; then
        echo "Running preprocessing commands:"

        echo "mv /db/planet.osm.bz2 /db/planet.osm.pbf"
        mv /db/planet.osm.bz2 /db/planet.osm.pbf

        echo "osmium cat -o /db/planet.osm.bz2 /db/planet.osm.pbf"
        osmium cat -o /db/planet.osm.bz2 /db/planet.osm.pbf

        echo "rm /db/planet.osm.pbf"
        rm /db/planet.osm.pbf
      fi &&
        # init_osm3s -- Creates database
        /opt/overpass/bin/init_osm3s.sh /db/planet.osm.bz2 /db/db /opt/overpass "--version=$(osmium fileinfo -e -g data.timestamp.last /db/planet.osm.bz2) --compression-method=gz --map-compression-method=gz --flush-size=${OVERPASS_FLUSH_SIZE}" &&
        echo "Database created. Now updating it." &&
        cp -r /opt/overpass/rules /db/db &&
        chown -R overpass:overpass /db/* &&

        # update_overpass -- Updates database
        echo "Updating" &&
        /opt/overpass/bin/update_overpass.sh -O /db/planet.osm.bz2 &&

        # osm3s_query -- Generates areas
        echo "Generating areas..." &&
        /opt/overpass/bin/osm3s_query --progress --rules --db-dir=/db/db </db/db/rules/areas.osm3s

        touch /db/init_done &&
        rm /db/planet.osm.bz2 &&
        chown -R overpass:overpass /db/*
    ) || (
      echo "Failed to process planet file"
      exit 1
    )

    echo "Overpass container ready to receive requests"

  elif [[ $CURL_STATUS_CODE = "403" ]]; then
    echo "Access denied when downloading planet file. Check your OVERPASS_PLANET_URL, this image doesn't support authentication"
    cat /db/cookie.jar
    exit 1
  else
    echo "Failed to download planet file. HTTP status code: ${CURL_STATUS_CODE}"
    cat /db/planet.osm.bz2
    exit 1
  fi
fi

# shellcheck disable=SC2016 # ignore SC2016 (variables within single quotes) as this is exactly what we want to do here
envsubst '${OVERPASS_MAX_TIMEOUT}' </etc/nginx/nginx.conf.template >/etc/nginx/nginx.conf

echo "Starting supervisord process"
exec /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf
