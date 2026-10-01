# Architecture

## Layers

- **OS:** `docker.io/redhat/ubi10-minimal`, digest-pinned in the Containerfile.
- **Apache 2.4** `mpm_event` with a dedicated ServerRoot `/opt/httpd` (not stock
  `/etc/httpd` drop-ins). `Listen 8080` only. No `<VirtualHost>`: one listener,
  one site. `ServerName localhost` only silences the FQDN warning; the OpenShift
  Route is the hostname.
- **PHP 8.4 + php-fpm** from Remi `php:remi-8.4` (EPEL is a Remi prerequisite;
  release RPMs are sha256-pinned). `install_weak_deps=0`. Individual `php-*`
  NVRs are **not** pinned; a rebuild can pick up a newer 8.4.x. `make versions`
  dumps `php -v`, `httpd -v`, `composer --version`, and `rpm -qa`.
- **Handler:** `mod_proxy_fcgi` → `unix:/run/php-fpm/drupal.sock`. Not mod_php.
  Existence-guarded `SetHandler` (`<If "-f %{REQUEST_FILENAME}">`) plus FPM
  `security.limit_extensions` and `cgi.fix_pathinfo=0`.
- **Composer 2.10** binary, digest-pinned. `COMPOSER_HOME=/opt/drupal/.composer`.
- **App layout:** `HOME`/`WORKDIR` `/var/www/html`, DocumentRoot
  `/var/www/html/web`. Placeholder `web/index.php` and stock Drupal
  `web/.htaccess` exist so `GET /` is not a 500; `composer create-project` /
  scaffold overwrites them.

## Process model (PID 1)

`ENTRYPOINT` `/opt/drupal/scripts/entrypoint.sh`, `CMD start`:

1. Create runtime dirs (`/run/httpd`, `/run/php-fpm`, `/tmp/php-sessions`).
2. `nss_wrapper` if the runtime UID is **not** in `/etc/passwd` (CRI-O/Podman
   often inject a line; GNU `id -un` is not used — it prints the number and
   exits 0 when the account is missing). Extra passwd line is named `default`,
   not `drupal` (`/etc/passwd` already has `drupal:1001`).
3. `php-fpm -t` and `httpd -t`.
4. `php-fpm -D` (daemonize). Wait for the unix socket (default 30s).
5. `exec httpd -D FOREGROUND` — **httpd is PID 1**.

There is **no** tini or supervisord. `STOPSIGNAL SIGWINCH` is Apache’s graceful
stop. PHP-FPM is not PID 1, is not reaped by Apache, and does not receive
SIGTERM when the pod stops. See [security.md](security.md).

Any command other than `start` is `exec`’d after appending
`/etc/drupal/php-cli.d` to `PHP_INI_SCAN_DIR` (CLI `memory_limit=-1`). That
overlay is **never** applied on the `start` path, so FPM workers keep
`memory_limit=256M`.

## Baked config (no templating)

| Path | Role |
|---|---|
| `/opt/httpd/conf/httpd.conf` | ServerRoot, Listen 8080, DocumentRoot, directories |
| `/opt/httpd/conf.modules.d/` | `LoadModule` only |
| `/opt/httpd/conf.d/` | Site fragments (PHP-FPM, RemoteIP, healthz, files) |
| `/opt/httpd/conf/php-fpm.conf` + `php-fpm.d/www.conf` | FPM pool, unix socket, ping.path |
| `/etc/drupal/php.d/` | FPM+CLI Drupal ini (after Remi `/etc/php.d`) |
| `/etc/drupal/php-cli.d/` | CLI-only; entrypoint non-`start` path |

Downstream overrides: drop in `/etc/drupal/php.d/zz-*.ini` and
`/opt/httpd/conf.d/*.conf`. Do not add runtime gomplate/gotpl/`tpl.sh`.

## PHP extensions and tools

Build fails if any of these are missing: `curl`, `gd` (JPEG/PNG/WebP; AVIF is
not a hard fail), `mbstring`, `xml`, `zip` (`php-pecl-zip`), `pdo_mysql`,
`pdo_pgsql`, `openssl`, `zlib`, `fileinfo`, `json`, `opcache`, `apcu`,
`igbinary`, `sodium`, and `PASSWORD_ARGON2ID` (PHP compile flag; no argon2 RPM).

Also on PATH: `git`, `patch`, `mysql`, `mysqldump`, `psql`, `pg_dump` (client
RPMs `mariadb` and `postgresql`, not `*-server`). ImageMagick, jpegoptim,
gcc/g++/make/re2c, wget, and `mod_ssl` are not installed.

GD is the image toolkit. ImageMagick stays out of the base.

## Image labels and platform

`make build` sets `org.opencontainers.image.version` (`IMAGE_VERSION`, default
`1.0.0`), `created` (`BUILD_DATE`), `revision` (`git rev-parse HEAD`), and
`source` (`remote.origin.url` when configured). These override the UBI base
revision label so the image refers to **this** git tree.

Default `PLATFORM` is `linux/amd64`. This repo does not publish multi-arch
manifests. On aarch64, use qemu (`podman build --platform=linux/amd64`) or a
native rebuild after changing `PLATFORM`.
