# Extending the image

## `FROM` this base

The image user is `1001` (gid 0). Copy as that user. **Do not** set
`COMPOSER_ALLOW_SUPERUSER=1`. **Do not** `USER root` for Composer.

```dockerfile
FROM docker.io/<hub-user>/ubi10-apache-php:1.0.0

COPY --chown=1001:0 composer.json composer.lock ./
RUN composer install --no-dev --no-interaction --prefer-dist \
    --no-progress --optimize-autoloader

COPY --chown=1001:0 . .
```

`PATH` includes `/var/www/html/vendor/bin`, so `drush` from `vendor/bin` works
once Composer has installed it.

Keep DocumentRoot at `/var/www/html/web` (Drupal recommended-project layout).
The base placeholder `web/index.php` and `web/.htaccess` are overwritten by
`drupal/core-composer-scaffold`.

## PHP drop-ins

Remi loads extensions from `/etc/php.d`. Drupal overrides live in
`/etc/drupal/php.d/` and win because `PHP_INI_SCAN_DIR` lists them second.

Add `zz-*.ini` (later name wins):

```dockerfile
COPY --chown=1001:0 php/zz-memory.ini /etc/drupal/php.d/zz-memory.ini
```

```ini
; zz-memory.ini
memory_limit = 512M
```

CLI-only overrides belong in `/etc/drupal/php-cli.d/` (entrypoint non-`start`
path only). Do not put `memory_limit=-1` in `/etc/drupal/php.d/` — that would
apply to FPM workers.

Do not add `extension=` lines; Remi already loads the `.so` files.

## Apache drop-ins

`/opt/httpd/conf.d/*.conf` is `IncludeOptional` after the base fragments.
Examples: extra `RemoteIPInternalProxy` CIDRs for hostNetwork ingress,
custom `Timeout`.

```dockerfile
COPY --chown=1001:0 httpd/zz-remoteip-extra.conf /opt/httpd/conf.d/zz-remoteip-extra.conf
```

Do not add `<VirtualHost>`. Do not load `mod_ssl` or listen on 8443.

## Drupal `$settings['reverse_proxy']`

Apache restores the client IP (`RemoteIPHeader X-Forwarded-For`) and sets
`HTTPS=on` when `X-Forwarded-Proto` is `https`. Drupal still needs reverse
proxy settings in `settings.php` (or a settings include):

```php
$settings['reverse_proxy'] = TRUE;
$settings['reverse_proxy_addresses'] = [
  '10.0.0.0/8',
  '172.16.0.0/12',
  '192.168.0.0/16',
  '127.0.0.0/8',
];
```

Tune the CIDRs to the cluster’s pod/service networks. Also set
`$settings['trusted_host_patterns']` to the Route hostname.

`session.cookie_secure` is **not** set in the image (local `make run` is HTTP).
With reverse_proxy + `X-Forwarded-Proto: https`, Drupal/Symfony marks cookies
Secure on the Route.

## Remi package versions

EPEL and Remi **release RPMs** are sha256-pinned. The `php:remi-8.4` module
packages are not pinned at NVR, so a rebuild can move 8.4.x. After a release
build, run `make versions` and keep the `rpm -qa` output with the git tag.

## What not to add in the base

gcc/g++/make/re2c, jpegoptim, ImageMagick, wget, Xdebug, `mod_ssl`, HTTP/2,
brotli RPM, tini, supervisord, runtime templating, or Drupal core/contrib.
