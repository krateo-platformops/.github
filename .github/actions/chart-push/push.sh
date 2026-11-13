#!/usr/bin/env bash
# Pushes one packaged Helm chart with `helm push`, retrying ONLY ghcr.io's transient failure to tag
# a manifest it has just accepted:
#
#   Error: failed to perform "Tag" on destination: sha256:<digest>: not found
#
# Why: the upload succeeds and the registry then cannot find the manifest it just stored when helm
# tags it (read-after-write). On 2026-11-13 it failed dashboard-page in portal 1.8.115 and 1.8.116
# (17 of 18 charts published), and earlier frontend 1.8.40 and portal 1.8.89, each fixed only by
# re-running the job by hand. Pushing the same .tgz again is idempotent: the same bytes give the same
# digest, so a retry tags exactly what the first attempt uploaded and never re-stamps a version.
#
# Why only that error: a refused push (denied, a name the token cannot write, an invalid chart) is the
# truth, and retrying would only delay the same failure, so anything else fails on the first attempt.
#
# Usage: push.sh <chart.tgz> <oci://host/path>
# Env:   CP_ATTEMPTS (total attempts, default 3), CP_BACKOFF (seconds, multiplied by the attempt
#        number; default 10), CP_HELM (the helm command; default helm, replaced by a stub in the tests).
set -uo pipefail

tgz="${1:?usage: push.sh <chart.tgz> <oci://host/path>}"
repo="${2:?usage: push.sh <chart.tgz> <oci://host/path>}"
attempts="${CP_ATTEMPTS:-3}"
backoff="${CP_BACKOFF:-10}"
helm="${CP_HELM:-helm}"

# The one signature a retry can fix. Keep it exact: anything not matched fails immediately.
transient='failed to perform "Tag" on destination: sha256:[0-9a-f]{64}: not found'

log="$(mktemp)"
trap 'rm -f "$log"' EXIT

attempt=1
while :; do
  "$helm" push "$tgz" "$repo" 2>&1 | tee "$log"
  rc=${PIPESTATUS[0]}
  [ "$rc" -eq 0 ] && exit 0
  if ! grep -Eq "$transient" "$log"; then
    echo "::error::pushing $(basename "$tgz") failed (exit $rc) with an error that is not the registry's transient tag failure; not retrying." >&2
    exit "$rc"
  fi
  if [ "$attempt" -ge "$attempts" ]; then
    echo "::error::pushing $(basename "$tgz") still hit the registry's transient tag failure after $attempts attempts (exit $rc)." >&2
    exit "$rc"
  fi
  wait=$((backoff * attempt))
  echo "::warning::pushing $(basename "$tgz") hit the registry's transient tag failure (attempt $attempt of $attempts); retrying in ${wait}s." >&2
  sleep "$wait"
  attempt=$((attempt + 1))
done
