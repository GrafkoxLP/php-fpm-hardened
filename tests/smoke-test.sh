#!/usr/bin/env bash
# Smoke tests for the hardened PHP-FPM image.
# Usage: tests/smoke-test.sh <image>
set -euo pipefail

IMAGE="${1:?usage: $0 <image>}"
failures=0

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }

run_php() { docker run --rm "$@"; }

# Compares an ini value (as returned by ini_get) against the expectation.
check_ini() {
  local key="$1" expected="$2" actual
  actual="$(run_php "$IMAGE" php -r "echo ini_get('$key');")"
  if [[ "$actual" == "$expected" ]]; then
    pass "$key = '$actual'"
  else
    fail "$key: expected '$expected', got '$actual'"
  fi
}

# Extensions
if run_php "$IMAGE" php -m | grep -qx 'pdo_mysql'; then
  pass "pdo_mysql loaded"
else
  fail "pdo_mysql not loaded"
fi

# Hardening values (ini_get returns "" for Off and "1" for On)
check_ini expose_php ""
check_ini allow_url_fopen ""
check_ini allow_url_include ""
check_ini file_uploads ""
check_ini session.upload_progress.enabled ""
check_ini session.cookie_secure "1"
check_ini session.cookie_httponly "1"
check_ini session.use_strict_mode "1"

disabled="$(run_php "$IMAGE" php -r "echo ini_get('disable_functions');")"
if [[ ",$disabled," == *",system,"* ]]; then
  pass "disable_functions contains system ($disabled)"
else
  fail "disable_functions does not contain system: '$disabled'"
fi

# open_basedir: default without env, overridable via PHP_OPEN_BASEDIR
check_ini open_basedir "/var/www/html:/tmp"
actual="$(run_php -e PHP_OPEN_BASEDIR=/srv/app:/tmp "$IMAGE" php -r "echo ini_get('open_basedir');")"
if [[ "$actual" == "/srv/app:/tmp" ]]; then
  pass "open_basedir overridable via PHP_OPEN_BASEDIR ($actual)"
else
  fail "open_basedir override: expected '/srv/app:/tmp', got '$actual'"
fi

# FPM configuration test
if out="$(run_php "$IMAGE" php-fpm -t 2>&1)"; then
  pass "php-fpm -t: $(echo "$out" | tail -n1)"
else
  fail "php-fpm -t failed: $out"
fi

# Start like in production and wait for FPM to become ready
cid="$(docker run -d \
  --read-only --tmpfs /tmp \
  --cap-drop ALL --security-opt no-new-privileges \
  --user 99:100 \
  -e PHP_OPEN_BASEDIR=/var/www/html:/tmp \
  "$IMAGE")"
trap 'docker rm -f "$cid" >/dev/null 2>&1 || true' EXIT

ready=0
for _ in $(seq 1 30); do
  if docker logs "$cid" 2>&1 | grep -q 'ready to handle connections'; then
    ready=1
    break
  fi
  if [[ "$(docker inspect -f '{{.State.Running}}' "$cid")" != "true" ]]; then
    break
  fi
  sleep 1
done
if [[ "$ready" == 1 ]]; then
  pass "container started with production flags and is ready to handle connections"
else
  fail "container did not become ready"
  docker logs "$cid" >&2 || true
fi

if (( failures > 0 )); then
  echo "$failures smoke test(s) failed" >&2
  exit 1
fi
echo "All smoke tests passed"
