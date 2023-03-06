#!/usr/bin/env sh

set -e
exec curl -f http://localhost:2114/health?plugin=http || exit 1
