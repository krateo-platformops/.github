#!/usr/bin/env bash
# Tests push.sh against a stub helm that answers a scripted sequence of outcomes.
# Run: bash push_test.sh   (needs only bash, grep and mktemp)
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail=0
TAG_ERR='Error: failed to perform "Tag" on destination: sha256:bede5a3ff3100643ad29366ed8a1773231c5eb7e30bbb7a473a0fd867c2bb18b: not found'

# A stub helm: each call consumes the next line of $tmp/plan ("ok", or "fail <exit> <message>") and
# appends its arguments to $tmp/calls.
cat >"$tmp/helm" <<'STUB'
#!/usr/bin/env bash
dir="$(dirname "$0")"
echo "$*" >>"$dir/calls"
line="$(head -n1 "$dir/plan")"; tail -n +2 "$dir/plan" >"$dir/plan.next"; mv "$dir/plan.next" "$dir/plan"
case "$line" in
  ok) echo "Pushed: ghcr.io/x/charts/demo:1.0.0"; exit 0 ;;
  fail\ *) set -- $line; code="$2"; shift 2; echo "$*" >&2; exit "$code" ;;
  *) echo "stub helm: no plan left" >&2; exit 99 ;;
esac
STUB
chmod +x "$tmp/helm"

check() { # $1=case $2=want exit $3=want calls; plan lines on stdin
  cat >"$tmp/plan"; : >"$tmp/calls"
  local rc=0
  CP_HELM="$tmp/helm" CP_BACKOFF=0 bash "$here/push.sh" "$tmp/demo-1.0.0.tgz" "oci://ghcr.io/x/charts" >"$tmp/out" 2>&1 || rc=$?
  local calls; calls="$(wc -l <"$tmp/calls" | tr -d ' ')"
  if [ "$rc" = "$2" ] && [ "$calls" = "$3" ] && grep -q 'push .*demo-1.0.0.tgz oci://ghcr.io/x/charts' "$tmp/calls"; then
    echo "ok   $1"
  else
    echo "FAIL $1: exit $rc (want $2), helm calls $calls (want $3)"; cat "$tmp/out"; fail=1
  fi
}

check "a clean push is one call" 0 1 <<<"ok"
printf 'fail 1 %s\nok\n' "$TAG_ERR" | check "the transient tag failure is retried, then the push succeeds" 0 2
printf 'fail 1 %s\nfail 1 %s\nok\n' "$TAG_ERR" "$TAG_ERR" | check "it is retried up to the attempt limit" 0 3
printf 'fail 1 %s\nfail 1 %s\nfail 1 %s\nok\n' "$TAG_ERR" "$TAG_ERR" "$TAG_ERR" | check "after 3 transient failures it fails with helm's exit" 1 3
printf 'fail 1 %s\nok\n' 'Error: failed to authorize: failed to fetch oauth token: unexpected status: 403 Forbidden' | check "a denied push fails on the first attempt" 1 1
printf 'fail 1 %s\nok\n' 'Error: failed to perform "Tag" on destination: denied' | check "a Tag failure that is not 'not found' is not retried" 1 1
printf 'fail 1 %s\nok\n' 'Error: chart.metadata.version "x" is invalid' | check "an invalid chart fails on the first attempt" 1 1
printf 'fail 7 %s\nok\n' "$TAG_ERR" | CP_ATTEMPTS=1 check "CP_ATTEMPTS=1 disables the retry and keeps helm's exit code" 7 1

exit "$fail"
