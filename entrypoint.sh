#!/bin/bash
set -e

# Inject password from environment variable if set
if [ -n "$BEEF_PASSWORD" ]; then
    sed -i "s/CHANGE_ME_BEEF_PASSWORD/$BEEF_PASSWORD/g" /beef/config.yaml
fi

# Start BeEF
exec /beef/beef "$@"
