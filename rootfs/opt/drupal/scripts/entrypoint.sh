#!/usr/bin/env bash
set -euo pipefail
[[ "${DEBUG:-}" == "1" || "${DEBUG:-}" == "true" ]] && set -x

readonly CLI_PHP_INI_DIR="/etc/drupal/php-cli.d"
readonly FPM_SOCK="${PHP_FPM_SOCK:-/run/php-fpm/drupal.sock}"
readonly SOCKET_WAIT_SECONDS="${SOCKET_WAIT_SECONDS:-30}"
export HTTPD_CONF="${HTTPD_CONF:-/opt/httpd/conf/httpd.conf}"
export PHP_FPM_CONF="${PHP_FPM_CONF:-/opt/httpd/conf/php-fpm.conf}"
export HOME="${HOME:-/var/www/html}"

log() { printf '[ INFO ] [ entrypoint ]: %s\n' "$*" >&2; }
die() { printf '[ ERROR ] [ entrypoint ]: %s\n' "$*" >&2; exit 1; }

# OpenShift /run and /tmp are often empty tmpfs. Build-time mkdir does not survive.
ensure_runtime_dirs() {
    local d
    for d in /run/httpd /run/php-fpm /tmp/php-sessions; do
        mkdir -p "${d}"
        chmod g=u "${d}" 2>/dev/null || true
    done
}

# Restricted SCC: random UID, gid 0. Never chmod g=u /etc/passwd (RHSA).
# CRI-O 4.2+ may already inject the UID into /etc/passwd — then skip.
# GNU coreutils `id -un` prints the number and exits 0 when the account is
# missing, so it is not a valid "already in passwd" check.
# Otherwise nss_wrapper (writable /tmp, works with a read-only root).
# Name the extra line "default", not "drupal": /etc/passwd already has drupal:1001
# and getpwnam("drupal") would keep returning 1001.
setup_arbitrary_uid() {
    local uid gid wrap passwd group lib
    uid="$(id -u)"
    gid="$(id -g)"
    if grep -qE "^[^:]+:[^:]*:${uid}:" /etc/passwd; then
        return 0
    fi

    wrap="${NSS_WRAPPER_DIR:-/tmp/nss_wrapper}"
    mkdir -p "${wrap}"
    chmod 0700 "${wrap}"
    passwd="${wrap}/passwd"
    group="${wrap}/group"
    cp /etc/passwd "${passwd}"
    cp /etc/group "${group}"
    printf 'default:x:%s:%s:Drupal:%s:/sbin/nologin\n' \
        "${uid}" "${gid}" "${HOME}" >> "${passwd}"

    lib=""
    for lib in /usr/lib64/libnss_wrapper.so /usr/lib/libnss_wrapper.so; do
        if [[ -r "${lib}" ]]; then
            break
        fi
        lib=""
    done
    [[ -n "${lib}" ]] || die "uid ${uid} is not in passwd and nss_wrapper is missing"

    export NSS_WRAPPER_PASSWD="${passwd}"
    export NSS_WRAPPER_GROUP="${group}"
    export LD_PRELOAD="${lib}${LD_PRELOAD:+:${LD_PRELOAD}}"
    log "nss_wrapper: uid ${uid} gid ${gid} as default"
}

wait_for_socket() {
    local n=0
    while [[ "${n}" -lt "${SOCKET_WAIT_SECONDS}" ]]; do
        if [[ -S "${FPM_SOCK}" ]]; then
            return 0
        fi
        sleep 1
        n=$((n + 1))
    done
    die "PHP-FPM socket not ready after ${SOCKET_WAIT_SECONDS}s: ${FPM_SOCK}"
}

main() {
    ensure_runtime_dirs
    setup_arbitrary_uid

    if [[ "${1:-}" != "start" ]]; then
        export PHP_INI_SCAN_DIR="${PHP_INI_SCAN_DIR:-/etc/php.d:/etc/drupal/php.d}:${CLI_PHP_INI_DIR}"
        log "Exec (non-start): $*"
        exec "$@"
    fi

    log "Validating PHP-FPM syntax..."
    php-fpm -t -y "${PHP_FPM_CONF}" || die "${PHP_FPM_CONF} syntax invalid."

    log "Validating Apache syntax..."
    httpd -t -d /opt/httpd -f "${HTTPD_CONF}" || die "${HTTPD_CONF} syntax invalid."

    log "Starting PHP-FPM (background)"
    php-fpm -D -y "${PHP_FPM_CONF}" || die "PHP-FPM failed to start."
    wait_for_socket

    log "Exec httpd -D FOREGROUND (PID 1)"
    exec httpd -D FOREGROUND -d /opt/httpd -f "${HTTPD_CONF}"
}

main "$@"
