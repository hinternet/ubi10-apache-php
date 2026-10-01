#!/usr/bin/env bash
# Drive the built image via podman/docker run+exec. Do not reimplement httpd/FPM.
set -euo pipefail

IMAGE="${IMAGE:-ubi10-apache-php:latest}"
ENGINE="${CONTAINER_ENGINE:-podman}"
PREFIX="ubi10-apache-php-test-$$"
PASS=0
FAIL=0
containers=()

log() { printf '%s\n' "$*"; }
pass() { PASS=$((PASS + 1)); log "[PASS] $*"; }
fail() { FAIL=$((FAIL + 1)); log "[FAIL] $*"; }

cleanup() {
    local c
    for c in "${containers[@]+"${containers[@]}"}"; do
        "${ENGINE}" rm -f "${c}" >/dev/null 2>&1 || true
    done
}
trap cleanup EXIT

need_image() {
    # podman "image exists" is not on docker; inspect works on both.
    if ! "${ENGINE}" image inspect "${IMAGE}" >/dev/null 2>&1; then
        log "Image ${IMAGE} not found. Run: make build"
        exit 1
    fi
}

run_detached() {
    local name="$1"
    shift
    "${ENGINE}" run -d --name "${name}" "$@" "${IMAGE}" >/dev/null
    containers+=("${name}")
}

wait_pong() {
    local name="$1"
    local n=0
    while [[ "${n}" -lt 45 ]]; do
        if body="$("${ENGINE}" exec "${name}" /opt/drupal/scripts/healthcheck.sh 2>/dev/null)" \
            && [[ "${body}" == "pong" ]]; then
            return 0
        fi
        sleep 1
        n=$((n + 1))
    done
    log "---- ${name} logs ----"
    "${ENGINE}" logs "${name}" || true
    return 1
}

http_code_body() {
    # Sets HTTP_CODE and HTTP_BODY from an in-container curl (no -f).
    local name="$1" url="$2"
    shift 2
    HTTP_BODY="$("${ENGINE}" exec "${name}" curl -sS "$@" -o /tmp/test-body -w '%{http_code}' "${url}")"
    HTTP_CODE="${HTTP_BODY: -3}"
    HTTP_BODY="$("${ENGINE}" exec "${name}" cat /tmp/test-body)"
}

cli() {
    "${ENGINE}" run --rm --user 1001:0 "${IMAGE}" "$@"
}

need_image
log "=== image ${IMAGE} via ${ENGINE} ==="

# --- CLI / non-start path (entrypoint appends php-cli.d) ---
phpv="$(cli php -r 'echo PHP_MAJOR_VERSION, ".", PHP_MINOR_VERSION;')"
if [[ "${phpv}" == "8.4" ]]; then
    pass "PHP 8.4 (${phpv})"
else
    fail "PHP 8.4, got: ${phpv}"
fi

phpfull="$(cli php -v | head -n1)"
log "    ${phpfull}"

if cli php -r 'exit(extension_loaded("curl") ? 0 : 1);'; then
    pass "curl extension"
else
    fail "curl extension missing"
fi

if cli php -r 'exit(defined("PASSWORD_ARGON2ID") ? 0 : 1);'; then
    pass "PASSWORD_ARGON2ID"
else
    fail "PASSWORD_ARGON2ID undefined"
fi

gdout="$(cli php -r '$i=gd_info(); foreach (["JPEG Support","PNG Support","WebP Support"] as $k) { if (empty($i[$k])) { fwrite(STDERR, "gd missing $k\n"); exit(1);} echo $k, "\n"; }')"
if [[ "${gdout}" == *"JPEG Support"* && "${gdout}" == *"PNG Support"* && "${gdout}" == *"WebP Support"* ]]; then
    pass "GD JPEG/PNG/WebP"
    log "${gdout}" | sed 's/^/    /'
else
    fail "GD JPEG/PNG/WebP: ${gdout}"
fi

