#!/usr/bin/env sh
set +e

OVERPASS_UPDATE_SLEEP=${OVERPASS_UPDATE_SLEEP:-60}
if [ "$OVERPASS_UPDATES_ENABLED" = "YES" ]; then
  while true; do
    if [ -n "$OVERPASS_DIFF_URL" ]; then
      /opt/overpass/bin/update_overpass.sh
    fi
    sleep "${OVERPASS_UPDATE_SLEEP}"
  done
fi
