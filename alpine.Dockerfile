# syntax=docker/dockerfile:1
ARG PHP_VERSION="8.4"
FROM php:${PHP_VERSION}-cli-alpine AS upstream
FROM upstream AS base
ARG APCU_VERSION="5.1.27"
ARG REDIS_VERSION="6.3.0"
ARG OPENSWOOLE_VERSION="25.2.0"
ARG user="php"
ARG uid="5000"

# Install gnu-libiconv and set LD_PRELOAD env to make iconv work fully on Alpine image.
# see https://github.com/docker-library/php/issues/240#issuecomment-763112749
ENV LD_PRELOAD="/usr/lib/preloadable_libiconv.so"

RUN <<EOF
    set -eux

    # region Install Dependencies
    apk add \
        --no-cache \
      postgresql-client \
      libmemcached-dev \
      ca-certificates \
      gnu-libiconv \
      libzip-dev \
      yaml-dev \
      zlib-dev \
      gettext \
      fcgi \
      file \
      acl \
    ;
    apk add \
        --no-cache \
        --virtual .build-deps \
      ${PHPIZE_DEPS} \
      postgresql-dev \
      oniguruma-dev \
      linux-headers \
      openssl-dev \
      c-ares-dev \
      pcre2-dev \
      pcre-dev \
      curl-dev \
      icu-dev \
    ;
    # endregion

    # region Install redis extension
    curl \
        --fail \
        --silent \
        --location \
        --output /tmp/redis.tar.gz \
      "https://github.com/phpredis/phpredis/archive/${REDIS_VERSION}.tar.gz"
    tar xfz /tmp/redis.tar.gz
    rm -rf /tmp/redis.tar.gz
    mkdir -p /usr/src/php/ext
    mv phpredis-* /usr/src/php/ext/redis
    # endregion

    # region Install Extensions
    docker-php-source extract
    docker-php-ext-configure zip
    docker-php-ext-install -j$(nproc) \
      pdo_pgsql \
      sockets \
      opcache \
      bcmath \
      pcntl \
      redis \
      intl \
      zip \
    ;
    # endregion

    # region Install PECL Extensions
    pecl install memcached
    pecl install excimer
    pecl install "apcu-${APCU_VERSION}"
    pecl install yaml
    pecl install "openswoole-${OPENSWOOLE_VERSION}"
    pecl clear-cache || true
    docker-php-ext-enable \
      openswoole \
      memcached \
      opcache \
      excimer \
      apcu \
      yaml \
    ;
    docker-php-source delete
    # endregion

    # region Remove Build Dependencies
    runDeps="$( \
      scanelf \
          --format '%n#p' \
          --recursive \
          --nobanner \
          --needed \
        /usr/local/lib/php/extensions \
        | tr ',' '\n' \
        | sort -u \
        | awk 'system("[ -e /usr/local/lib/" $1 " ]") == 0 { next } { print "so:" $1 }' \
    )"
    apk add \
        --no-cache \
        --virtual .phpexts-rundeps \
      ${runDeps}
    apk del .build-deps
    rm -rf \
      /usr/local/lib/php/test \
      /usr/local/bin/phpdbg \
      /usr/local/bin/docker-php-ext-* \
      /usr/local/bin/docker-php-source \
      /usr/local/bin/install-php-extensions \
      /usr/local/bin/pear* \
      /usr/local/bin/pecl \
      /usr/local/bin/phpize \
      /var/cache/* \
      /usr/src/* \
      /tmp/*
    # endregion

    # Add a non-root user to run the application
    addgroup \
        -g "${uid}" \
        -S \
      "${user}"
    adduser \
        -h "/home/${user}" \
        -u "${uid}" \
        -G ${user} \
        -DS \
      "${user}"
EOF

# Copy custom PHP settings
COPY --link php.ini "${PHP_INI_DIR}/conf.d/99-docker.ini"

ENTRYPOINT ["docker-php-entrypoint"]
VOLUME /var/run/php
VOLUME /app
EXPOSE 9000

FROM base AS dev
ARG user="php"
ARG uid="5000"
ENV COMPOSER_ALLOW_SUPERUSER="1"
ENV PHP_OPCACHE_VALIDATE_TIMESTAMPS="1"

# Enables PHPStorm to apply the correct path mapping on Xdebug breakpoints
ENV PHP_IDE_CONFIG="serverName=Docker"

RUN --mount=type=bind,from=upstream,source=/usr/local/bin,target=/usr/local/bin <<EOF
    set -eux
    ln -sf "${PHP_INI_DIR}/php.ini-development" "${PHP_INI_DIR}/php.ini"

    # region Install XDebug
    apk add \
        --no-cache \
        --virtual .build-deps \
      ${PHPIZE_DEPS} \
      linux-headers \
    ;
    pecl install xdebug
    docker-php-ext-enable xdebug
    apk del .build-deps
    rm -rf \
      /var/cache/* \
      /tmp/*
    # endregion

    # See https://docs.docker.com/desktop/networking/#i-want-to-connect-from-a-container-to-a-service-on-the-host
    # See https://github.com/docker/for-linux/issues/264
    # The `client_host` below may optionally be replaced with `discover_client_host=yes`
    # Add `start_with_request=yes` to start debug session on each request
    echo "xdebug.client_host = host.docker.internal" >> "${PHP_INI_DIR}/conf.d/xdebug.ini";
    echo "xdebug.mode = off" >> "${PHP_INI_DIR}/conf.d/xdebug.ini";
EOF

COPY --link --from=composer:latest /usr/bin/composer /usr/bin/composer

WORKDIR "/app"

ONBUILD ARG user="php"
ONBUILD ARG uid="5000"
USER "${uid}:${uid}"

FROM base AS prod
ARG user="php"
ARG uid="5000"
ENV PHP_OPCACHE_VALIDATE_TIMESTAMPS="0"
ENV PHP_OPCACHE_MAX_ACCELERATED_FILES="10000"
ENV PHP_OPCACHE_MEMORY_CONSUMPTION="192"
ENV PHP_OPCACHE_MAX_WASTED_PERCENTAGE="10"

RUN ln -sf "${PHP_INI_DIR}/php.ini-production" "${PHP_INI_DIR}/php.ini"

WORKDIR "/app"

ONBUILD ARG user="php"
ONBUILD ARG uid="5000"
USER "${uid}:${uid}"
