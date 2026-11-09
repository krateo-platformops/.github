#!/usr/bin/env bash
# Downloads one GitHub release asset and its checksums file through `gh release download`,
# authenticated with the job's token, retrying ONLY when the failure is a transient network error,
# then verifies the asset's sha256 against the checksums file.
#
# Why: on 2026-11-09 GitHub timed out anonymous traffic ("Increased timeouts due to surge in
# anonymous users"). security.yml fetched gitleaks and syft anonymously, with no retry, so every
# download answered 504 and the filesystem and sbom jobs failed in authn and installer (5 runs)
# until someone re-ran them by hand. An authenticated request is not the traffic being shed, and a
# retry covers the rest.
#
# Why only transient errors: a missing tag or asset, or a checksum mismatch, is the truth. Retrying
# would only delay the same failure, so those fail on the first attempt.
#
# Env: RD_REPO (owner/name), RD_TAG, RD_ASSET, RD_CHECKSUMS (the checksums file's asset name),
#      RD_DIR (destination, created if needed), RD_ATTEMPTS (default 3),
#      RD_BACKOFF (seconds, multiplied by the attempt number; default 10),
#      RD_GH (the gh command; default gh, replaced by a stub in the tests).
#      GH_TOKEN must be set for gh to authenticate.
set -uo pipefail

repo="${RD_REPO:?RD_REPO is required}"
tag="${RD_TAG:?RD_TAG is required}"
asset="${RD_ASSET:?RD_ASSET is required}"
sums="${RD_CHECKSUMS:?RD_CHECKSUMS is required}"
dir="${RD_DIR:?RD_DIR is required}"
attempts="${RD_ATTEMPTS:-3}"
backoff="${RD_BACKOFF:-10}"
gh="${RD_GH:-gh}"

# Signatures of network failures that a retry can fix. Keep this list narrow: anything not
# matched here fails immediately.
transient='HTTP 50[0234]|50[234] (Bad Gateway|Service Unavailable|Gateway Timeout)|connection reset by peer|i/o timeout|TLS handshake timeout|unexpected EOF|error connecting to'

mkdir -p "$dir"
log="$(mktemp)"
trap 'rm -f "$log"' EXIT

attempt=1
while :; do
  "$gh" release download "$tag" --repo "$repo" --pattern "$asset" --pattern "$sums" \
    --dir "$dir" --clobber 2>&1 | tee "$log"
  rc=${PIPESTATUS[0]}
  if [ "$rc" -eq 0 ]; then
    break
  fi
  if ! grep -Eq "$transient" "$log"; then
    echo "::error::downloading $asset from $repo $tag failed (exit $rc) with an error that is not a transient network failure; not retrying." >&2
    exit "$rc"
  fi
  if [ "$attempt" -ge "$attempts" ]; then
    echo "::error::downloading $asset from $repo $tag still failed with a transient network error after $attempts attempts (exit $rc)." >&2
    exit "$rc"
  fi
  wait=$((backoff * attempt))
  echo "::warning::downloading $asset from $repo $tag hit a transient network error (attempt $attempt of $attempts); retrying in ${wait}s." >&2
  sleep "$wait"
  attempt=$((attempt + 1))
done

# gh succeeds when ANY pattern matches, so a release without the asset (but with its checksums
# file) "downloads" fine: check that the asset itself arrived.
if [ ! -f "$dir/$asset" ]; then
  echo "::error::$repo $tag has no asset named $asset; not retrying." >&2
  exit 1
fi

# The checksums file lists every asset of the release; check exactly this one, and refuse a
# release whose checksums file doesn't name it rather than skip the check.
want="$(awk -v a="$asset" '$2 == a || $2 == "*" a { print $1; exit }' "$dir/$sums")"
if [ -z "$want" ]; then
  echo "::error::$sums has no sha256 line for $asset; refusing an unverified binary." >&2
  exit 1
fi
got="$(sha256sum "$dir/$asset" | cut -d' ' -f1)"
if [ "$got" != "$want" ]; then
  echo "::error::$asset has sha256 $got, but $sums says $want; refusing it." >&2
  exit 1
fi
echo "verified $asset from $repo $tag against $sums"
