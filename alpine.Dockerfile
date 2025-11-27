# syntax=docker/dockerfile:1
ARG PHP_VERSION="8.4"
ARG PIE_VERSION="1.3.0"
FROM ghcr.io/php/pie:${PIE_VERSION} AS pie
FROM php:${PHP_VERSION}-cli-alpine AS upstream
FROM upstream AS base
ARG UV_VERSION="0.3.0"
ARG user="php"
ARG uid="900"

# Install gnu-libiconv and set LD_PRELOAD env to make iconv work fully on Alpine image.
# see https://github.com/docker-library/php/issues/240#issuecomment-763112749
ENV LD_PRELOAD="/usr/lib/preloadable_libiconv.so"

RUN --mount=type=bind,from=pie,source=/pie,target=/usr/bin/pie \
    <<EOF
    set -eux

    if php --version | grep -q "PHP 8\.4"; then
      php_8_4=true
    fi

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
      libuv \
      unzip \
      fcgi \
      file \
      acl \
    ;
    apk add \
        --no-cache \
        --virtual .build-deps \
      ${PHPIZE_DEPS} \
      ${php_8_4:+curl-dev} \
      postgresql-dev \
      linux-headers \
      liburing-dev \
      sqlite-dev \
      pcre2-dev \
      libuv-dev \
      pcre-dev \
      icu-dev \
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
    if [ "${php_8_4:-}" = "true" ]; then
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

    # region Install Swoole with extra features
    # TODO: Remove this condition when Swoole supports PHP 8.5+
    if php --version | grep -q "PHP 8\.4"; then
        pie install -j${num_cpu} swoole/swoole \
          --enable-swoole-sqlite \
          --enable-swoole-pgsql \
          --enable-swoole-curl \
          --enable-sockets \
          --enable-openssl \
          --enable-iouring \
          --enable-brotli \
        ;
    fi
    # endregion

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
      /usr/local/bin/install-php-extensions \
      /usr/local/bin/docker-php-source \
      /usr/local/bin/docker-php-ext-* \
      /usr/local/bin/phpize \
      /usr/local/bin/pear* \
      /usr/local/bin/pecl \
      /usr/local/bin/phpize \
      /var/cache/* \
      /usr/src/* \
      /tmp/* \
    ;
    # endregion

    # region Add a non-root user to run the application
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
    # endregion
EOF

# Copy custom PHP settings
COPY --link ./php.ini "${PHP_INI_DIR}/conf.d/99-docker.ini"

FROM base AS dev
ARG user="php"
ARG uid="900"
ENV COMPOSER_ALLOW_SUPERUSER="1"
ENV PHP_OPCACHE_VALIDATE_TIMESTAMPS="1"

# Enables PHPStorm to apply the correct path mapping on Xdebug breakpoints
ENV PHP_IDE_CONFIG="serverName=Docker"

RUN --mount=type=bind,from=pie,source=/pie,target=/usr/bin/pie \
    --mount=type=bind,from=upstream,source=/usr/local/bin,target=/usr/local/bin \
    <<EOF
    set -eux
    ln -sf "${PHP_INI_DIR}/php.ini-development" "${PHP_INI_DIR}/php.ini"

    # region Install XDebug
    apk add \
        --no-cache \
        --virtual .build-deps \
      ${PHPIZE_DEPS} \
      linux-headers \
    ;

    # TODO: Switch to stable when available
    if php --version | grep -q "PHP 8\.5"; then
      pie install xdebug/xdebug:@alpha
    else
      pie install xdebug/xdebug
    fi
    apk del .build-deps
    rm -rf \
      /var/cache/* \
      /tmp/*
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

ENTRYPOINT ["docker-php-entrypoint"]

VOLUME /var/run/php
VOLUME /app
EXPOSE 9000/tcp

FROM base AS prod-pre
RUN <<EOF
    # region Remove Build Dependencies
    set -eux
    apk del ${PHPIZE_DEPS} *-dev
    rm -rf \
      /usr/local/bin/phpdbg \
      /usr/local/bin/php-cgi \
      /usr/local/bin/php-config \
      /usr/local/bin/install-php-extensions \
      /usr/local/bin/docker-php-source \
      /usr/local/bin/docker-php-ext-* \
      /usr/local/bin/phpize \
      /usr/local/bin/pear* \
      /usr/local/bin/phar* \
      /usr/local/bin/pecl \
      /usr/local/php/man \
      /usr/local/etc/pear.conf \
      /usr/local/lib/php/PEAR \
	  /usr/local/lib/php/.registry \
      /usr/src/* \
      /var/cache/* \
      /var/log/* \
      /tmp/* \
    ;
    # endregion
EOF

FROM scratch AS prod
ARG user="php"
ARG uid="900"
ENV PHP_OPCACHE_VALIDATE_TIMESTAMPS="0"
ENV PHP_OPCACHE_MAX_ACCELERATED_FILES="10000"
ENV PHP_OPCACHE_MEMORY_CONSUMPTION="192"
ENV PHP_OPCACHE_MAX_WASTED_PERCENTAGE="10"

COPY --link --from=prod-pre / /
RUN ln -sf "${PHP_INI_DIR}/php.ini-production" "${PHP_INI_DIR}/php.ini"

WORKDIR "/app"

ONBUILD ARG user="php"
ONBUILD ARG uid="900"
USER "${uid}:${uid}"

ENTRYPOINT ["docker-php-entrypoint"]

VOLUME /var/run/php
VOLUME /app
EXPOSE 9000/tcp