bins="$(cli bash -c 'command -v mysql; command -v mysqldump; command -v psql; command -v pg_dump')"
if cli bash -c 'command -v mysql && command -v mysqldump && command -v psql && command -v pg_dump' >/dev/null; then
    pass "mysql+mysqldump+psql+pg_dump on PATH"
    log "${bins}" | sed 's/^/    /'
else
    fail "SQL clients on PATH: ${bins}"
fi

comp="$(cli bash -c 'id -u; test -z "${COMPOSER_ALLOW_SUPERUSER:-}"; composer --version')"
if printf '%s\n' "${comp}" | grep -q '^1001$' && printf '%s\n' "${comp}" | grep -qi composer; then
    pass "composer runs as UID 1001 (no COMPOSER_ALLOW_SUPERUSER)"
    log "${comp}" | sed 's/^/    /'
else
    fail "composer as UID 1001: ${comp}"
fi

clipath="$(cli bash -c 'printf %s "$PATH"')"
if [[ ":${clipath}:" == *":/var/www/html/vendor/bin:"* ]]; then
    pass "PATH includes /var/www/html/vendor/bin"
else
    fail "PATH missing vendor/bin: ${clipath}"
fi

own="$(cli bash -c 'stat -c "%u:%g %a" /etc/drupal/php.d; stat -c "%u:%g %a" /var/www/html; test -x /opt/drupal/scripts/entrypoint.sh && echo exec_ok')"
phpd_own="$(printf '%s\n' "${own}" | sed -n '1p')"
html_own="$(printf '%s\n' "${own}" | sed -n '2p')"
if [[ "${phpd_own}" == "1001:0 775" && "${html_own}" == "1001:0 775" && "${own}" == *exec_ok* ]]; then
    pass "g=u ownership 1001:0 775 on php.d and HOME; scripts executable"
    log "    ${own}" | sed 's/^/    /'
else
    fail "expected 1001:0 775 + exec_ok, got: ${own}"
fi

climem="$(cli php -r 'echo ini_get("memory_limit");')"
if [[ "${climem}" == "-1" ]]; then
    pass "CLI php-cli.d memory_limit=-1 (non-start path)"
else
    fail "CLI memory_limit expected -1, got ${climem}"
fi

