#!/usr/bin/env bash
# Tests retry.sh with stub commands; no network or Go needed. Run: bash retry_test.sh
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail=0

# A stub that fails N times with a given message, then succeeds. Counts its calls.
stub() { # $1=name $2=failures-before-success $3=message
  cat > "$tmp/$1" <<EOF
#!/usr/bin/env bash
n=\$(cat "$tmp/$1.count" 2>/dev/null || echo 0); n=\$((n+1)); echo "\$n" > "$tmp/$1.count"
if [ "\$n" -le $2 ]; then echo "$3" >&2; exit 1; fi
echo ok
EOF
  chmod +x "$tmp/$1"
}

check() { # $1=case $2=stub $3=want-exit $4=want-calls
  local rc calls
  GO_DOWNLOAD_RUN="$tmp/$2" GO_DOWNLOAD_ATTEMPTS=3 GO_DOWNLOAD_BACKOFF=0 \
    bash "$here/retry.sh" >"$tmp/$2.out" 2>&1
  rc=$?
  calls=$(cat "$tmp/$2.count")
  if { [ "$3" = 0 ] && [ "$rc" -ne 0 ]; } || { [ "$3" != 0 ] && [ "$rc" -eq 0 ]; } || [ "$calls" -ne "$4" ]; then
    echo "FAIL $1: exit=$rc calls=$calls (want exit $3, calls $4)"; sed 's/^/    /' "$tmp/$2.out"; fail=1
  else
    echo "ok   $1: exit=$rc calls=$calls"
  fi
}

stream='go: go.opentelemetry.io/otel@v1.46.0: read "https://proxy.golang.org/go.opentelemetry.io/otel/@v/v1.46.0.zip": stream error: stream ID 489; INTERNAL_ERROR; received from peer'
toolchain='go: switching to go >= 1.26.0: module golang.org/toolchain: read "https://proxy.golang.org/golang.org/toolchain/@v/list": stream error: stream ID 19; INTERNAL_ERROR; received from peer'
real='go: golang.org/x/vuln@v1.9.0 requires go >= 1.26.0 (running go 1.24.0; GOTOOLCHAIN=local)'
missing='go: example.com/nope@v1.0.0: reading https://proxy.golang.org/example.com/nope/@v/v1.0.0.info: 404 Not Found'

stub pass 0 ""                 ; check "succeeds first time"                    pass   0 1
stub flake1 1 "$stream"        ; check "transient once, then succeeds"          flake1 0 2
stub flake2 2 "$toolchain"     ; check "transient twice (toolchain), then ok"   flake2 0 3
stub flakeall 9 "$stream"      ; check "transient every time: gives up after 3" flakeall 1 3
stub realerr 9 "$real"         ; check "real error: no retry"                   realerr 1 1
stub notfound 9 "$missing"     ; check "404 module: no retry"                   notfound 1 1

exit "$fail"
