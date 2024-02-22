# syntax=docker/dockerfile:1.4
FROM php:8.3-cli-alpine AS base
LABEL maintainer="moritz@matchory.com"

# Persistent/Runtime dependencies
RUN apk add --no-cache \
		gnu-libiconv \
        libstdc++ \
		gettext \
		fcgi \
		file \
		git \
		acl \
	;

# install gnu-libiconv and set LD_PRELOAD env to make iconv work fully on Alpine image.
# see https://github.com/docker-library/php/issues/240#issuecomment-763112749
ENV LD_PRELOAD /usr/lib/preloadable_libiconv.so

ARG user="5000"
ARG uid="5000"

ARG APCU_VERSION=5.1.23
ARG REDIS_VERSION=6.0.2
ARG OPENSWOOLE_VERSION=22.1.2

RUN set -eux; \
    apk add --no-cache --virtual .build-deps \
      $PHPIZE_DEPS \
      postgresql-dev \
      oniguruma-dev \
      linux-headers \
      openssl-dev \
      libzip-dev \
      pcre2-dev \
      pcre-dev \
      yaml-dev \
      curl-dev \
      zlib-dev \
      icu-dev \
      c-ares-dev \
      ; \
    \
    curl -L -o /tmp/redis.tar.gz "https://github.com/phpredis/phpredis/archive/${REDIS_VERSION}.tar.gz"; \
    tar xfz /tmp/redis.tar.gz; \
    rm -r /tmp/redis.tar.gz; \
    mkdir -p /usr/src/php/ext; \
    mv phpredis-* /usr/src/php/ext/redis; \
    \
    docker-php-ext-configure zip; \
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
    ; \
    docker-php-source extract; \
    mkdir -p /usr/src/php/ext/openswoole; \
    curl -sfL "https://github.com/openswoole/swoole-src/archive/refs/tags/v${OPENSWOOLE_VERSION}.tar.gz" -o openswoole.tar.gz; \
    tar xfz openswoole.tar.gz --strip-components=1 -C /usr/src/php/ext/openswoole; \
    docker-php-ext-configure openswoole \
      --enable-hook-curl \
      --enable-openssl \
      --enable-sockets \
      --enable-mysqlnd \
      --with-postgres \
      --enable-http2 \
      --enable-cares \
    ; \
    docker-php-ext-install -j$(nproc) --ini-name zz-openswoole.ini openswoole; \
    \
    pecl install \
      "apcu-${APCU_VERSION}" \
      excimer \
      yaml \
    ; \
    pecl clear-cache; \
    docker-php-ext-enable \
      opcache \
      excimer \
      apcu \
      yaml \
    ; \
    rm -f openswoole.tar.gz; \
    docker-php-source delete; \
    \
    runDeps="$( \
      scanelf --needed --nobanner --format '%n#p' --recursive /usr/local/lib/php/extensions \
        | tr ',' '\n' \
        | sort -u \
        | awk 'system("[ -e /usr/local/lib/" $1 " ]") == 0 { next } { print "so:" $1 }' \
    )"; \
    apk add --no-cache --virtual .phpexts-rundeps $runDeps; \
    \
    apk del .build-deps

RUN ln -sf "${PHP_INI_DIR}/php.ini-production" "${PHP_INI_DIR}/php.ini"

# Copy custom PHP settings
COPY --link php.ini "${PHP_INI_DIR}/conf.d/99-docker.ini"

# Create the application user
RUN adduser -D -G www-data -u "${uid}" -h "/home/${user}" "${user}"

ENTRYPOINT ["docker-php-entrypoint"]

VOLUME /var/run/php

EXPOSE 9000

FROM base as prod

# Opcache settings
ENV PHP_OPCACHE_ENABLE="1" \
    PHP_OPCACHE_VALIDATE_TIMESTAMPS="0" \
    PHP_OPCACHE_MAX_ACCELERATED_FILES="10000" \
    PHP_OPCACHE_MEMORY_CONSUMPTION="192" \
    PHP_OPCACHE_MAX_WASTED_PERCENTAGE="10"

RUN mv "${PHP_INI_DIR}/php.ini-production" "${PHP_INI_DIR}/php.ini"
