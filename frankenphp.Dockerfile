# syntax=docker/dockerfile:1.12
FROM dunglas/frankenphp:1.3.3-php8.3-alpine
LABEL org.opencontainers.image.title="Matchory PHP Web"
LABEL org.opencontainers.image.description="Matchory base image for PHP web apps"
LABEL org.opencontainers.image.url=https://matchory.com
LABEL org.opencontainers.image.source=https://bitbucket.org/matchory/php-web
LABEL org.opencontainers.image.licenses=MIT
LABEL org.opencontainers.image.vendor="Mathory GmbH"

ARG user="5000"
ARG uid="5000"

ARG APCU_VERSION=5.1.24
ARG REDIS_VERSION=6.1.0

# Opcache settings
ENV PHP_OPCACHE_ENABLE="1" \
    PHP_OPCACHE_VALIDATE_TIMESTAMPS="0" \
    PHP_OPCACHE_MAX_ACCELERATED_FILES="10000" \
    PHP_OPCACHE_MEMORY_CONSUMPTION="192" \
    PHP_OPCACHE_MAX_WASTED_PERCENTAGE="10"

# Persistent/Runtime dependencies
RUN apk add --no-cache \
        postgresql-client \
		gnu-libiconv \
        colordiff \
        libstdc++ \
		gettext \
		file \
		acl \
	;
# install gnu-libiconv and set LD_PRELOAD env to make iconv work fully on Alpine image.
# see https://github.com/docker-library/php/issues/240#issuecomment-763112749
ENV LD_PRELOAD /usr/lib/preloadable_libiconv.so

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
      yaml \
    ; \
    pecl clear-cache; \
    docker-php-ext-enable \
      opcache \
      excimer \
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
    ln -sf "${PHP_INI_DIR}/php.ini-production" "${PHP_INI_DIR}/php.ini"; \
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
      /data/caddy

CMD ["--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]
HEALTHCHECK CMD curl -f http://localhost:2019/metrics || exit 1

EXPOSE 80
EXPOSE 443
EXPOSE 443/udp
EXPOSE 2019
