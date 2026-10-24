# php-fpm-hardened

[![Build](https://github.com/GrafkoxLP/php-fpm-hardened/actions/workflows/build.yml/badge.svg)](https://github.com/GrafkoxLP/php-fpm-hardened/actions/workflows/build.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Hardened PHP-FPM image based on the official `php:8.5-fpm-alpine`, with `pdo_mysql`
and a restrictive PHP/FPM configuration. It is rebuilt automatically **only** when the
official base image changes (or this repository changes), so a tag only moves when there
is something new to deploy.

```
ghcr.io/grafkoxlp/php-fpm-hardened:8.5
```

The image is meant to run behind a separate web server (e.g.
[`nginxinc/nginx-unprivileged`](https://hub.docker.com/r/nginxinc/nginx-unprivileged))
that talks to it via FastCGI on port 9000.

## Tags

| Tag              | Meaning                                              |
|------------------|------------------------------------------------------|
| `8.5`            | Latest build of the PHP 8.5 line (recommended)       |
| `8.5.x`          | Full PHP version of the build (e.g. `8.5.12`)        |
| `latest`         | Same as `8.5`                                        |

Only `linux/amd64` is published.

## Hardening

### PHP ([`conf/zz-hardening.ini`](conf/zz-hardening.ini))

Applied on top of `php.ini-production`.

| Setting | Value | Why |
|---|---|---|
| `expose_php` | `Off` | No `X-Powered-By` header revealing the PHP version. |
| `display_errors` / `log_errors` | `Off` / `On` | Errors go to the log, never to the client. |
| `allow_url_fopen` / `allow_url_include` | `Off` | Blocks remote file access via `http://` wrappers (SSRF, remote code inclusion). |
| `file_uploads` | `Off` | Removes the file-upload attack surface entirely. |
| `session.upload_progress.enabled` | `Off` | Not needed without uploads; also closes the attack path used by PHP2Shell (CVE-2026-109619). |
| `session.save_path` | `/tmp` | Sessions live on the tmpfs; the root filesystem stays read-only. |
| `session.use_strict_mode` | `1` | Rejects uninitialized session IDs (session fixation). |
| `session.cookie_httponly` / `cookie_secure` / `cookie_samesite` | `1` / `1` / `Lax` | Session cookie is not readable by JavaScript, only sent over HTTPS and not on cross-site subrequests. |
| `open_basedir` | `${PHP_OPEN_BASEDIR:-/var/www/html:/tmp}` | Scripts can only access the document root and `/tmp`; configurable via environment. |
| `disable_functions` | `exec,passthru,shell_exec,system,proc_open,popen,pcntl_exec` | A code injection cannot easily be turned into a shell. |
| `memory_limit` / `post_max_size` | `128M` / `2M` | Bounds per-request resource usage. |

> [!WARNING]
> `open_basedir` falls back to `/var/www/html:/tmp` only if `PHP_OPEN_BASEDIR` is
> **unset**. If the variable is set but **empty** (e.g. `PHP_OPEN_BASEDIR=` or
> `PHP_OPEN_BASEDIR: ""` in Compose), PHP uses the empty value and **`open_basedir` is
> disabled**. Either leave the variable out or set it to a non-empty path list.

### PHP-FPM pool ([`conf/zz-pool.conf`](conf/zz-pool.conf))

| Setting | Why |
|---|---|
| `pm = dynamic`, `max_children = 10`, small spare range | Bounded number of workers for a small server. |
| `pm.max_requests = 500` | Workers are recycled regularly, limiting the impact of leaks. |
| `clear_env = yes` | Workers do not inherit the container environment (no secrets leaking into `getenv()`). |
| `security.limit_extensions = .php` | FPM refuses to execute anything that is not a `.php` file. |

### Image / runtime

- Default user is `www-data` instead of root; deployments can override it (e.g. `user: "99:100"`).
- Designed for and tested with `read_only`, a tmpfs on `/tmp`, `cap_drop: [ALL]`,
  `no-new-privileges` and an arbitrary non-root UID/GID.
- No ports are published: the container should only be reachable from the web server over an
  internal Docker network.

## Usage

A complete example lives in [`examples/`](examples/):

- [`examples/docker-compose.yml`](examples/docker-compose.yml) – nginx-unprivileged + this
  image (+ an example database) on separate internal networks, with all hardening options.
- [`examples/nginx/default.conf`](examples/nginx/default.conf) – minimal nginx config for a
  PHP application.

The relevant part for the PHP container:

```yaml
services:
  nginx:
    image: nginxinc/nginx-unprivileged:stable-alpine
    volumes:
      - ./app:/var/www/html:ro
      - ./nginx/default.conf:/etc/nginx/conf.d/default.conf:ro
    read_only: true
    tmpfs: [/tmp]
    cap_drop: [ALL]
    security_opt: [no-new-privileges:true]
    networks: [frontend, fastcgi]

  php:
    image: ghcr.io/grafkoxlp/php-fpm-hardened:8.5
    user: "99:100"
    environment:
      PHP_OPEN_BASEDIR: /var/www/html:/tmp
    volumes:
      - ./app:/var/www/html:ro
    read_only: true
    tmpfs: [/tmp]
    cap_drop: [ALL]
    security_opt: [no-new-privileges:true]
    networks: [fastcgi]

networks:
  frontend: {}
  fastcgi:
    internal: true
```

nginx and PHP-FPM must see the application under the same path (`/var/www/html`), because
nginx passes `SCRIPT_FILENAME` to FPM.

For front-controller apps (Laravel, Symfony, …), the nginx example also contains a commented-out,
stricter variant that only passes `/index.php` to PHP-FPM and answers every other `.php` request with 404.

### Local overrides

Mount an additional ini file named `zzz-local.ini`; it is loaded after the image's
`zz-hardening.ini` and therefore wins:

```yaml
    volumes:
      - ./zzz-local.ini:/usr/local/etc/php/conf.d/zzz-local.ini:ro
```

```ini
; zzz-local.ini
memory_limit = 256M
post_max_size = 8M
```

Keep in mind that every relaxation (e.g. re-enabling `file_uploads`) weakens the hardening.
Pool settings can be overridden the same way with a file in `/usr/local/etc/php-fpm.d/`
that sorts after `zz-pool.conf`.

## How updates work

The [build workflow](.github/workflows/build.yml) runs daily, on pushes to `main` that touch
the image, and manually via *Run workflow* (with an optional `force` input).

1. **Check** – Resolves the current index digest (manifest list) of
   `docker.io/library/php:8.5-fpm-alpine` and compares it with the
   `org.opencontainers.image.base.digest` label of the published
   `ghcr.io/grafkoxlp/php-fpm-hardened:8.5`. If they match (and the run was neither a push
   nor forced), the run ends with *Base unchanged – skipping build*.
2. **Build** – The base image is pinned by that digest (`PHP_BASE=php:8.5-fpm-alpine@sha256:…`),
   so the label always matches the base that was actually used. The image gets OCI labels
   (`base.name`, `base.digest`, `source`, `revision`, `created`, …).
3. **Test** – The image is loaded locally and smoke-tested
   ([`tests/smoke-test.sh`](tests/smoke-test.sh)): `pdo_mysql` is loaded, the hardening
   values are active, `open_basedir` defaults and overrides work, `php-fpm -t` passes and the
   container becomes ready with production-like flags (`--read-only`, tmpfs, `--cap-drop ALL`,
   `no-new-privileges`, `--user 99:100`). **If any test fails, nothing is pushed.**
4. **Push** – Exactly the tested image is tagged `8.5`, `8.5.x` and `latest` and pushed to GHCR.
5. **Scan** – A separate job scans the pushed image (by digest) with Trivy for fixable
   `CRITICAL`/`HIGH` vulnerabilities. It only has read access to packages and no registry
   login, so even a compromised scanner could not push a tampered image. The scan is
   informational (non-blocking); results appear in the repository's *Security* tab.

All actions are pinned to full commit SHAs (with a version comment for Dependabot).

Because a new image is only pushed when something actually changed, tools that watch registry
digests (Watchtower, Arcane, Renovate, …) update the container exactly when the upstream image
received updates.

GitHub disables scheduled workflows in public repositories after 60 days without activity.
A small `keepalive` job re-enables the workflow via the GitHub API on each scheduled run, which
resets that timer without dummy commits.

GitHub Actions versions are kept up to date by [Dependabot](.github/dependabot.yml).

## Building locally

```sh
docker build -t php-fpm-hardened:local .
tests/smoke-test.sh php-fpm-hardened:local
```

## License

[MIT](LICENSE)
