#!/usr/bin/env bash
# GET 127.0.0.1/healthz → Apache → FPM ping.path; body must be "pong".
# OpenShift: exec this script (always). httpGet works only from cluster/node
# IPs (see 25-healthz.conf); public Route clients are denied after remoteip.
set -euo pipefail

readonly URL="${HEALTHCHECK_URL:-http://127.0.0.1:8080/healthz}"
# Match Docker HEALTHCHECK --timeout=5s and OpenShift probe timeoutSeconds: 5.
body="$(curl -fsS --max-time 5 "${URL}")"
if [[ "${body}" != "pong" ]]; then
    echo "healthcheck: expected pong, got: ${body}" >&2
    exit 1
fi
printf '%s\n' "${body}"
