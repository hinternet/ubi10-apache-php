# ubi10-apache-php

OpenShift-first **Drupal 11 runtime base image**. There is no Drupal application
in the image: downstream projects `FROM` it, copy their Composer tree, and
deploy under SCC `restricted-v2`.

| Layer | Choice |
|---|---|
| OS | `docker.io/redhat/ubi10-minimal` (digest-pinned) |
| HTTP | Apache 2.4 `mpm_event`, config under `/opt/httpd` |
| PHP | 8.4 FPM from Remi `php:remi-8.4` |
| Transport | `mod_proxy_fcgi` → `unix:/run/php-fpm/drupal.sock` |
| Composer | official `composer:2.10` binary (digest-pinned) |
| App | `HOME`/`WORKDIR` `/var/www/html`, `DocumentRoot` `/var/www/html/web` |
| User | `USER 1001`, gid 0; `nss_wrapper` if the OpenShift UID is missing from passwd |
| Listen | **8080 only** (edge TLS on the Route; no `mod_ssl` in the pod) |

Config is baked in `rootfs/` at build time. There is no gomplate, gotpl, or
`tpl.sh`.

Local tag: `ubi10-apache-php:latest` (`linux/amd64`, Podman via `CONTAINER_ENGINE`;
`CONTAINER_ENGINE=docker` is supported). OpenShift examples use `:1.0.0`.

## Quick start

```bash
make lint           # hadolint + shellcheck (skipped if a tool is absent)
make build          # ubi10-apache-php:latest
make test           # manifests + podman/docker run/exec against the image
make run            # httpd+FPM on localhost:8080
make health         # exec /opt/drupal/scripts/healthcheck.sh; prints pong
make stop
```

Optional: `make scan` (Trivy HIGH/CRITICAL, `--ignore-unfixed`; uses
`CONTAINER_ENGINE save` so Docker/Podman sockets are not required; cache
defaults to `~/.local/share/trivy`), `make versions` (php/httpd/composer +
`rpm -qa`). Use the same `CONTAINER_ENGINE` as `make build`.

## Publish to Docker Hub (`docker.io`)

Name: `docker.io/<your-hub-username>/ubi10-apache-php`  
(not `library/ubi10-apache-php` — that namespace is for official images.)

| Tag | What it is | Use |
|---|---|---|
| `1.0.0` (`IMAGE_VERSION`) | This release | **Pin this** in OpenShift / `FROM` |
| `1.0` | Latest `1.0.x` | Optional floating minor |
| `latest` | Moving pointer | Local convenience only |

Bump `IMAGE_VERSION` in the Makefile for each publish: patch (`1.0.1`) for
fixes, minor (`1.1.0`) for compatible additions, major (`2.0.0`) for breaks
(PHP major, process model).

Create a [Docker Hub](https://hub.docker.com) access token (Account Settings →
Personal access tokens) with Read & Write. Username is the Hub **username**,
not your email. Do not put the token in git.

```bash
export DOCKERHUB_USER=myuser          # Docker Hub username
export DOCKERHUB_TOKEN=dckr_pat_…     # access token (stdin login; not printed)
make build test
make push                             # logs in if TOKEN is set; pushes 1.0.0, 1.0, latest
```

Already logged in (`podman login docker.io` / `docker login`):

```bash
make push REGISTRY_USER=myuser
```

Dry-run (prints names, no network):

```bash
make push REGISTRY_USER=myuser PUSH_DRY_RUN=1
```

Then pull / `FROM`:

```dockerfile
FROM docker.io/myuser/ubi10-apache-php:1.0.0
```

OpenShift: set `images.newName` in `examples/openshift/kustomization.yaml` to
`docker.io/myuser/ubi10-apache-php` and keep `newTag: "1.0.0"`.

## Downstream image

Do **not** set `COMPOSER_ALLOW_SUPERUSER`. The image user is `1001`, not root.

```dockerfile
FROM docker.io/<hub-user>/ubi10-apache-php:1.0.0

COPY --chown=1001:0 composer.json composer.lock ./
RUN composer install --no-dev --no-interaction --prefer-dist

COPY --chown=1001:0 . .
```

`PATH` already includes `/var/www/html/vendor/bin` (the directory does not need
to exist in the base image). Override PHP with `/etc/drupal/php.d/zz-*.ini` and
Apache with `/opt/httpd/conf.d/*.conf`.

## OpenShift (short)

- SCC `restricted-v2`. **Do not** pin `runAsUser`. **Do not** set `fsGroup: 0`.
- Container port **8080**. Route: edge TLS (or reencrypt to 8080 — still HTTP in the pod).
- Probes: **exec** `/opt/drupal/scripts/healthcheck.sh` with `timeoutSeconds` ≥ 5
  and a `startupProbe`. Do not use httpGet on the public Route (`/healthz` is
  local + RFC1918 only after RemoteIP).
- Writable mounts (required for a read-only rootfs; recommended anyway):
  `/tmp`, `/run/httpd`, `/run/php-fpm`. Drupal also needs
  `/var/www/html/web/sites/default/files` and `/var/www/html/files-private`.
- Set `$settings['reverse_proxy']` in the app. Apache sets `HTTPS=on` from
  `X-Forwarded-Proto`; Drupal still needs the reverse-proxy settings.

Example manifests: [`examples/openshift/`](examples/openshift/)
(`oc apply -k examples/openshift` after a registry push; set `images.newName`).

## PID 1

The entrypoint starts php-fpm with `-D`, waits for the socket, then
`exec httpd -D FOREGROUND`. **httpd is PID 1.** There is no tini or supervisord.
`STOPSIGNAL SIGWINCH` stops Apache gracefully; FPM is not reaped and does not
receive SIGTERM. That is the v1 process model — see
[docs/architecture.md](docs/architecture.md) and [docs/security.md](docs/security.md).

## Docs

- [docs/index.md](docs/index.md) — index
- [docs/architecture.md](docs/architecture.md) — process model and layout
- [docs/openshift.md](docs/openshift.md) — deploy, probes, mounts, Route
- [docs/env.md](docs/env.md) — environment variables and defaults
- [docs/extending.md](docs/extending.md) — `FROM`, Composer, drop-ins
- [docs/security.md](docs/security.md) — restricted-v2, files PHP, healthz
