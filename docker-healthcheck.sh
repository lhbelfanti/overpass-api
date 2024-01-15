#!/bin/bash

set -e -o pipefail

HEALTHCHECK='curl --noproxy "*" -qf "http://localhost/api/interpreter?data=\[out:json\];node(1);out;" | jq ".generator" |grep -q Overpass || exit 1'

OVERPASS_HEALTHCHECK=${OVERPASS_HEALTHCHECK:-$HEALTHCHECK}

echo "Healthcheck"
eval "${OVERPASS_HEALTHCHECK}"
