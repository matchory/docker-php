# syntax=docker/dockerfile:1
ARG PHP_VERSION="8.4"
ARG PIE_VERSION="1.3.0-rc.3"
FROM ghcr.io/php/pie:${PIE_VERSION} AS pie
FROM dunglas/frankenphp:1.10-php${PHP_VERSION} AS upstream
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked <<EOF
    set -eux

    export DEBIAN_FRONTEND=noninteractive
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
      libuv1 \
      zlib1g \
      unzip \
      file \
    ;
EOF

FROM upstream AS builder
ARG UV_VERSION="0.3.0"

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    --mount=type=bind,from=pie,source=/pie,target=/usr/bin/pie \
    <<EOF
    set -eux

    # region Install Dependencies
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install \
        --yes \
        --no-install-recommends \
      ${PHPIZE_DEPS} \
      libmemcached-dev \
      libsqlite3-dev \
      libyaml-dev \
      libicu-dev \
      libzip-dev \
      zlib1g-dev \
      libuv1-dev \
      libpq-dev \
      git \
    ;
    # endregion

    docker-php-source extract
    export num_cpu=$(nproc)

    # region Install PIE extensions
    pie install -j${num_cpu} phpredis/phpredis \
      --enable-redis \
    ;
    pie install -j${num_cpu} apcu/apcu \
      --enable-apcu \
    ;
    pie install -j${num_cpu} pecl/yaml
    pie install -j${num_cpu} php-memcached/php-memcached \
      --enable-memcached-session \
      --enable-memcached-json \
    ;
    #pie install -j${num_cpu} csvtoolkit/fastcsv \
    #  --enable-fastcsv \
    #;
    # endregion

    # region Install built-in extensions
    docker-php-ext-configure zip
    docker-php-ext-install -j${num_cpu} \
      pdo_sqlite \
      pdo_pgsql \
      sockets \
      bcmath \
      pcntl \
      intl \
      zip \
    ;

    # If we're running on PHP 8.4, install the opcache extension (it's bundled in later versions)
    if php --version | grep -q "PHP 8\.4"; then
      docker-php-ext-install -j${num_cpu} opcache
    fi

    # endregion

    # region Install uv extension
    pecl config-set preferred_state beta
    pecl install "uv-${UV_VERSION}"
    pecl config-set preferred_state stable
    # endregion

    # region Install PECL extensions
    pecl install excimer
    pecl clear-cache || true
    docker-php-ext-enable \
      excimer \
      uv \
    ;
    # endregion
EOF

FROM upstream AS base
ARG user="php"
ARG uid="900"

RUN <<EOF
    # region Remove Build Dependencies
    export DEBIAN_FRONTEND=noninteractive
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

    # Add additional capability to bind to port 80 and 443
    setcap CAP_NET_BIND_SERVICE=+eip /usr/local/bin/frankenphp

    # Give write access to /data/caddy and /config/caddy
    chown -R "${uid}:${uid}" \
        /config/caddy \
        /data/caddy

    # Create the application folder
    mkdir -p /app
EOF

COPY --link --from=builder /usr/local/lib/php/extensions/ /usr/local/lib/php/extensions/
COPY --link --from=builder /usr/local/etc/php/conf.d/ /usr/local/etc/php/conf.d/

# Copy custom PHP settings
COPY --link ./php.ini "${PHP_INI_DIR}/conf.d/99-docker.ini"
COPY --link ./Caddyfile /etc/caddy/Caddyfile

CMD ["--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD [ "curl", "-ISsfo", "/dev/null", "http://localhost:2019/metrics" ]

VOLUME /app
EXPOSE 80/tcp
EXPOSE 443/tcp
EXPOSE 443/udp
EXPOSE 2019/tcp
EXPOSE 2019/udp

FROM base AS dev
ARG user="php"
ARG uid="900"
ENV COMPOSER_ALLOW_SUPERUSER="1"
ENV PHP_OPCACHE_VALIDATE_TIMESTAMPS="1"

# Enables PHPStorm to apply the correct path mapping on Xdebug breakpoints
ENV PHP_IDE_CONFIG="serverName=Docker"

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    --mount=type=bind,from=pie,source=/pie,target=/usr/bin/pie \
    --mount=type=bind,from=upstream,source=/usr/local/bin,target=/usr/local/bin \
    <<EOF
    set -eux
    ln -sf "${PHP_INI_DIR}/php.ini-development" "${PHP_INI_DIR}/php.ini"

    # region Install XDebug
    # TODO: Switch to stable when available
    if php --version | grep -q "PHP 8\.5"; then
      pie install xdebug/xdebug:@alpha
    else
      pie install xdebug/xdebug
    fi
    rm -rf /tmp/*
    # endregion

    # region Configure XDebug
    # See https://docs.docker.com/desktop/networking/#i-want-to-connect-from-a-container-to-a-service-on-the-host
    # See https://github.com/docker/for-linux/issues/264
    # The `client_host` below may optionally be replaced with `discover_client_host=yes`
    # Add `start_with_request=yes` to start debug session on each request
    echo "xdebug.client_host = host.docker.internal" >> "${PHP_INI_DIR}/conf.d/docker-php-ext-xdebug.ini";
    echo "xdebug.mode = off" >> "${PHP_INI_DIR}/conf.d/docker-php-ext-xdebug.ini";
    # endregion
EOF

COPY --link --from=composer:latest /usr/bin/composer /usr/bin/composer

WORKDIR "/app"

ONBUILD ARG user="php"
ONBUILD ARG uid="900"
USER "${uid}:${uid}"

FROM base AS prod
ARG user="php"
ARG uid="900"
ENV PHP_OPCACHE_VALIDATE_TIMESTAMPS="0"
ENV PHP_OPCACHE_MAX_ACCELERATED_FILES="10000"
ENV PHP_OPCACHE_MEMORY_CONSUMPTION="192"
ENV PHP_OPCACHE_MAX_WASTED_PERCENTAGE="10"

RUN ln -sf "${PHP_INI_DIR}/php.ini-production" "${PHP_INI_DIR}/php.ini"

WORKDIR "/app"

ONBUILD ARG user="php"
ONBUILD ARG uid="900"
USER "${uid}:${uid}"
