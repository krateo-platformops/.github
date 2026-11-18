#!/usr/bin/env bash
# Push one packaged chart to an OCI registry, surviving GHCR's read-after-write race on the tag step and nothing else.
#
#   push.sh CHART.tgz oci://REGISTRY/PATH
#
# Chart pushes go through this file (krateo-blueprints/charts PUBLISHING.md rule 14): release-oci.yaml runs it through
# the chart-push action's `path` output, and a caller's own workflow through the action's push mode. It is krateo-blueprints/rabbitmq-operator-blueprint hack/push-chart.sh at commit
# e22d03a02714e892791710dfad4beb3c9be6fc80 (sha256 102f721a363388d31412b0cc420ac45a5a32e88aa7e40e40453c0028c36fba2b),
# adapted only where marked "ADAPTED" below. It replaces this action's earlier push.sh (1b398a48ff), which retried
# the same error blind, three times with a growing backoff, and never checked which digest the tag landed on.
#
# The race (on 2026-11-13 it failed dashboard-page in portal 1.8.115 and 1.8.116, and earlier frontend 1.8.40 and
# portal 1.8.89; on 2026-11-18 the keycloak KOG 0.11.0 release and rabbitmq-operator-blueprint's first prerelease.yaml
# run, 44279368853). `helm push` (oras-go ExtendedCopy) PUTs the manifest by digest, then tags it, and the tag
# step first GETs that manifest by digest. GHCR answered that GET 404 about one second after accepting the PUT, so helm
# exits with
#     Error: failed to perform "Tag" on destination: sha256:<digest>: not found
# and leaves an untagged manifest behind. Measured for run 44279368853: the GHCR versions API listed exactly one
# version of charts/rabbitmq-cluster-operator, the untagged sha256:64960ed5..., created 09:48:36Z, the second helm
# failed; a GET of that digest returned 200 a minute later.
#
# On that exact error only, this script polls until the registry serves the manifest at that digest (bounded:
# PUSH_POLL_ATTEMPTS x PUSH_POLL_INTERVAL seconds, default 10 x 3), then pushes the SAME archive again. The second
# push has the same manifest digest: helm builds the manifest from the archive bytes, Chart.yaml and the archive's
# modification time (pkg/pusher/ocipusher.go PushOptCreationTime: ctime.Modified in v3.19.0, the version release-oci
# sets up, and stat.ModTime in v4), none of which changed, so its PUT is idempotent and
# its tag lands on the digest already there. The script checks that: a second push reporting another digest fails.
# Any other push error fails at once, unretried; a digest still unfetchable after the bound fails, saying so.
#
# Reading the manifest uses the registry's own token challenge (WWW-Authenticate: Bearer realm=...), with
# REGISTRY_USERNAME and REGISTRY_PASSWORD as credentials when set (anonymous otherwise), and checks the body hashes to
# the digest. The credentials and the token reach curl as a config on its stdin (`-K -`), never on its command line,
# where every process in the job could read them (/proc/<pid>/cmdline, ps); they go only to a token service on the
# registry's own host. guard.sh, beside chart-version-guard, follows the same two rules. push_test.py, beside this
# file, drives this script with stand-in helm and curl.
set -euo pipefail

die() { echo "::error::$*" >&2; exit 1; }

