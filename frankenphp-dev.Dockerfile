# syntax=docker/dockerfile:1.7
FROM dunglas/frankenphp:php8.3-alpine

LABEL org.opencontainers.image.title="Matchory PHP Web Development Image"
LABEL org.opencontainers.image.description="Matchory base image for local development of PHP web apps"
LABEL org.opencontainers.image.url=https://matchory.com
LABEL org.opencontainers.image.source=https://bitbucketorg/matchory/php-web
LABEL org.opencontainers.image.licenses=MIT
LABEL org.opencontainers.image.vendor="Mathory GmbH"

# Persistent/Runtime dependencies
RUN apk add --no-cache \
        postgresql-client \
        gnu-libiconv \
        colordiff \
        libstdc++ \
        gettext \
        nodejs \
        file \
        npm \
        acl \
	;
# install gnu-libiconv and set LD_PRELOAD env to make iconv work fully on Alpine image.
# see https://github.com/docker-library/php/issues/240#issuecomment-763112749
ENV LD_PRELOAD /usr/lib/preloadable_libiconv.so

ARG user="5000"
ARG uid="5000"

ARG APCU_VERSION=5.1.23
ARG REDIS_VERSION=6.0.2

RUN set -eux; \
    apk add --no-cache --virtual .build-deps \
      ${PHPIZE_DEPS} \
      postgresql-dev \
      oniguruma-dev \
      linux-headers \
      libzip-dev \
      yaml-dev \
      curl-dev \
      zlib-dev \
      icu-dev \
      ; \
    \
    curl -L -o /tmp/redis.tar.gz "https://github.com/phpredis/phpredis/archive/${REDIS_VERSION}.tar.gz"; \
    tar xfz /tmp/redis.tar.gz; \
    rm -r /tmp/redis.tar.gz; \
    mkdir -p /usr/src/php/ext; \
    mv phpredis-* /usr/src/php/ext/redis; \
    \
    docker-php-ext-configure zip; \
    docker-php-ext-configure zip; \
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
    ; \
    pecl install \
      "apcu-${APCU_VERSION}" \
      excimer \
      xdebug \
      yaml \
    ; \
    docker-php-ext-enable \
      opcache \
      excimer \
      xdebug \
      apcu \
      yaml \
    ; \
    runDeps="$( \
      scanelf --needed --nobanner --format '%n#p' --recursive /usr/local/lib/php/extensions \
        | tr ',' '\n' \
        | sort -u \
        | awk 'system("[ -e /usr/local/lib/" $1 " ]") == 0 { next } { print "so:" $1 }' \
    )"; \
    apk add --no-cache --virtual .phpexts-rundeps ${runDeps}; \
    \
    apk del .build-deps

# Copy custom PHP settings
COPY --link php.ini "${PHP_INI_DIR}/conf.d/99-docker.ini"
COPY --link Caddyfile /etc/caddy/Caddyfile

RUN set -eux; \
    ln -sf "${PHP_INI_DIR}/php.ini-development" "${PHP_INI_DIR}/php.ini"; \
    \
    # See https://docs.docker.com/desktop/networking/#i-want-to-connect-from-a-container-to-a-service-on-the-host
    # See https://github.com/docker/for-linux/issues/264
    # The `client_host` below may optionally be replaced with `discover_client_host=yes`
    # Add `start_with_request=yes` to start debug session on each request
    echo "xdebug.client_host = host.docker.internal" >> "${PHP_INI_DIR}/conf.d/99-docker.ini"; \
    \
    # Create the application user
    adduser -D -G www-data -u "${uid}" -h "/home/${user}" "${user}"; \
	\
    # Add additional capability to bind to port 80 and 443
	setcap CAP_NET_BIND_SERVICE=+eip /usr/local/bin/frankenphp; \
	\
    # Give write access to /data/caddy and /config/caddy
	chown -R ${uid}:${uid} \
      /config/caddy \
      /data/caddy \
    ; \
    \
    # Create the application folder
    mkdir -p /app; \
    cd /app; \
    # Install Chokidar to watch for file changes
    npm install --dev --quiet --no-progress chokidar

COPY --link --from=composer:latest /usr/bin/composer /usr/bin/composer

CMD ["--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]
HEALTHCHECK CMD curl -f http://localhost:2019/metrics || exit 1

ENV COMPOSER_ALLOW_SUPERUSER="1"

# Enables PHPStorm to apply the correct path mapping on Xdebug breakpoints
ENV PHP_IDE_CONFIG serverName=Docker

EXPOSE 80
EXPOSE 443
EXPOSE 443/udp
EXPOSE 2019
