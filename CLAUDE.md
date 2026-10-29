# CLAUDE.md

- The three Dockerfiles are kept in parallel by hand. A change to extensions, ENV or stages usually belongs in all three (FrankenPHP has no Swoole). CI fails if `*_VERSION` pins differ between them.
- Pin versions as `ARG NAME="x"` with a `# renovate: datasource=... depName=... versioning=...` comment directly above. Renovate's dockerfile manager is off on purpose; the regex manager and the CI base-image check both read these ARG defaults.
- `prod` is `FROM scratch` and inherits no ENV. Re-declare any ENV that runtime or downstream images need (see `PHP_INI_DIR`, `LD_PRELOAD`).
- README is the user-facing docs: update its tables when you change build args, env vars or extensions.
