# Security notes

## restricted-v2

- `USER 1001`, primary gid **0**. OpenShift assigns an arbitrary UID; the
  process still has gid 0. File ownership is `1001:0` with `chmod g=u`
  (0775/0664). **Never** `chmod 777`. **Never** `chmod g=u /etc/passwd` (RHSA).
  The image applies `g=u` **before** `chown 1001:0` so rootless Podman/Docker
  builds (typical on Ubuntu) do not fail with `chmod: Operation not permitted`.
- If the runtime UID is missing from `/etc/passwd`, `nss_wrapper` synthesizes a
  `default` passwd line (not `drupal` — that name is already uid 1001). CRI-O
  and Podman often inject the UID themselves; then nss_wrapper is skipped.
- Example manifests must **not** pin `runAsUser` and must **not** set
  `fsGroup: 0`.
- Port 8080 only (unprivileged). No `NET_BIND_SERVICE`.
- Example pod sets `automountServiceAccountToken: false`.

## Read-only rootfs (supported in v1)

The image starts with a read-only root filesystem if these are writable
(tmpfs or emptyDir):

| Mount | Why |
|---|---|
| `/tmp` | PHP temp, sessions (`/tmp/php-sessions`), nss_wrapper |
| `/run/httpd` | pid, mutex, scoreboard |
| `/run/php-fpm` | pid + `drupal.sock` |

A Drupal site also needs writable public/private files (see
[openshift.md](openshift.md)). `make test` runs `--read-only` with tmpfs on
`/tmp`, `/run/httpd`, and `/run/php-fpm`.

## PHP handler

- Unix socket, `listen.mode=0660`, **no** `listen.owner`/`listen.group` (FPM is
  not root and cannot chown; Apache is the same UID).
- `SetHandler` only when the request maps to a real file. FPM
  `security.limit_extensions = .php .phar`. `cgi.fix_pathinfo=0`.
- `settings.php` / `services.yml` are `Require all denied` in the docroot
  Directory (the FPM `-f` guard would otherwise execute a real `settings.php`).

## Public files (SA-2006-006 / SA-2013-003)

`<DirectoryMatch "^/var/www/html/web/sites/[^/]+/files(/|$)">` — matches
`files/` and `files/field/…`, not `filesfoo`. `AllowOverride None`, dummy
SetHandlers, and `Require all denied` for `.php` / `.phar` / `.phtml` /
`.phps` / `.php[0-9]+`. Parent `/var/www/html` and `/` stay denied.
`AllowOverride All` is only on `/var/www/html/web`.

## `/healthz`

Apache proxies `GET/HEAD /healthz` to FPM `ping.path`; body is `pong` (not a
Drupal page, not a 204). Authz: `Require local` plus RFC1918/ULA. After
`mod_remoteip`, a public Route client is **not** those CIDRs and must not get
`pong`. A server-config `RewriteRule ^/healthz$ - [END]` stops Drupal’s
`.htaccess` front controller from swallowing the path.

**Probes:** exec `/opt/drupal/scripts/healthcheck.sh` (always). Docker
`HEALTHCHECK` uses the same script against `127.0.0.1:8080`. httpGet from the
kubelet can work on node/cluster IPs; it is **not** reliable through a public
Route. `/healthz` is `dontlog`.

Do not expose FPM `pm.status_path`. `/server-status` is `Require local`.

## Edge TLS

No `mod_ssl`, no HTTP/2, no HSTS on the pod. `X-Forwarded-Proto: https` sets
env `HTTPS=on`. HSTS belongs on the Route. Do not set `session.cookie_secure=1`
in the image (breaks HTTP `make run`).

HTTPoxy: `RequestHeader unset Proxy early`.

## PID 1 caveat

httpd is PID 1. PHP-FPM is a daemon started with `-D`. On `SIGWINCH`/pod stop,
Apache exits; FPM may be left behind until the container runtime kills the
cgroup. FPM zombies are not reaped by httpd. v1 does not ship tini or
supervisord.

## Secrets and `clear_env = no`

FPM workers inherit the container environment. Do not pass build-time secrets
(tokens, Composer auth) as runtime env on the `start` path.

## Supply chain

UBI digest, EPEL/Remi RPM sha256, Composer digest are pinned.
`install_weak_deps=0`. SUID/SGID bits are stripped at build (`find -perm /6000`).
`make scan` runs Trivy `--ignore-unfixed` for HIGH/CRITICAL when `trivy` is
installed; it is evidence, not a substitute for `make test`. It saves the
image with the same `CONTAINER_ENGINE` as `make build` and scans the tarball
(no Docker/Podman API socket). Cache defaults to `~/.local/share/trivy`
because `~/.cache/trivy` is often root-owned after a `sudo trivy` run. Override
with `TRIVY_CACHE_DIR`.
