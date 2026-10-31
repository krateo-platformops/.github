#!/usr/bin/env bash
# Runs a Go download command, retrying ONLY when its output shows a transient network failure.
#
# Why: proxy.golang.org occasionally drops a stream mid-download, e.g.
#   go: go.opentelemetry.io/otel@v1.46.0: read "https://proxy.golang.org/...zip":
#       stream error: stream ID 489; INTERNAL_ERROR; received from peer
# Each one red-ticked a job (and, through installer's pin-ci, blocked a release) until someone
# re-ran it by hand. Seen in oasgen-provider (3 times on 2026-10-30/31) and provider-runtime
# (2026-10-28, toolchain download).
#
# Why only transient errors: a missing module, a checksum mismatch, or "requires go >= X" is CI
# telling the truth. Retrying those would only delay the same red tick, so they fail on the first
# attempt, exactly as before.
#
# Env: GO_DOWNLOAD_RUN (the command, run with bash -c), GO_DOWNLOAD_ATTEMPTS (default 3),
#      GO_DOWNLOAD_BACKOFF (seconds, multiplied by the attempt number; default 10).
set -uo pipefail

cmd="${GO_DOWNLOAD_RUN:?GO_DOWNLOAD_RUN is required}"
attempts="${GO_DOWNLOAD_ATTEMPTS:-3}"
backoff="${GO_DOWNLOAD_BACKOFF:-10}"

# Signatures of network failures that a retry can fix. Keep this list narrow: anything not
# matched here fails immediately.
transient='stream error: stream ID [0-9]+; (INTERNAL_ERROR|PROTOCOL_ERROR|REFUSED_STREAM)|connection reset by peer|i/o timeout|TLS handshake timeout|unexpected EOF|502 Bad Gateway|503 Service Unavailable|504 Gateway Timeout'

log="$(mktemp)"
trap 'rm -f "$log"' EXIT

attempt=1
while :; do
  bash -c "$cmd" 2>&1 | tee "$log"
  rc=${PIPESTATUS[0]}
  if [ "$rc" -eq 0 ]; then
    exit 0
  fi
  if ! grep -Eq "$transient" "$log"; then
    echo "::error::'$cmd' failed (exit $rc) with an error that is not a transient network failure; not retrying." >&2
    exit "$rc"
  fi
  if [ "$attempt" -ge "$attempts" ]; then
    echo "::error::'$cmd' still failed with a transient network error after $attempts attempts (exit $rc)." >&2
    exit "$rc"
  fi
  wait=$((backoff * attempt))
  echo "::warning::'$cmd' hit a transient network error (attempt $attempt of $attempts); retrying in ${wait}s." >&2
  sleep "$wait"
  attempt=$((attempt + 1))
done
