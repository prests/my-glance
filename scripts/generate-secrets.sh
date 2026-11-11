#!/bin/bash
set -eu

: "${GLANCE_AUTH_PASSWORD:?GLANCE_AUTH_PASSWORD must be set}"

hash="$(docker run --rm glanceapp/glance@sha256:4d7445bc7971836858ffddee5d7501f1efbabb6e694a45b1dde1a789bb1943bb password:hash "$GLANCE_AUTH_PASSWORD")"
printf 'GLANCE_AUTH_PASSWORD_HASH=%s\n' "$hash"