tgz="${1:-}" repo="${2:-}"
[ -f "$tgz" ] || die "usage: $0 CHART.tgz oci://REGISTRY/PATH (no archive at '${tgz}')"
[[ "$repo" == oci://*/* ]] || die "usage: $0 CHART.tgz oci://REGISTRY/PATH (got '${repo}')"
attempts="${PUSH_POLL_ATTEMPTS:-10}" interval="${PUSH_POLL_INTERVAL:-3}"
# A line break in a credential would end its curl config line and start another option there.
case "${REGISTRY_USERNAME:-}${REGISTRY_PASSWORD:-}" in
  *$'\n'* | *$'\r'*) die "REGISTRY_USERNAME or REGISTRY_PASSWORD contains a line break; refusing it" ;;
esac

# ADAPTED: the source piped `tar -tzf` into `head -n1`. Under pipefail, tar killed by SIGPIPE once head exits makes the
# assignment fail and set -e end the script with no message, on an archive whose listing outgrows one write. awk reads
# the whole listing, so tar is never cut off; an archive tar cannot read fails saying so, not silently.
name="$(tar -tzf "$tgz" | awk -F/ 'NR == 1 { print $1 }')" || die "${tgz} is not a readable chart archive"
[ -n "$name" ] || die "${tgz} has no top-level chart directory"
host="${repo#oci://}"; path="${host#*/}/${name}"; host="${host%%/*}"

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

RACE='failed to perform "Tag" on destination: sha256:[0-9a-f]{64}: not found'

sha256_of() {
  if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# One curl config line, KEY = "VALUE", with \ and " escaped (curl's -K syntax).
cfg_line() { local s="${2//\\/\\\\}"; s="${s//\"/\\\"}"; printf '%s = "%s"\n' "$1" "$s"; }
# The `user` line for user $1 and password $2; they are joined here, never on a command line.
cfg_user() { cfg_line user "$1:$2"; }

# 0 when the registry serves a manifest whose bytes hash to $1.
fetchable() {
  local digest="$1" url="https://${host}/v2/${path}/manifests/${1}" challenge realm rhost service scope token conf=""
  challenge="$(curl -sS -o /dev/null -D - "$url" | tr -d '\r' | grep -i '^www-authenticate: Bearer ' || true)"
  if [ -n "$challenge" ]; then
    realm="$(sed -n 's/.*realm="\([^"]*\)".*/\1/p' <<<"$challenge")"
    service="$(sed -n 's/.*service="\([^"]*\)".*/\1/p' <<<"$challenge")"
    scope="$(sed -n 's/.*scope="\([^"]*\)".*/\1/p' <<<"$challenge")"
    [ -n "$realm" ] || return 1
    rhost="${realm#*://}"; rhost="${rhost%%/*}"
    local cred="" send=1
    # ADAPTED: this repository's credential names (release-oci.yaml and chart-version-guard set them), not the source's
    # REGISTRY_USER and REGISTRY_TOKEN. The source put them on curl's command line (`-u user:password`); here they go
    # on its stdin, and only to a realm on the registry's own host.
    # BEGIN realm-host (push_test.py deletes this block to prove its cases see it)
    [ "$rhost" = "$host" ] || send=0
    # END realm-host
    if [ "$send" = 1 ] && [ -n "${REGISTRY_PASSWORD:-}" ]; then
      cred="$(cfg_user "${REGISTRY_USERNAME:-token}" "${REGISTRY_PASSWORD}")"
    fi
    token="$(printf '%s\n' "$cred" | curl -fsS -K - -G "$realm" --data-urlencode "service=${service}" \
      --data-urlencode "scope=${scope:-repository:${path}:pull}" | sed -n 's/.*"token" *: *"\([^"]*\)".*/\1/p')" || return 1
    [ -n "$token" ] || return 1
    conf="$(cfg_line header "Authorization: Bearer ${token}")"
  fi
  printf '%s\n' "$conf" | curl -fsS -K - \
    -H 'Accept: application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
    -o "$work/manifest" "$url" 2>/dev/null || return 1
  [ "sha256:$(sha256_of "$work/manifest")" = "$digest" ]
}

if helm push "$tgz" "$repo" >"$work/first" 2>&1; then
  cat "$work/first"
  exit 0
fi
cat "$work/first" >&2

# Capture, then match: no reader that stops early sits on a pipe (under pipefail its producer's SIGPIPE would be the
# pipeline's status). Here `|| true` already kept head's line, so this is the form, not a behaviour change.
races="$(grep -oE "$RACE" "$work/first" || true)"
orphan="$(grep -m1 -oE 'sha256:[0-9a-f]{64}' <<<"$races" || true)"
[ -n "$orphan" ] || die "helm push ${tgz} failed, and not with GHCR's tag read-after-write race; not retrying"

echo "::warning::helm push ${name}: the registry accepted manifest ${orphan} but 404'd reading it back to tag it (GHCR read-after-write race). Waiting for it to be served, then tagging that digest."
served=""
for i in $(seq 1 "$attempts"); do
  if fetchable "$orphan"; then served=$i; break; fi
  echo "poll ${i}/${attempts}: ${host}/${path}@${orphan} not served yet"
  [ "$i" -lt "$attempts" ] && sleep "$interval"
done
[ -n "$served" ] \
  || die "${host}/${path}@${orphan} was still not served after ${attempts} polls ${interval}s apart; it is untagged in the registry. Not tagging blind."
echo "${host}/${path}@${orphan} served on poll ${served}; pushing the same archive again to tag that digest"

helm push "$tgz" "$repo" >"$work/second" 2>&1 || { cat "$work/second" >&2; die "the second push of ${tgz} failed too"; }
cat "$work/second"
# Capture, then take the first: `sed ... | head -n1` fails the assignment, and set -e ends the script with no message,
# when head exits before sed has written everything (push_test.py case "longrace").
digests="$(sed -n 's/^Digest: \(sha256:[0-9a-f]\{64\}\)$/\1/p' "$work/second")"
again="$(sed -n 1p <<<"$digests")"
[ "$again" = "$orphan" ] \
  || die "the second push of ${tgz} reported digest '${again}', not ${orphan}: the archive changed between pushes, so the tag is not on the manifest first pushed"
