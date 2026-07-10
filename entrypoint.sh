#!/bin/bash
set -e

# Inject password from environment variable if set
if [ -n "$BEEF_PASSWORD" ]; then
    python3 << 'PYEOF'
import os
with open('/beef/config.yaml', 'r') as f:
    content = f.read()
content = content.replace('CHANGE_ME_BEEF_PASSWORD', os.environ['BEEF_PASSWORD'])
with open('/beef/config.yaml', 'w') as f:
    f.write(content)
PYEOF
fi

# Start BeEF
exec /beef/beef "$@"
