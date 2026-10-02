#!/bin/sh
set -eu
: "${GMORN_TRACE_ENGINE_BIN:?Set by tools/test.sh}"
exec "$GMORN_TRACE_ENGINE_BIN" --audio-driver Dummy "$@"
