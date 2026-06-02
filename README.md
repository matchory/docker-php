Docker PHP Base Images
======================

This repository contains the Dockerfiles for the PHP base images used by Matchory web applications. Images are published
to `ghcr.io/matchory/php`.

## Image Variants

| Variant        | Dockerfile              | Base Image           | Use Case                                    |
|----------------|-------------------------|----------------------|---------------------------------------------|
| **Standard**   | `Dockerfile`            | `php:*-cli` (Debian) | Default CLI image                           |
| **Alpine**     | `alpine.Dockerfile`     | `php:*-cli-alpine`   | Smaller image size                          |
| **FrankenPHP** | `frankenphp.Dockerfile` | `dunglas/frankenphp` | Web server with Caddy, Mercure, and Vulcain |

Each variant provides two build targets:

- **`dev`** — Includes Xdebug and Composer
- **`prod`** — Stripped-down, built `FROM scratch` for minimal size

## Quick Start

```bash
# Standard Debian image
docker build --target dev -t php:dev .
docker build --target prod -t php:prod .

# Alpine variant
docker build --target dev -f alpine.Dockerfile -t php:alpine-dev .

# FrankenPHP variant
docker build --target dev -f frankenphp.Dockerfile -t php:frankenphp-dev .

# Specify PHP version (default: 8.5)
docker build --build-arg PHP_VERSION=8.4 --target dev -t php:8.4-dev .
```

## Pre-installed Extensions

**Via PIE/PECL:**
redis, apcu, yaml, memcached (with session and JSON support), excimer, uv

**Swoole** (CLI variants only): Compiled with curl, pgsql, sqlite, sockets, openssl, iouring, and brotli support. Not included in the FrankenPHP variant, which uses FrankenPHP as its application server.

**Built-in PHP extensions:**
pdo_sqlite, pdo_pgsql, sockets, bcmath, pcntl, intl, zip, opcache

**Dev target only:**
Xdebug, Composer

## Environment Variables

### PHP Configuration

| Variable                  | Default        | Description                  |
|---------------------------|----------------|------------------------------|
| `PHP_MEMORY_LIMIT`        | `2G`           | Memory limit                 |
| `PHP_MAX_EXECUTION_TIME`  | `300`          | Max execution time (seconds) |
| `PHP_UPLOAD_MAX_FILESIZE` | `128M`         | Max upload file size         |
| `PHP_POST_MAX_SIZE`       | Same as upload | Max POST body size           |
| `PHP_ERROR_REPORTING`     | `E_ALL`        | Error reporting level        |
| `PHP_DISPLAY_ERRORS`      | `Off`          | Display errors in output     |

### OPcache

| Variable                            | Default (dev / prod) | Description                  |
|-------------------------------------|----------------------|------------------------------|
| `PHP_OPCACHE_ENABLE`                | `1`                  | Enable OPcache               |
| `PHP_OPCACHE_ENABLE_CLI`            | Same as enable       | Enable OPcache for CLI       |
| `PHP_OPCACHE_VALIDATE_TIMESTAMPS`   | `1` / `0`            | Revalidate scripts on change |
| `PHP_OPCACHE_MAX_ACCELERATED_FILES` | `10000`              | Max cached scripts           |
| `PHP_OPCACHE_MEMORY_CONSUMPTION`    | `192`                | OPcache memory (MB)          |
| `PHP_OPCACHE_MAX_WASTED_PERCENTAGE` | `10`                 | Restart threshold (%)        |

### FrankenPHP-specific

The FrankenPHP variant uses a Caddyfile with Mercure and Vulcain enabled. Configure via:

| Variable                        | Default                   | Description                              |
|---------------------------------|---------------------------|------------------------------------------|
| `SERVER_NAME`                   | `localhost`               | Server hostname                          |
| `MERCURE_TRANSPORT_URL`         | `bolt:///data/mercure.db` | Mercure transport backend                |
| `MERCURE_PUBLISHER_JWT_KEY`     | —                         | JWT key for publishers                   |
| `MERCURE_SUBSCRIBER_JWT_KEY`    | —                         | JWT key for subscribers                  |
| `CADDY_GLOBAL_OPTIONS`          | —                         | Additional Caddy global config           |
| `CADDY_EXTRA_CONFIG`            | —                         | Additional Caddy site blocks             |
| `CADDY_SERVER_EXTRA_DIRECTIVES` | —                         | Extra directives inside the server block |
| `FRANKENPHP_CONFIG`             | —                         | Extra FrankenPHP directives              |

## Build Args

| Arg           | Default | Description                   |
|---------------|---------|-------------------------------|
| `PHP_VERSION` | `8.5`   | PHP version (`8.4`, `8.5`)    |
| `user`        | `php`   | Non-root username             |
| `uid`         | `900`   | UID/GID for the non-root user |

## Non-root User

All images create and run as user `php` (UID 900) by default. The `user` and `uid` build args apply when
building these base images themselves — the `USER` instruction is baked at that point, so passing
`--build-arg uid=...` to a *downstream* image build does not change the user it runs as. Downstream images
that need a different UID must create it and add their own `USER` instruction.

## Multi-stage Build Architecture

All Dockerfiles follow a consistent pattern:

1. **pie** — PIE (PHP Installer for Extensions) binary
2. **upstream** — Base PHP image with runtime dependencies
3. **builder** — Compiles PHP extensions (Debian variants) or included in base (Alpine)
4. **base** — Non-root user setup, copies compiled extensions and custom `php.ini`
5. **dev** — Adds Xdebug and Composer on top of base
6. **prod-pre** — Strips build tools, dev packages, and caches
7. **prod** — `FROM scratch` with only the final filesystem for minimal image size

## CI/CD

GitHub Actions builds and pushes all variants on:

- **Push to `main`** — Always builds
- **Weekly schedule** (Mondays 03:00 UTC) — Only rebuilds if upstream base images have changed

Images are built for `linux/amd64` and `linux/arm64`, with SBOM and provenance attestations.

### Image Tags

Images are tagged as:

```
ghcr.io/matchory/php:<version>[-<variant>][-dev]
```

Examples:

- `ghcr.io/matchory/php:8.4` — Standard Debian, production
- `ghcr.io/matchory/php:8.4-dev` — Standard Debian, development
- `ghcr.io/matchory/php:8.4-alpine` — Alpine, production
- `ghcr.io/matchory/php:8.4-alpine-dev` — Alpine, development
- `ghcr.io/matchory/php:8.4-frankenphp` — FrankenPHP, production
- `ghcr.io/matchory/php:8.4-frankenphp-dev` — FrankenPHP, development
