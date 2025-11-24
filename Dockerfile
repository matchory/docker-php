# syntax=docker/dockerfile:1
ARG PHP_VERSION="8.4"
FROM php:${PHP_VERSION}-cli AS upstream
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked <<EOF
    set -eux

    apt-get update
    apt-get install \
        --yes \
        --no-install-recommends \
      postgresql-client \
      libmemcached11t64 \
      ca-certificates \
      libyaml-0-2 \
      libicu76 \
      libzip5 \
      gettext \
      openssl \
      zlib1g \
      file \
    ;
EOF

FROM upstream AS builder
ARG APCU_VERSION="5.1.27"
ARG REDIS_VERSION="6.3.0"
ARG OPENSWOOLE_VERSION="25.2.0"

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked <<EOF
    set -eux

    # region Install Dependencies
    apt-get update
    apt-get install \
        --yes \
        --no-install-recommends \
      ${PHPIZE_DEPS} \
      linux-headers-generic \
      libcurl4-openssl-dev \
      libmemcached-dev \
      libonig-dev \
      libyaml-dev \
      libssl-dev \
      libicu-dev \
      libzip-dev \
      zlib1g-dev \
      libpq-dev \
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
    # endregion

EOF

FROM upstream AS base
ARG user="php"
ARG uid="5000"

RUN <<EOF
    # region Remove Build Dependencies
    apt-get purge \
        --option APT::AutoRemove::RecommendsImportant=false \
        --auto-remove \
        --yes \
    ;

    rm -rf \
      /usr/local/lib/php/test \
      /usr/local/bin/phpdbg \
      /usr/local/bin/install-php-extensions \
      /usr/local/bin/docker-php-source \
      /usr/local/bin/docker-php-ext-* \
      /usr/local/bin/phpize \
      /usr/local/bin/pear* \
      /usr/local/bin/pecl \
      /usr/src/* \
      /tmp/* \
    ;
    # endregion

    # region Add a non-root user to run the application
    addgroup \
        --gid "${uid}" \
      "${user}"
    adduser \
        --home "/home/${user}" \
        --disabled-password \
        --disabled-login \
        --uid "${uid}" \
        --gid ${uid} \
        --system \
      "${user}"
    # endregion
EOF

COPY --link --from=builder /usr/local/lib/php/extensions/ /usr/local/lib/php/extensions/
COPY --link --from=builder /usr/local/etc/php/conf.d/ /usr/local/etc/php/conf.d/

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

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    --mount=type=bind,from=upstream,source=/usr/local/bin,target=/usr/local/bin <<EOF
    set -eux
    ln -sf "${PHP_INI_DIR}/php.ini-development" "${PHP_INI_DIR}/php.ini"

    # region Install XDebug
    apt-get update
    apt-get install \
        --yes \
        --no-install-recommends \
      ${PHPIZE_DEPS}
    pecl install xdebug
    docker-php-ext-enable xdebug
    apt-get purge \
        --yes \
        --auto-remove \
      ${PHPIZE_DEPS}
    rm -rf  /tmp/*
    # endregion

    # region Configure XDebug
    # See https://docs.docker.com/desktop/networking/#i-want-to-connect-from-a-container-to-a-service-on-the-host
    # See https://github.com/docker/for-linux/issues/264
    # The `client_host` below may optionally be replaced with `discover_client_host=yes`
    # Add `start_with_request=yes` to start debug session on each request
    echo "xdebug.client_host = host.docker.internal" >> "${PHP_INI_DIR}/conf.d/xdebug.ini";
    echo "xdebug.mode = off" >> "${PHP_INI_DIR}/conf.d/xdebug.ini";
    # endregion
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