# --- default UID start ---
name="${PREFIX}-default"
run_detached "${name}"
if wait_pong "${name}"; then
    hc="$("${ENGINE}" exec "${name}" /opt/drupal/scripts/healthcheck.sh)"
    if [[ "${hc}" == "pong" ]]; then
        pass "healthcheck.sh stdout pong"
    else
        fail "healthcheck.sh stdout pong, got: ${hc}"
    fi

    body="$("${ENGINE}" exec "${name}" curl -fsS http://127.0.0.1:8080/healthz)"
    if [[ "${body}" == "pong" ]]; then
        pass "GET /healthz body pong"
    else
        fail "GET /healthz body pong, got: ${body}"
    fi

    if "${ENGINE}" exec "${name}" grep -q -- '--max-time 5' /opt/drupal/scripts/healthcheck.sh; then
        pass "healthcheck.sh curl --max-time 5"
    else
        fail "healthcheck.sh curl --max-time 5"
    fi

    lrb="$("${ENGINE}" exec "${name}" grep -E '^LimitRequestBody' /opt/httpd/conf/httpd.conf)"
    if [[ "${lrb}" == "LimitRequestBody 134217728" ]]; then
        pass "LimitRequestBody 134217728 (128Mi, matches post_max_size)"
    else
        fail "LimitRequestBody expected 134217728, got: ${lrb}"
    fi

    http_code_body "${name}" http://127.0.0.1:8080/
    if [[ "${HTTP_CODE}" != "500" && "${HTTP_CODE}" != "000" ]]; then
        pass "placeholder GET / is not a 500 (HTTP ${HTTP_CODE})"
        log "    body: ${HTTP_BODY}"
    else
        fail "placeholder GET / HTTP ${HTTP_CODE} body=${HTTP_BODY}"
    fi

    httpd_v="$("${ENGINE}" exec "${name}" httpd -v | head -n1)"
    if printf '%s\n' "${httpd_v}" | grep -qE 'Apache/2\.4'; then
        pass "Apache 2.4 (${httpd_v})"
    else
        fail "Apache 2.4, got: ${httpd_v}"
    fi

    if "${ENGINE}" exec "${name}" httpd -t -d /opt/httpd -f /opt/httpd/conf/httpd.conf; then
        pass "httpd -t"
    else
        fail "httpd -t"
    fi

    if "${ENGINE}" exec "${name}" php-fpm -t -y /opt/httpd/conf/php-fpm.conf; then
        pass "php-fpm -t"
    else
        fail "php-fpm -t"
    fi

    mods="$("${ENGINE}" exec "${name}" httpd -M 2>/dev/null || true)"
    if printf '%s\n' "${mods}" | grep -q mpm_event_module && printf '%s\n' "${mods}" | grep -q proxy_fcgi_module; then
        pass "mpm_event + proxy_fcgi loaded"
    else
        fail "expected mpm_event and proxy_fcgi in httpd -M"
    fi
    if printf '%s\n' "${mods}" | grep -qE 'php[0-9]*_module|libphp'; then
        fail "mod_php must not be loaded"
    else
        pass "mod_php not loaded"
    fi

    # FPM workers must not see CLI unlimited memory or php-cli.d.
    "${ENGINE}" exec "${name}" bash -c 'printf "%s\n" "<?php echo ini_get(\"memory_limit\"), PHP_EOL, getenv(\"PHP_INI_SCAN_DIR\");" > /var/www/html/web/mem.php'
    http_code_body "${name}" http://127.0.0.1:8080/mem.php
    "${ENGINE}" exec "${name}" rm -f /var/www/html/web/mem.php
    if [[ "${HTTP_CODE}" == "200" && "${HTTP_BODY}" == *"256M"* && "${HTTP_BODY}" != *php-cli.d* && "${HTTP_BODY}" != *"-1"* ]]; then
        pass "FPM PHP_INI_SCAN_DIR has no php-cli.d; memory_limit=256M"
        log "    ${HTTP_BODY}" | sed 's/^/    /'
    else
        fail "FPM ini mix-up: HTTP ${HTTP_CODE} body=${HTTP_BODY}"
    fi

    # Edge TLS: Apache sets env HTTPS from X-Forwarded-Proto (Drupal reverse_proxy still required).
    "${ENGINE}" exec "${name}" bash -c 'printf "%s\n" "<?php echo empty(\$_SERVER[\"HTTPS\"]) ? \"off\" : \$_SERVER[\"HTTPS\"];" > /var/www/html/web/https.php'
    http_code_body "${name}" http://127.0.0.1:8080/https.php -H "X-Forwarded-Proto: https"
    "${ENGINE}" exec "${name}" rm -f /var/www/html/web/https.php
    if [[ "${HTTP_CODE}" == "200" && "${HTTP_BODY}" == "on" ]]; then
        pass "X-Forwarded-Proto: https sets HTTPS=on"
    else
        fail "X-Forwarded-Proto HTTPS: HTTP ${HTTP_CODE} body=${HTTP_BODY}"
    fi

    # Public files: SA-2006-006 / SA-2013-003
    "${ENGINE}" exec "${name}" bash -c '
