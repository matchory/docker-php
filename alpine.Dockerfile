# syntax=docker/dockerfile:1.13
FROM php:8.4-cli-alpine AS base
ARG user="5000"
ARG uid="5000"

ARG APCU_VERSION="5.1.24"
ARG REDIS_VERSION="6.1.0"
ARG OPENSWOOLE_VERSION="25.2.0"

# Install gnu-libiconv and set LD_PRELOAD env to make iconv work fully on Alpine image.
# see https://github.com/docker-library/php/issues/240#issuecomment-763112749
ENV LD_PRELOAD="/usr/lib/preloadable_libiconv.so"

# Create the application user
RUN <<EOF
    set -eux

    # Add a non-root user to run the application
    adduser -D -G www-data -u "${uid}" -h "/home/${user}" "${user}"
    ln -sf "${PHP_INI_DIR}/php.ini-production" "${PHP_INI_DIR}/php.ini"

    # region Dependencies
    # Runtime dependencies
    apk add --no-cache \
      gnu-libiconv \
      libstdc++ \
      gettext \
      fcgi \
      file \
      git \
      acl \
    ;

    # Build dependencies
    apk add --no-cache --virtual .build-deps \
      ${PHPIZE_DEPS} \
      libmemcached-dev \
      postgresql-dev \
      oniguruma-dev \
      linux-headers \
      openssl-dev \
      libzip-dev \
      c-ares-dev \
      pcre2-dev \
      pcre-dev \
      yaml-dev \
      curl-dev \
      zlib-dev \
      icu-dev \
    ;
    # endregion

    # region Install redis
    curl -L -o /tmp/redis.tar.gz "https://github.com/phpredis/phpredis/archive/${REDIS_VERSION}.tar.gz"
    tar xfz /tmp/redis.tar.gz
    rm -r /tmp/redis.tar.gz
    mkdir -p /usr/src/php/ext
    mv phpredis-* /usr/src/php/ext/redis
    # endregion

    # region Install Extensions
    docker-php-ext-configure zip
    docker-php-ext-install -j$(nproc) \
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
    # endregion

    # region Install OpenSwoole
    docker-php-source extract
    mkdir --parents /usr/src/php/ext/openswoole
    curl \
          --silent \
          --fail \
          --location \
          --output openswoole.tar.gz \
      "https://github.com/openswoole/swoole-src/archive/refs/tags/v${OPENSWOOLE_VERSION}.tar.gz"
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
    rm -f openswoole.tar.gz
    docker-php-source delete
    # endregion

    # region Install PECL Extensions
    pecl install \
      memcached \
      excimer \
      "apcu-${APCU_VERSION}" \
      yaml \
    ;
    pecl clear-cache || true
    docker-php-ext-enable \
      opcache \
      excimer \
      apcu \
      yaml \
    ;
    # endregion

    # Remove build dependencies
    runDeps="$( \
      scanelf --needed --nobanner --format '%n#p' --recursive /usr/local/lib/php/extensions \
        | tr ',' '\n' \
        | sort -u \
        | awk 'system("[ -e /usr/local/lib/" $1 " ]") == 0 { next } { print "so:" $1 }' \
    )"
    apk add --no-cache --virtual .phpexts-rundeps ${runDeps}
    apk del .build-deps
    # endregion
EOF

# Copy custom PHP settings
COPY --link php.ini "${PHP_INI_DIR}/conf.d/99-docker.ini"

ENTRYPOINT ["docker-php-entrypoint"]
VOLUME /var/run/php
EXPOSE 9000

FROM base AS dev
ENV COMPOSER_ALLOW_SUPERUSER="1"

# Enables PHPStorm to apply the correct path mapping on Xdebug breakpoints
ENV PHP_IDE_CONFIG="serverName=Docker"

RUN <<EOF
    set -eux
    ln -sf "${PHP_INI_DIR}/php.ini-development" "${PHP_INI_DIR}/php.ini"

    # region Dependencies
    # Runtime dependencies
    apk add --no-cache \
      colordiff \
      postgresql-client \
    ;

    # Build dependencies
    apk add --no-cache --virtual .build-deps \
      ${PHPIZE_DEPS} \
      linux-headers \
    ;
    # endregion

    # region Install XDebug
    pecl install xdebug
    docker-php-ext-enable xdebug
    # endregion

    apk del .build-deps

    # See https://docs.docker.com/desktop/networking/#i-want-to-connect-from-a-container-to-a-service-on-the-host
    # See https://github.com/docker/for-linux/issues/264
    # The `client_host` below may optionally be replaced with `discover_client_host=yes`
    # Add `start_with_request=yes` to start debug session on each request
    echo "xdebug.client_host = host.docker.internal" >> "${PHP_INI_DIR}/conf.d/docker-php-ext-xdebug.ini";
    echo "xdebug.mode = off" >> "${PHP_INI_DIR}/conf.d/docker-php-ext-xdebug.ini";
EOF

COPY --link --from=composer:latest /usr/bin/composer /usr/bin/composer

FROM base AS prod
ENV PHP_OPCACHE_ENABLE="1"
ENV PHP_OPCACHE_VALIDATE_TIMESTAMPS="0"
ENV PHP_OPCACHE_MAX_ACCELERATED_FILES="10000"
ENV PHP_OPCACHE_MEMORY_CONSUMPTION="192"
ENV PHP_OPCACHE_MAX_WASTED_PERCENTAGE="10"

RUN ln -sf "${PHP_INI_DIR}/php.ini-production" "${PHP_INI_DIR}/php.ini"
