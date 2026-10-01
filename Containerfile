FROM docker.io/redhat/ubi10-minimal:1787688387@sha256:204e1531cee54562b107fb31e0b327062fc3d5d67af7cc0d2e66b2c572b9044f

SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

ARG UID=1001
ARG GID=0

ENV PHP_VERSION=8.4 \
    HTTPD_VERSION=2.4 \
    HOME=/var/www/html \
    PATH="/var/www/html/vendor/bin:${PATH}" \
    COMPOSER_HOME=/opt/drupal/.composer \
    PHP_INI_SCAN_DIR=/etc/php.d:/etc/drupal/php.d \
    PHP_FPM_CONF=/opt/httpd/conf/php-fpm.conf \
    HTTPD_CONF=/opt/httpd/conf/httpd.conf

ARG MICRODNF_FLAGS="--disableplugin=subscription-manager --nodocs --setopt=install_weak_deps=0"

ARG EPEL_RELEASE_URL="https://dl.fedoraproject.org/pub/epel/10/Everything/x86_64/Packages/e/epel-release-10-9.el10_3.noarch.rpm"
ARG EPEL_RELEASE_SHA256="f567aa5c3cde55f579ba5c41c79df97da692a391efddd14b123a4eec0824fbc0"
ARG REMI_RELEASE_URL="https://rpms.remirepo.net/enterprise/10/remi/x86_64/remi-release-10.2-1.el10.remi.noarch.rpm"
ARG REMI_RELEASE_SHA256="3b47fa7deb85ecf9ababb2f0d888136c29eb852375d66729fe1c95408852bc4b"

ARG INSTALL_BASE_PKGS="httpd unzip tar rsync procps-ng shadow-utils patch git \
                       findutils hostname tzdata which ncurses curl nss_wrapper \
                       mariadb postgresql"

ARG INSTALL_PHP_PKGS="php php-cli php-common php-fpm"

ARG INSTALL_PHP_EXTS="php-mysqlnd php-pgsql php-bcmath php-curl php-gd php-gmp \
                      php-intl php-ldap php-mbstring php-opcache \
                      php-pdo php-process php-soap php-sodium php-xml"

ARG INSTALL_PHP_PECL="php-pecl-apcu php-pecl-igbinary php-pecl-memcached \
                      php-pecl-redis6 php-pecl-uploadprogress php-pecl-zip"

RUN set -x; \
    microdnf ${MICRODNF_FLAGS} install -y ${INSTALL_BASE_PKGS}; \
    microdnf ${MICRODNF_FLAGS} clean all; \
    rm -rf /var/cache/dnf /var/cache/yum; \
    httpd -v | grep -qE "Apache/${HTTPD_VERSION}\."; \
    command -v mysql; command -v mysqldump; command -v psql; command -v pg_dump

RUN set -x; \
    curl -fsSL -o /tmp/epel-release.rpm "${EPEL_RELEASE_URL}"; \
    curl -fsSL -o /tmp/remi-release.rpm "${REMI_RELEASE_URL}"; \
    echo "${EPEL_RELEASE_SHA256}  /tmp/epel-release.rpm" | sha256sum -c -; \
    echo "${REMI_RELEASE_SHA256}  /tmp/remi-release.rpm" | sha256sum -c -; \
    rpm -iv --replacepkgs /tmp/epel-release.rpm /tmp/remi-release.rpm; \
    rm -f /tmp/epel-release.rpm /tmp/remi-release.rpm; \
    microdnf ${MICRODNF_FLAGS} module reset -y php || true; \
    microdnf ${MICRODNF_FLAGS} module enable -y "php:remi-${PHP_VERSION}"; \
    microdnf ${MICRODNF_FLAGS} install -y \
        ${INSTALL_PHP_PKGS} ${INSTALL_PHP_EXTS} ${INSTALL_PHP_PECL}; \
    microdnf ${MICRODNF_FLAGS} clean all; \
    rm -rf /var/cache/dnf /var/cache/yum; \
    php -v | grep -qE "^PHP ${PHP_VERSION}\."; \
    php-fpm -v | grep -qE "^PHP ${PHP_VERSION}\."; \
    php -r 'exit(defined("PASSWORD_ARGON2ID") ? 0 : 1);'; \
    php -r 'foreach (["curl","gd","mbstring","xml","zip","pdo_mysql","pdo_pgsql","openssl","zlib","fileinfo","json","apcu","igbinary","sodium"] as $e) { if (!extension_loaded($e)) { fwrite(STDERR, "missing ext $e\n"); exit(1);} }'; \
    php -m | grep -qi opcache; \
    php-fpm -m | grep -qi opcache; \
    php -r '$i=gd_info(); foreach (["JPEG Support","PNG Support","WebP Support"] as $k) { if (empty($i[$k])) { fwrite(STDERR, "gd missing $k\n"); var_export($i); exit(1);} }'