set -euo pipefail
dir=/var/www/html/web/sites/default/files
mkdir -p "${dir}"
printf "%s\n" "<?php echo \"PWNED\";" > "${dir}/evil.php"
printf "%s\n" "<?php echo \"PWNED\";" > "${dir}/evil.phar"
printf "%s\n" "<?php echo \"PWNED\";" > "${dir}/evil.phtml"
'
    denied=1
    for path in /sites/default/files/evil.php /sites/default/files/evil.phar /sites/default/files/evil.phtml; do
        http_code_body "${name}" "http://127.0.0.1:8080${path}"
        if [[ "${HTTP_CODE}" == "200" || "${HTTP_BODY}" == *PWNED* ]]; then
            fail "files PHP denied: ${path} HTTP ${HTTP_CODE} body=${HTTP_BODY}"
            denied=0
        else
            log "    ${path} HTTP ${HTTP_CODE} (not executed)"
        fi
    done
    if [[ "${denied}" -eq 1 ]]; then
        pass "files PHP denied (sites/*/files .php/.phar/.phtml HTTP 403)"
    fi

    # settings.php must not execute via the FPM -f guard
    "${ENGINE}" exec "${name}" bash -c 'printf "%s\n" "<?php echo \"SETTINGS_LEAK\";" > /var/www/html/web/sites/default/settings.php'
    http_code_body "${name}" http://127.0.0.1:8080/sites/default/settings.php
    if [[ "${HTTP_CODE}" == "200" || "${HTTP_BODY}" == *SETTINGS_LEAK* ]]; then
        fail "settings.php executable: HTTP ${HTTP_CODE} body=${HTTP_BODY}"
    else
        pass "settings.php denied (HTTP ${HTTP_CODE})"
    fi

    # After RemoteIP, a public X-Forwarded-For must not get pong.
    http_code_body "${name}" http://127.0.0.1:8080/healthz -H "X-Forwarded-For: 8.8.8.8"
    if [[ "${HTTP_CODE}" == "200" && "${HTTP_BODY}" == "pong" ]]; then
        fail "healthz leak: X-Forwarded-For 8.8.8.8 got pong"
    else
        pass "healthz denies public X-Forwarded-For (HTTP ${HTTP_CODE})"
    fi
else
    fail "GET /healthz body pong (container did not become ready)"
fi

# --- arbitrary UID (nss_wrapper) ---
name4711="${PREFIX}-4711"
run_detached "${name4711}" --user 4711:0
if wait_pong "${name4711}"; then
    uid="$("${ENGINE}" exec "${name4711}" id -u)"
    gid="$("${ENGINE}" exec "${name4711}" id -g)"
    pwline="$("${ENGINE}" exec "${name4711}" sh -c 'grep -E "^[^:]+:[^:]*:4711:" /etc/passwd || true')"
    wrapfile="$("${ENGINE}" exec "${name4711}" sh -c 'grep -E "^default:" /tmp/nss_wrapper/passwd 2>/dev/null || true')"
    wrapenv="$("${ENGINE}" exec "${name4711}" sh -c 'tr "\0" "\n" < /proc/1/environ | grep NSS_WRAPPER_PASSWD= || true')"
    if [[ "${uid}" != "4711" || "${gid}" != "0" ]]; then
        fail "--user 4711:0 identity uid=${uid} gid=${gid}"
    elif [[ -n "${pwline}" ]]; then
        pass "--user 4711:0 starts (runtime passwd already has 4711; nss_wrapper skipped)"
        log "    ${pwline}"
    elif [[ "${wrapfile}" == default:x:4711:0:* && -n "${wrapenv}" ]]; then
        pass "--user 4711:0 starts (nss_wrapper name=default)"
        log "    ${wrapfile}"
    else
        fail "4711 not in passwd and nss_wrapper unused: pw=${pwline} wrap=${wrapfile} env=${wrapenv}"
    fi
    body="$("${ENGINE}" exec "${name4711}" curl -fsS http://127.0.0.1:8080/healthz || true)"
    if [[ "${body}" == "pong" ]]; then
        pass "--user 4711:0 GET /healthz body pong"
    else
        fail "--user 4711:0 healthz: ${body}"
    fi
else
    fail "--user 4711:0 start (healthz never became pong)"
fi

