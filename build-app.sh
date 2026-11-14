#!/bin/bash
# 转发到 App/build-app.sh
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$SCRIPT_DIR/App/build-app.sh" "$@"
