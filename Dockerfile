FROM php:8-cli
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

COPY ./healthcheck.sh /usr/local/bin/healthcheck

RUN chmod o+x /usr/local/bin/healthcheck

# Configure the health check. This will query the RoadRunner status endpoint in
# a HTTP context, and simply exit with 0 otherwise. The command referred to
# below is copied from the "healthcheck.sh" script, so take a look at that, too.
# See https://roadrunner.dev/docs/beep-beep-health for more info.
HEALTHCHECK --interval=10s --timeout=3s \
  CMD ["sh", "/usr/local/bin/healthcheck"]

EXPOSE 9000