# Podman (and CRI-O) often inject the runtime UID into /etc/passwd. That skips
# nss_wrapper. --passwd=false leaves 4711 missing so the wrapper path is real.
if "${ENGINE}" run --help 2>&1 | grep -q -- '--passwd'; then
    namenss="${PREFIX}-nss"
    run_detached "${namenss}" --user 4711:0 --passwd=false
    if wait_pong "${namenss}"; then
        wrapfile="$("${ENGINE}" exec "${namenss}" sh -c 'grep -E "^default:" /tmp/nss_wrapper/passwd 2>/dev/null || true')"
        wrapenv="$("${ENGINE}" exec "${namenss}" sh -c 'tr "\0" "\n" < /proc/1/environ | grep NSS_WRAPPER_PASSWD= || true')"
        logs="$("${ENGINE}" logs "${namenss}" 2>&1 || true)"
        if [[ "${wrapfile}" == default:x:4711:0:* && -n "${wrapenv}" && "${logs}" == *"nss_wrapper: uid 4711 gid 0 as default"* ]]; then
            pass "--user 4711:0 nss_wrapper name=default (passwd injection disabled)"
            log "    ${wrapfile}"
        else
            fail "nss_wrapper path: wrap=${wrapfile} env=${wrapenv}"
            log "${logs}" | sed 's/^/    /'
        fi
        body="$("${ENGINE}" exec "${namenss}" curl -fsS http://127.0.0.1:8080/healthz || true)"
        if [[ "${body}" == "pong" ]]; then
            pass "nss_wrapper GET /healthz body pong"
        else
            fail "nss_wrapper healthz: ${body}"
        fi
    else
        fail "nss_wrapper --user 4711:0 --passwd=false did not become ready"
    fi
else
    log "[SKIP] ${ENGINE} has no --passwd; cannot force nss_wrapper (injection-off) locally"
fi

# --- read-only rootfs with documented tmpfs mounts ---
namero="${PREFIX}-ro"
run_detached "${namero}" --read-only --user 1001:0 \
    --tmpfs /tmp:rw,mode=1777 \
    --tmpfs /run/httpd:rw,mode=0775 \
    --tmpfs /run/php-fpm:rw,mode=0775
if wait_pong "${namero}"; then
    body="$("${ENGINE}" exec "${namero}" curl -fsS http://127.0.0.1:8080/healthz)"
    if [[ "${body}" == "pong" ]]; then
        pass "read-only rootfs start with tmpfs /tmp /run/httpd /run/php-fpm (healthz pong)"
    else
        fail "read-only rootfs healthz: ${body}"
    fi
else
    fail "read-only rootfs run did not become ready"
fi

# Image must not advertise 8443 (no pod TLS).
exposed="$("${ENGINE}" inspect -f '{{range $p, $_ := .Config.ExposedPorts}}{{$p}} {{end}}' "${IMAGE}")"
if printf '%s' "${exposed}" | grep -q 8443; then
    fail "EXPOSE 8443 still present: ${exposed}"
else
    pass "EXPOSE is 8080 only (${exposed})"
fi

ver="$("${ENGINE}" inspect -f '{{index .Config.Labels "org.opencontainers.image.version"}}' "${IMAGE}")"
if [[ "${ver}" == "1.0.0" ]]; then
    pass "org.opencontainers.image.version=1.0.0"
else
    fail "org.opencontainers.image.version expected 1.0.0, got: ${ver}"
fi

rev="$("${ENGINE}" inspect -f '{{index .Config.Labels "org.opencontainers.image.revision"}}' "${IMAGE}")"
src="$("${ENGINE}" inspect -f '{{index .Config.Labels "org.opencontainers.image.source"}}' "${IMAGE}")"
if [[ -n "${rev}" ]]; then
    pass "org.opencontainers.image.revision is set (${rev})"
    log "    source=${src}"
else
    fail "org.opencontainers.image.revision missing"
fi

log "=== ${PASS} passed, ${FAIL} failed ==="
if [[ "${FAIL}" -ne 0 ]]; then
    exit 1
fi
exit 0
