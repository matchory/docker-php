# syntax=docker/dockerfile:1.12
FROM php:8.4-cli-alpine AS base
LABEL org.opencontainers.image.title="Matchory PHP Web Development Image"
LABEL org.opencontainers.image.description="Matchory base image for local development of PHP web apps"
LABEL org.opencontainers.image.url=https://matchory.com
LABEL org.opencontainers.image.source=https://bitbucket.org/matchory/php-web
LABEL org.opencontainers.image.licenses=MIT
LABEL org.opencontainers.image.vendor="Mathory GmbH"

ARG user="5000"
ARG uid="5000"

ARG APCU_VERSION=5.1.24
ARG REDIS_VERSION=6.1.0
ARG OPENSWOOLE_VERSION=22.1.2

# Persistent/Runtime dependencies
RUN apk add --no-cache \
    gnu-libiconv \
    libstdc++ \
    gettext \
    fcgi \
    file \
    nano \
    git \
    acl \
;

# install gnu-libiconv and set LD_PRELOAD env to make iconv work fully on Alpine image.
# see https://github.com/docker-library/php/issues/240#issuecomment-763112749
ENV LD_PRELOAD=/usr/lib/preloadable_libiconv.so

RUN <<EOF
set -eux
apk add --no-cache --virtual .build-deps \
  $PHPIZE_DEPS \
  postgresql-dev \
  oniguruma-dev \
  linux-headers \
  openssl-dev \
  c-ares-dev \
  libzip-dev \
  pcre2-dev \
  pcre-dev \
  yaml-dev \
  curl-dev \
  zlib-dev \
  icu-dev \
;

curl -L -o /tmp/redis.tar.gz "https://github.com/phpredis/phpredis/archive/${REDIS_VERSION}.tar.gz"
tar xfz /tmp/redis.tar.gz
rm -r /tmp/redis.tar.gz
mkdir -p /usr/src/php/ext
mv phpredis-* /usr/src/php/ext/redis

docker-php-ext-configure zip
docker-php-ext-install -j$(nproc) \
    pdo_mysql \
    pdo_pgsql \
    mbstring \
    sockets \
    opcache \
    bcmath \
    pcntl \
    redis \
    intl \
    zip \
;

docker-php-source extract
mkdir -p /usr/src/php/ext/openswoole
curl -sfL "https://github.com/openswoole/swoole-src/archive/refs/tags/v${OPENSWOOLE_VERSION}.tar.gz" -o openswoole.tar.gz
tar xfz openswoole.tar.gz --strip-components=1 -C /usr/src/php/ext/openswoole
docker-php-ext-configure openswoole \
  --enable-hook-curl \
  --enable-openssl \
  --enable-sockets \
  --enable-mysqlnd \
  --with-postgres \
  --enable-http2 \
  --enable-cares \
;

docker-php-ext-install -j$(nproc) --ini-name zz-openswoole.ini openswoole

pecl install \
  "apcu-${APCU_VERSION}" \
  excimer \
  yaml \
;

pecl clear-cache
docker-php-ext-enable \
  opcache \
  excimer \
  apcu \
  yaml \
;

rm -f openswoole.tar.gz
docker-php-source delete

runDeps="$( \
  scanelf --needed --nobanner --format '%n#p' --recursive /usr/local/lib/php/extensions \
    | tr ',' '\n' \
    | sort -u \
    | awk 'system("[ -e /usr/local/lib/" $1 " ]") == 0 { next } { print "so:" $1 }' \
)"
apk add --no-cache --virtual .phpexts-rundeps $runDeps
apk del .build-deps
EOF

# Copy custom PHP settings
COPY --link php.ini "${PHP_INI_DIR}/conf.d/99-docker.ini"

# Create the application user
RUN <<EOF
set -eux
ln -sf "${PHP_INI_DIR}/php.ini-production" "${PHP_INI_DIR}/php.ini"
adduser -D -G www-data -u "${uid}" -h "/home/${user}" "${user}"
EOF

ENTRYPOINT ["docker-php-entrypoint"]

VOLUME /var/run/php

EXPOSE 9000

FROM base AS dev
ENV COMPOSER_ALLOW_SUPERUSER="1"

# Enables PHPStorm to apply the correct path mapping on Xdebug breakpoints
ENV PHP_IDE_CONFIG serverName=Docker
RUN <<EOF
set -eux
mv "${PHP_INI_DIR}/php.ini-development" "${PHP_INI_DIR}/php.ini"

# See https://docs.docker.com/desktop/networking/#i-want-to-connect-from-a-container-to-a-service-on-the-host
# See https://github.com/docker/for-linux/issues/264
# The `client_host` below may optionally be replaced with `discover_client_host=yes`
# Add `start_with_request=yes` to start debug session on each request
echo "xdebug.client_host = host.docker.internal" >> "${PHP_INI_DIR}/conf.d/99-docker.ini"
apk add --no-cache --virtual .build-deps linux-headers ${PHPIZE_DEPS}
pecl install xdebug
docker-php-ext-enable xdebug

apk del .build-deps
apk  add --no-cache colordiff postgresql-client
EOF

COPY --link --from=composer:latest /usr/bin/composer /usr/bin/composer
