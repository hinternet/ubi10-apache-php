# AGENTS — ubi10-apache-php

## Mission

OpenShift-first Drupal 11 runtime base image: UBI 10, Apache 2.4 `mpm_event`,
PHP-FPM 8.4. The image contains no Drupal application. Downstream images
`FROM` it and copy their own Composer tree.

## Environment

- Build file: `Containerfile`. Engine: Podman (`CONTAINER_ENGINE=docker` works). Platform: `linux/amd64`.
- PHP 8.4 (Remi `php:remi-8.4`) and Apache 2.4. Package NVRs are not pinned. `IMAGE_VERSION` defaults to `1.1.0`.
- Day-to-day commands: `make lint`, `make build`, `make test`, `make run`.

## Principles you must not violate

1. Do not add Drupal core, contrib, or an application to this image.
2. Bake config in `rootfs/`. No gomplate, gotpl, or `tpl.sh`.
3. httpd is PID 1. No tini or supervisord. `STOPSIGNAL` stays `SIGWINCH`.
4. Listen on 8080 only. No `<VirtualHost>` and no `mod_ssl`.
5. UID 1001, GID 0. No `COMPOSER_ALLOW_SUPERUSER` and no `USER root` for Composer. On OpenShift, do not pin `runAsUser` and do not set `fsGroup: 0`.
6. DocumentRoot stays `/var/www/html/web`. FPM `memory_limit` stays `256M`. `memory_limit=-1` belongs only in `/etc/drupal/php-cli.d` (non-`start` commands).
7. Keep compilers, jpegoptim, wget, Xdebug, HTTP/2, and brotli out of the base. Do not install the `ghostscript` package. GD stays the Drupal core toolkit. SVG rasterization is `php-pecl-imagick-im7` plus `librsvg2` (not EPEL `php-pecl-imagick`). `ImageMagick-libs` links `libgs` and Graphviz; PDF, PostScript, and MSVG stay denied in policy. Pinned resource caps: memory 256MiB, map 512MiB, disk 1GiB, area 128MP, 16KP, 60s.
8. Keep the digest pins: UBI base, Composer 2.10, EPEL release RPM, Remi release RPM.

## Project documentation

Before any task, read `docs/index.md`, then only the doc that task needs.
`README.md` and `docs/` are the contract.
