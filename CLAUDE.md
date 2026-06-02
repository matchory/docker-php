# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This repository contains Dockerfiles for PHP base images used by Matchory web applications. It provides three variants of PHP images, each with `dev` and `prod` build targets.

## Image Variants

- **Dockerfile**: Standard Debian-based PHP CLI image (default)
- **alpine.Dockerfile**: Alpine-based PHP CLI image (smaller size)
- **frankenphp.Dockerfile**: FrankenPHP image with Caddy web server, Mercure, and Vulcain

## Build Commands

Build a specific variant and target:
```bash
# Standard Debian image (development)
docker build --target dev -t php:dev .

# Standard Debian image (production)
docker build --target prod -t php:prod .

# Alpine variant
docker build --target dev -f alpine.Dockerfile -t php:alpine-dev .

# FrankenPHP variant
docker build --target dev -f frankenphp.Dockerfile -t php:frankenphp-dev .
```

Specify PHP version (defaults to 8.5):
```bash
docker build --build-arg PHP_VERSION=8.4 --target dev -t php:8.4-dev .
```

## Architecture

### Multi-stage Build Pattern

All Dockerfiles follow a consistent multi-stage pattern:
1. **pie**: PIE (PHP Installer for Extensions) binary stage
2. **upstream**: Base PHP image with runtime dependencies
3. **builder**: Compiles PHP extensions (Debian images only)
4. **base**: Configures non-root user, copies extensions
5. **dev**: Development target with Xdebug and Composer
6. **prod-pre**: Strips build tools for production
7. **prod**: Final production image (FROM scratch for minimal size)

### Pre-installed Extensions

Extensions installed via PIE and PECL:
- redis, apcu, yaml, memcached, excimer, uv
- swoole (CLI variants only, with curl/pgsql/sqlite/iouring support)
- Built-in: pdo_sqlite, pdo_pgsql, sockets, bcmath, pcntl, intl, zip, opcache

### Configuration

- **php.ini**: Custom PHP settings with environment variable support for opcache, memory limits, etc.
- **Caddyfile**: FrankenPHP configuration with opt-in Mercure/Vulcain support via `CADDY_SERVER_IMPORTS=mercure` (frankenphp variant only)

### Environment Variables

Key runtime configuration via environment:
- `PHP_VERSION`: PHP version (8.4, 8.5)
- `PHP_MEMORY_LIMIT`, `PHP_MAX_EXECUTION_TIME`, `PHP_UPLOAD_MAX_FILESIZE`
- `PHP_OPCACHE_*`: OPcache tuning options

### Non-root User

All images run as user `php` (UID 900) by default. Override with build args `user` and `uid`.

## CI/CD

GitHub Actions workflow (`.github/workflows/docker.yaml`) builds and pushes images to `ghcr.io/matchory/php` on:
- Push to main
- Weekly schedule (Mondays 03:00 UTC) - only rebuilds if upstream base images changed