COPY --from=docker.io/composer:2.10@sha256:af98f42dfff7c68ba8d53c2164fd9fde1087b7d449514baa38c418b1f6bc4bac /usr/bin/composer /usr/bin/composer
COPY rootfs/ /

RUN set -x; \
    useradd -l -u ${UID} -g ${GID} -d ${HOME} -s /sbin/nologin -M drupal; \
    mkdir -p \
        /opt/httpd/conf.d /opt/httpd/conf.modules.d /opt/httpd/conf/php-fpm.d \
        ${COMPOSER_HOME} \
        /etc/drupal/php.d /etc/drupal/php-cli.d \
        ${HOME}/files-private \
        ${HOME}/web/sites/default/files \
        /tmp/php-sessions /run/httpd /run/php-fpm; \
    ln -sfn /etc/httpd/modules /opt/httpd/modules; \
    ln -sfn ${HTTPD_CONF} /etc/httpd/conf/httpd.conf; \
    chmod +x /opt/drupal/scripts/entrypoint.sh \
             /opt/drupal/scripts/healthcheck.sh; \
    # g=u while still root-owned. Rootless Podman/Docker often lack CAP_FOWNER
    # after chown 1001:0, so chmod -R g=u then fails with EPERM (Ubuntu).
    # Skip symlinks (chmod would follow /opt/httpd/modules → RPM /etc/httpd/modules).
    find /etc/drupal /opt/httpd /opt/drupal \
        ${HOME} /tmp/php-sessions /run/httpd /run/php-fpm \
        \( -type d -o -type f \) -exec chmod g=u {} +; \
    chown -R ${UID}:${GID} \
        /etc/drupal /opt/httpd /opt/drupal \
        ${HOME} /tmp/php-sessions /run/httpd /run/php-fpm; \
    find / -xdev -type f -perm /6000 -exec chmod a-s {} + 2>/dev/null || true; \
    composer --version

ARG IMAGE_VERSION=1.0.0
ARG BUILD_DATE=unknown
ARG GIT_REVISION=unknown
ARG GIT_SOURCE=unknown
LABEL org.opencontainers.image.title="ubi10-apache-php" \
      org.opencontainers.image.description="Drupal 11 base image: UBI 10, Apache 2.4 (mpm_event), PHP-FPM 8.4 (Remi)" \
      org.opencontainers.image.licenses="MIT (build tooling); UBI layers: Red Hat UBI EULA" \
      org.opencontainers.image.base.name="docker.io/redhat/ubi10-minimal" \
      org.opencontainers.image.version="${IMAGE_VERSION}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.revision="${GIT_REVISION}" \
      org.opencontainers.image.source="${GIT_SOURCE}" \
      io.openshift.expose-services="8080:http" \
      io.openshift.tags="drupal,php,php-fpm,apache,ubi10"

USER ${UID}
EXPOSE 8080
WORKDIR ${HOME}
STOPSIGNAL SIGWINCH
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD ["/opt/drupal/scripts/healthcheck.sh"]

ENTRYPOINT ["/opt/drupal/scripts/entrypoint.sh"]
CMD [ "start" ]
