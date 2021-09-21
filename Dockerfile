FROM php:8-cli AS base
LABEL maintainer="moritz@matchory.com"

# Arguments defined in docker-compose.yaml
ARG user="5000"
ARG uid="5000"

ENV REDIS_VERSION 5.3.4

# Opcache settings
ENV PHP_OPCACHE_ENABLE="1" \
    PHP_OPCACHE_VALIDATE_TIMESTAMPS="0" \
    PHP_OPCACHE_MAX_ACCELERATED_FILES="10000" \
    PHP_OPCACHE_MEMORY_CONSUMPTION="192" \
    PHP_OPCACHE_MAX_WASTED_PERCENTAGE="10"

# Install system dependencies
RUN set -eux; \
    apt-get update; \
    apt-get install --no-install-recommends -y \
      libonig-dev \
      libxml2-dev \
      libpng-dev \
      unzip \
      curl \
      git \
      zip; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

# Install PHP redis extension
RUN set -eux; \
    curl -L -o /tmp/redis.tar.gz https://github.com/phpredis/phpredis/archive/$REDIS_VERSION.tar.gz; \
    tar xfz /tmp/redis.tar.gz; \
    rm -r /tmp/redis.tar.gz; \
    mkdir -p /usr/src/php/ext; \
    mv phpredis-* /usr/src/php/ext/redis

# Install PHP extensions
RUN docker-php-ext-install \
    bcmath \
    mbstring \
    opcache \
    pcntl \
    pdo_mysql \
    redis \
    sockets

# Install the default production php.ini
RUN mv $PHP_INI_DIR/php.ini-production $PHP_INI_DIR/php.ini

# Copy custonm PHP settings
COPY php.ini $PHP_INI_DIR/conf.d/99-docker.ini

# Create the application user
RUN useradd -G www-data -u $uid -d /home/$user $user

EXPOSE 9000

FROM base AS dev
ENV BLACKFIRE_PORT 8707

# Enables PHPStorm to apply the correct path mapping on Xdebug breakpoints:
ENV PHP_IDE_CONFIG serverName=Docker

# Install blackfire
# Please note that the Blackfire Probe is dependent on the session module.
# If it isn't present in your install, you will need to enable it yourself.
RUN set -eux; \
    version=$(php -r "echo PHP_MAJOR_VERSION.PHP_MINOR_VERSION;"); \
    curl -A "Docker" -o /tmp/blackfire-probe.tar.gz -D - -L -s https://blackfire.io/api/v1/releases/probe/php/linux/amd64/$version; \
    mkdir -p /tmp/blackfire; \
    tar zxpf /tmp/blackfire-probe.tar.gz -C /tmp/blackfire; \
    mv /tmp/blackfire/blackfire-*.so $(php -r "echo ini_get ('extension_dir');")/blackfire.so; \
    printf "extension=blackfire.so\nblackfire.agent_socket=tcp://blackfire:${BLACKFIRE_PORT}\n" > $PHP_INI_DIR/conf.d/blackfire.ini; \
    rm -rf /tmp/blackfire /tmp/blackfire-probe.tar.gz

# Install and enable XDebug on your local dev environment
RUN set -eux; \
    pecl install xdebug; \
    docker-php-ext-enable xdebug

# Run as our application user
USER $user

FROM base AS prod
COPY ./healthcheck.sh /usr/local/bin/healthcheck

RUN chmod o+x /usr/local/bin/healthcheck

# Configure the health check. This will query the RoadRunner status endpoint in
# a HTTP context, and simply exit with 0 otherwise. The command referred to
# below is copied from the "healthcheck.sh" script, so take a look at that, too.
# See https://roadrunner.dev/docs/beep-beep-health for more info.
HEALTHCHECK --interval=10s --timeout=3s \
  CMD ["sh", "/usr/local/bin/healthcheck"]

# Run as our application user
USER $user
