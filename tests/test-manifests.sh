#!/usr/bin/env bash
# Static checks on shipped OpenShift examples and baked httpd/healthcheck config.
# Does not need a cluster or a built image.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

log() { printf '%s\n' "$*"; }
pass() { PASS=$((PASS + 1)); log "[PASS] $*"; }
fail() { FAIL=$((FAIL + 1)); log "[FAIL] $*"; }

deploy="${ROOT}/examples/openshift/deployment.yaml"
kustom="${ROOT}/examples/openshift/kustomization.yaml"
cm="${ROOT}/examples/openshift/configmap.yaml"
httpd="${ROOT}/rootfs/opt/httpd/conf/httpd.conf"
hc="${ROOT}/rootfs/opt/drupal/scripts/healthcheck.sh"
examples_dir="${ROOT}/examples/openshift"

if [[ ! -f "${kustom}" ]]; then
    fail "examples/openshift/kustomization.yaml missing"
else
    pass "kustomization.yaml present"
fi

if grep -qE '^[[:space:]]+runAsUser:' "${deploy}"; then
    fail "deployment pins runAsUser"
else
    pass "deployment does not pin runAsUser"
fi

if grep -qE '^[[:space:]]+fsGroup:[[:space:]]*0' "${deploy}"; then
    fail "deployment sets fsGroup: 0"
else
    pass "deployment does not set fsGroup: 0"
fi

if grep -RIn --include='*.yaml' '8443' "${examples_dir}"; then
    fail "OpenShift examples mention 8443"
else
    pass "OpenShift examples have no 8443"
fi

if grep -q 'containerPort: 8080' "${deploy}"; then
    pass "deployment containerPort 8080"
else
    fail "deployment missing containerPort 8080"
fi

if grep -q 'image: ubi10-apache-php:1.0.0' "${deploy}"; then
    pass "deployment image is ubi10-apache-php:1.0.0 (not :latest)"
else
    fail "deployment image must be ubi10-apache-php:1.0.0, not :latest"
fi

if grep -q 'automountServiceAccountToken: false' "${deploy}"; then
    pass "automountServiceAccountToken: false"
else
    fail "deployment missing automountServiceAccountToken: false"
fi

if grep -q 'optional: true' "${deploy}"; then
    pass "ConfigMap volume is optional: true"
else
    fail "ConfigMap volume must be optional: true"
fi

if grep -A6 'resources:' "${deploy}" | grep -q 'memory:'; then
    pass "deployment sets memory resources"
else
    fail "deployment missing memory resources"
fi

probe_exec="$(grep -c 'command: \["/opt/drupal/scripts/healthcheck.sh"\]' "${deploy}" || true)"
if [[ "${probe_exec}" -eq 3 ]]; then
    pass "startup/liveness/readiness exec healthcheck.sh"
else
    fail "expected 3 exec healthcheck probes, got ${probe_exec}"
fi

if grep -q 'timeoutSeconds: 5' "${deploy}"; then
    pass "probe timeoutSeconds: 5"
else
    fail "probe timeoutSeconds: 5 missing"
fi

for f in networkpolicy.yaml pdb.yaml; do
    if [[ -f "${examples_dir}/${f}" ]]; then
        pass "${f} present"
    else
        fail "${f} missing"
    fi
done

if [[ -f "${examples_dir}/overlays/with-pvc/kustomization.yaml" ]] \
    && [[ -f "${examples_dir}/overlays/with-pvc/pvc.yaml" ]]; then
    pass "with-pvc overlay present"
else
    fail "overlays/with-pvc missing kustomization.yaml or pvc.yaml"
fi

if grep -q 'max_input_vars = 10000' "${cm}"; then
    pass "configmap zz-openshift.ini sets max_input_vars = 10000"
else
    fail "configmap should set a real override (max_input_vars = 10000)"
fi

if grep -qE 'useradd -l -u' "${ROOT}/Containerfile"; then
    pass "Containerfile useradd -l"
else
    fail "Containerfile useradd must use -l (DL3046)"
fi

if grep -q 'org.opencontainers.image.revision' "${ROOT}/Containerfile"; then
    pass "Containerfile sets org.opencontainers.image.revision"
else
    fail "Containerfile missing org.opencontainers.image.revision"
fi

if grep -qE '^push:' "${ROOT}/Makefile" && grep -qE '^login:' "${ROOT}/Makefile"; then
    pass "Makefile has login and push targets"
else
    fail "Makefile missing login/push"
fi

if grep -qE '^REGISTRY[[:space:]]+\?=[[:space:]]*docker.io' "${ROOT}/Makefile"; then
    pass "Makefile REGISTRY defaults to docker.io"
else
    fail "Makefile REGISTRY should default to docker.io"
fi

if grep -qE 'dckr_pat_|DOCKERHUB_TOKEN[[:space:]]*:=' "${ROOT}/Makefile"; then
    fail "Makefile must not hard-code a Docker Hub token"
else
    pass "Makefile does not hard-code DOCKERHUB_TOKEN"
fi

push_dry="$(make -C "${ROOT}" --no-print-directory push REGISTRY_USER=ci-dry-run PUSH_DRY_RUN=1)"
if printf '%s\n' "${push_dry}" | grep -q 'docker.io/ci-dry-run/ubi10-apache-php' \
    && printf '%s\n' "${push_dry}" | grep -q '1.0.0' \
    && printf '%s\n' "${push_dry}" | grep -q 'PUSH_DRY_RUN=1'; then
    pass "make push PUSH_DRY_RUN prints docker.io/USER/ubi10-apache-php:1.0.0"
    log "    ${push_dry}" | sed 's/^/    /'
else
    fail "make push dry-run output: ${push_dry}"
fi

if grep -qE '^LimitRequestBody 134217728$' "${httpd}"; then
    pass "httpd.conf LimitRequestBody 134217728"
else
    fail "httpd.conf LimitRequestBody must be 134217728"
fi

if grep -q -- '--max-time 5' "${hc}"; then
    pass "healthcheck.sh --max-time 5"
else
    fail "healthcheck.sh must use --max-time 5"
fi

if grep -q 'printf' "${hc}" && grep -q 'pong' "${hc}"; then
    pass "healthcheck.sh prints pong on success"
else
    fail "healthcheck.sh must print pong on success"
fi

log "=== manifests ${PASS} passed, ${FAIL} failed ==="
if [[ "${FAIL}" -ne 0 ]]; then
    exit 1
fi
exit 0
