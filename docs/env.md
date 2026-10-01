# Environment variables

Do not invent additional variables in the image. Downstream may set these at
runtime; defaults match the Containerfile / entrypoint / healthcheck.

| Name | Default | Where | Notes |
|---|---|---|---|
| `PHP_VERSION` | `8.4` | image ENV | Informational |
| `HTTPD_VERSION` | `2.4` | image ENV | Informational |
| `HOME` | `/var/www/html` | image ENV | `WORKDIR`; nss_wrapper home |
| `PATH` | `/var/www/html/vendor/bin:${PATH}` | image ENV | Dir may be absent in the base |
| `COMPOSER_HOME` | `/opt/drupal/.composer` | image ENV | Owned `1001:0`, `g=u` |
| `PHP_INI_SCAN_DIR` | `/etc/php.d:/etc/drupal/php.d` | image ENV | **FPM** scan path. CLI overlay is not in this default |
| `PHP_FPM_CONF` | `/opt/httpd/conf/php-fpm.conf` | image ENV | Entrypoint `-y` |
| `HTTPD_CONF` | `/opt/httpd/conf/httpd.conf` | image ENV | Entrypoint `-f` |
| `DEBUG` | unset | entrypoint | `1` or `true` → `set -x` |
| `PHP_FPM_SOCK` | `/run/php-fpm/drupal.sock` | entrypoint | Must match `www.conf` `listen` |
| `SOCKET_WAIT_SECONDS` | `30` | entrypoint | Wait for the FPM socket before `exec httpd` |
| `NSS_WRAPPER_DIR` | `/tmp/nss_wrapper` | entrypoint | Used only when the runtime UID is missing from `/etc/passwd` (not `id -un`; GNU `id -un` prints the number and exits 0) |
| `HEALTHCHECK_URL` | `http://127.0.0.1:8080/healthz` | healthcheck.sh | Body must be exactly `pong`. On success the script prints `pong`. `curl --max-time 5` |

`COMPOSER_ALLOW_SUPERUSER` is **not** set and must not be added.

## PHP_INI_SCAN_DIR: FPM vs CLI

- **`CMD start` (FPM + httpd):** `PHP_INI_SCAN_DIR=/etc/php.d:/etc/drupal/php.d`.
  FPM `memory_limit=256M` from `10-drupal.ini`. `/etc/drupal/php-cli.d` is not
  scanned.
- **Any other command** (e.g. `composer`, `php`, `drush` via the entrypoint):
  the entrypoint **appends** `:/etc/drupal/php-cli.d` so CLI gets
  `memory_limit=-1`.

`podman exec` into a running `start` container does **not** go through that
append: `php` there still sees the FPM scan dir (256M). Use
`podman run … composer` / `php` for CLI unlimited memory.

## Ports

Apache `Listen 8080` only. `EXPOSE 8080`. There is no 8443, no `mod_ssl`, no
HTTP/2, no HSTS in the pod. TLS belongs on the OpenShift Route.
