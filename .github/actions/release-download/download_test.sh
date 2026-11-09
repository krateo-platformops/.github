#!/usr/bin/env bash
# Tests download.sh with a stub gh; no network needed. Run: bash download_test.sh
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail=0

asset=tool_1.0.0_linux_x64.tar.gz
sums=tool_1.0.0_checksums.txt

# A stub gh that fails N times with a given message, then "downloads": it writes the asset and a
# checksums file into --dir. $4 picks what the checksums file says about the asset:
# good (its real sha256), bad (a wrong one) or missing (no line for it); gone writes only the
# checksums file, as gh does when one of two patterns matches nothing. Counts its calls.
stub() { # $1=name $2=failures-before-success $3=message $4=good|bad|missing
  cat > "$tmp/$1" <<EOF
#!/usr/bin/env bash
n=\$(cat "$tmp/$1.count" 2>/dev/null || echo 0); n=\$((n+1)); echo "\$n" > "$tmp/$1.count"
if [ "\$n" -le $2 ]; then echo "$3" >&2; exit 1; fi
while [ \$# -gt 0 ]; do [ "\$1" = --dir ] && dir="\$2"; shift; done
[ "$4" = gone ] || printf 'binary' > "\$dir/$asset"
sum=\$(printf 'binary' | sha256sum | cut -d' ' -f1)
case "$4" in
  good|gone) printf '%s  %s\n%s  other.tar.gz\n' "\$sum" "$asset" "\$sum" > "\$dir/$sums" ;;
  bad)     printf '%s  %s\n' "\$(printf other | sha256sum | cut -d' ' -f1)" "$asset" > "\$dir/$sums" ;;
  missing) printf '%s  other.tar.gz\n' "\$sum" > "\$dir/$sums" ;;
esac
EOF
  chmod +x "$tmp/$1"
}

check() { # $1=case $2=stub $3=want-exit(0|nonzero) $4=want-calls
  local rc calls
  RD_GH="$tmp/$2" RD_REPO=o/tool RD_TAG=v1.0.0 RD_ASSET="$asset" RD_CHECKSUMS="$sums" \
    RD_DIR="$tmp/$2.dir" RD_ATTEMPTS=3 RD_BACKOFF=0 \
    bash "$here/download.sh" >"$tmp/$2.out" 2>&1
  rc=$?
  calls=$(cat "$tmp/$2.count")
  if { [ "$3" = 0 ] && [ "$rc" -ne 0 ]; } || { [ "$3" != 0 ] && [ "$rc" -eq 0 ]; } || [ "$calls" -ne "$4" ]; then
    echo "FAIL $1: exit=$rc calls=$calls (want exit $3, calls $4)"; sed 's/^/    /' "$tmp/$2.out"; fail=1
  else
    echo "ok   $1: exit=$rc calls=$calls"
  fi
}

gw='HTTP 504: 504 Gateway Timeout (https://api.github.com/repos/o/tool/releases/assets/1)'
reset='Get "https://objects.githubusercontent.com/...": read tcp 10.1.0.4:443: connection reset by peer'
notag='release not found'
noasset='no assets match the file pattern'
denied='HTTP 401: Bad credentials (https://api.github.com/repos/o/tool/releases/tags/v1.0.0)'

stub pass 0 ""             good    ; check "succeeds first time"                  pass     0 1
stub flake1 1 "$gw"        good    ; check "504 once, then succeeds"              flake1   0 2
stub flake2 2 "$reset"     good    ; check "reset twice, then succeeds"           flake2   0 3
stub flakeall 9 "$gw"      good    ; check "504 every time: gives up after 3"     flakeall 1 3
stub notag 9 "$notag"      good    ; check "missing tag: no retry"                notag    1 1
stub noasset 9 "$noasset"  good    ; check "missing asset: no retry"              noasset  1 1
stub denied 9 "$denied"    good    ; check "bad token: no retry"                  denied   1 1
stub gone 0 ""             gone    ; check "only the checksums arrived: refused"  gone     1 1
stub badsum 0 ""           bad     ; check "checksum mismatch: refused"           badsum   1 1
stub nosum 0 ""            missing ; check "asset not in checksums: refused"      nosum    1 1

exit "$fail"
