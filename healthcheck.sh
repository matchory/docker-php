#!/usr/bin/env sh

set -e

role=${CONTAINER_ROLE:-web}

if [ "$role" = "web" ]; then
    exec curl -f http://localhost:2114/health?plugin=http || exit 1
elif [ "$role" = "worker" ]; then
    # TODO: Does a worker health check make sense?
    exit 0
else
    exit 0
fi
