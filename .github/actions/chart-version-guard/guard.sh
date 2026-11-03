#!/usr/bin/env bash
# Decides whether a packaged Helm chart may be pushed to an OCI registry without replacing a
# published version with different contents. release-oci.yaml runs it before every push, and
# chart-version-guard.yaml runs it on a chart repo's pull requests.
#
#   Usage: guard.sh <chart.tgz> <oci://host/path>
#
# The package is looked up at <path>/<name>:<version>, read from its own Chart.yaml, which is
# where `helm push` would put it. The exit status is the verdict:
#
#   0   absent      not published: push it.
#   10  identical   published, same contents: do not push. The published artifact stays.
#   11  different   published, different contents: refuse. The chart needs a version bump.
#   any other       the check could not be completed. A caller must treat this as a failure,
#                   never as "absent": a registry that cannot answer has not said "push".
#
# Why: release-oci used to push every chart on every tag. observability tags 3.1.31 and 3.1.32
# both pushed krateo-observability:0.1.25 with identical files, and each push moved the tag to a
# new digest, because `helm package` stamps fresh mtimes. A chart whose files changed without a
# version bump replaced the published version just as silently (observability#87 nearly did this
# with krateo-sse-proxy 0.1.18).
#
# What "same contents" means: the files in the two packages, byte for byte, after removing what
# release-oci writes differently on every run:
#   - tar metadata (mtimes, owners, modes). Only file paths and contents are compared.
#   - the provenance annotations org.opencontainers.image.{revision,source,version,ref.name} in any
#     Chart.yaml (release-oci stamps the building commit and tag into them), and an annotations
#     map that removing them leaves empty.
#   - `generated:` in Chart.lock and requirements.lock (helm dependency update writes the time).
# Everything else counts, appVersion included: it selects the image a release deploys.
#
# The exclusion is checked, not trusted, so it can never make the comparison vacuous:
#   - it may remove only those lines. A file where it would remove anything else (a stamp key
#     with a multi-line value, say) stops the check.
#   - on each side, what is left must declare the chart's name and version, and must hold content
#     beyond them: name and version are the lookup key, equal by construction, so comparing only
#     them proves nothing. A package whose only content is the key plus the excluded fields stops
#     the check instead of comparing "identical".
# Stopping the check is the "could not check" verdict below, which a release treats as a failure.
#
# Registry access is the OCI distribution API, read-only: GET the manifest for the tag, then the
# chart layer's blob. 200 means published. 404 means absent ONLY when the body carries the
# registry error code MANIFEST_UNKNOWN or NAME_UNKNOWN. Any other answer (an auth refusal, a 5xx
# after curl's retries, a network error, a 404 that is not from a registry, an artifact that is
# not a Helm chart, a digest that does not match) ends the check with a non-verdict exit status.
#
# Env: REGISTRY_USERNAME / REGISTRY_PASSWORD, optional. They are sent only to the registry's own
#      host (for GHCR, that includes its token endpoint), never to a token realm or redirect
#      elsewhere. Without them the requests are anonymous.
#      The scheme is https, except plain http for a localhost registry, as helm does.
#
# Needs: bash, curl, jq, tar, awk, diff, and sha256sum or shasum.
set -uo pipefail
# Not `set -e`: an unexpected command failure must never become this script's exit status, since
# 10 or 11 from some command would read as a verdict. Every failure goes through fail().

readonly ABSENT=0 IDENTICAL=10 DIFFERENT=11 ERROR=2

pkg="${1:-}"
oci_repo="${2:-}"
ref=""

fail() {
  echo "::error::could not check ${ref:-${pkg}}: $*. Not treating it as unpublished." >&2
  exit "$ERROR"
}

[ -n "$pkg" ] && [ -n "$oci_repo" ] || fail "usage: guard.sh <chart.tgz> <oci://host/path>"
[ -f "$pkg" ] || fail "no such package file: $pkg"
case "$oci_repo" in oci://?*) ;; *) fail "OCI repo '$oci_repo' does not start with oci://" ;; esac

for t in curl jq tar awk diff; do
  command -v "$t" >/dev/null 2>&1 || fail "required tool '$t' is not installed"
done
if command -v sha256sum >/dev/null 2>&1; then sha256() { sha256sum "$1" | awk '{print $1}'; }
elif command -v shasum >/dev/null 2>&1; then sha256() { shasum -a 256 "$1" | awk '{print $1}'; }
else fail "neither sha256sum nor shasum is installed"; fi

tmp="$(mktemp -d)" || fail "mktemp failed"
trap 'rm -rf "$tmp"' EXIT
export LC_ALL=C

# --- the package being released ------------------------------------------------------------------

# Prints the single top-level directory of an extracted package (helm names it after the chart).
top_dir() {
  local n
  n="$(find "$1" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"
  [ "$n" = 1 ] && [ -d "$(find "$1" -mindepth 1 -maxdepth 1)" ] || return 1
  find "$1" -mindepth 1 -maxdepth 1
}

# A top-level scalar from helm-written YAML ("key: value"), with any quotes removed.
yaml_scalar() { # $1=file $2=key
  awk -v k="$2" 'index($0, k ": ") == 1 { print substr($0, length(k) + 3); exit }' "$1" | tr -d "\"'"
}

mkdir "$tmp/local" "$tmp/published" || fail "mkdir failed"
tar -xzf "$pkg" -C "$tmp/local" 2>"$tmp/tar.err" || fail "cannot extract $pkg: $(head -c 300 "$tmp/tar.err")"
local_top="$(top_dir "$tmp/local")" || fail "$pkg does not hold exactly one chart directory"
[ -f "$local_top/Chart.yaml" ] || fail "$pkg has no Chart.yaml"
name="$(yaml_scalar "$local_top/Chart.yaml" name)"
version="$(yaml_scalar "$local_top/Chart.yaml" version)"
[ -n "$name" ] && [ -n "$version" ] || fail "cannot read name and version from $pkg's Chart.yaml"

rest="${oci_repo#oci://}"
rest="${rest%/}"
host="${rest%%/*}"
path=""
[ "$rest" != "$host" ] && path="${rest#*/}"
repo="${path:+${path}/}${name}"
tag="${version//+/_}" # OCI tags cannot hold "+"; helm push writes it as "_"
ref="${host}/${repo}:${tag}"

case "$host" in
  localhost | localhost:* | 127.0.0.1 | 127.0.0.1:* | "[::1]" | "[::1]:"*) base="http://${host}" ;;
  *) base="https://${host}" ;;
esac

# --- registry access -----------------------------------------------------------------------------

# Values in a curl config file are double-quoted with backslash escapes. Credentials and tokens go
# through config files (mode 600), not the command line, where any process could read them.
cfg_quote() { local s="${1//\\/\\\\}"; s="${s//\"/\\\"}"; printf '"%s"' "$s"; }

user="${REGISTRY_USERNAME:-}"
pass="${REGISTRY_PASSWORD:-}"
auth="$tmp/auth.curlrc"
(umask 077 && : >"$auth") || fail "cannot create $auth"

# Prints the HTTP status of GET $1 (body to $2, headers to $tmp/headers). Returns curl's status.
# curl retries the transient answers (408, 429, 5xx, timeouts) itself before giving one back.
request() { # $1=url $2=out [$3=accept] [$4=curl config]
  local args=(-sS -L --proto '=http,https' --connect-timeout 10 --max-time 120
    --retry 3 --retry-delay 1 -o "$2" -D "$tmp/headers" -w '%{http_code}' -K "${4:-$auth}")
  [ -n "${3:-}" ] && args+=(-H "Accept: $3")
  curl "${args[@]}" "$1" 2>"$tmp/curl.err"
}

# The value of parameter $2 in a WWW-Authenticate challenge $1.
challenge_param() { printf '%s' "$1" | sed -n "s/.*[ ,]$2=\"\\([^\"]*\\)\".*/\\1/p"; }

# Answers a 401 by writing credentials for the retry into $auth.
authenticate() {
  local chal realm service scope rhost tcfg code token
  chal="$(tr -d '\r' <"$tmp/headers" | awk 'tolower($0) ~ /^www-authenticate:/ { sub(/^[^:]*:[ ]*/, ""); c = $0 } END { print c }')"
  case "$chal" in
    [Bb]earer\ *)
      realm="$(challenge_param "$chal" realm)"
      service="$(challenge_param "$chal" service)"
      scope="$(challenge_param "$chal" scope)"
      [ -n "$realm" ] || fail "the registry asked for a token without naming where to get one"
      rhost="${realm#*://}"
      rhost="${rhost%%/*}"
      tcfg="$tmp/token.curlrc"
      (umask 077 && : >"$tcfg") || fail "cannot create $tcfg"
      if [ -n "$user" ] && [ "$rhost" = "$host" ]; then
        printf 'user = %s\n' "$(cfg_quote "${user}:${pass}")" >"$tcfg"
      fi
      code="$(request "${realm}?service=$(jq -rn --arg v "$service" '$v|@uri')&scope=$(jq -rn --arg v "$scope" '$v|@uri')" \
        "$tmp/token.json" "" "$tcfg")" || fail "token request to $realm failed: $(head -c 300 "$tmp/curl.err")"
      [ "$code" = 200 ] || fail "token request to $realm answered HTTP $code: $(head -c 300 "$tmp/token.json")"
      token="$(jq -r '.token // .access_token // empty' "$tmp/token.json" 2>/dev/null)"
      [ -n "$token" ] || fail "token response from $realm carries no token"
      printf 'header = %s\n' "$(cfg_quote "Authorization: Bearer ${token}")" >"$auth"
      ;;
    [Bb]asic*)
      [ -n "$user" ] || fail "the registry requires credentials and REGISTRY_USERNAME is not set"
      printf 'user = %s\n' "$(cfg_quote "${user}:${pass}")" >"$auth"
      ;;
    *) fail "the registry answered 401 without a usable WWW-Authenticate challenge" ;;
  esac
}

# GET with at most one authentication round. Sets $code.
authed=0
get() { # $1=url $2=out [$3=accept]
  code="$(request "$@")" || fail "GET $1 failed: $(head -c 300 "$tmp/curl.err")"
  if [ "$code" = 401 ] && [ "$authed" = 0 ]; then
    authed=1
    authenticate
    code="$(request "$@")" || fail "GET $1 failed: $(head -c 300 "$tmp/curl.err")"
  fi
}

# --- does <repo>:<tag> exist? --------------------------------------------------------------------

get "${base}/v2/${repo}/manifests/${tag}" "$tmp/manifest.json" "application/vnd.oci.image.manifest.v1+json"
case "$code" in
  200) ;;
  404)
    errcodes="$(jq -r '[.errors[]?.code] | join(",")' "$tmp/manifest.json" 2>/dev/null)"
    case ",${errcodes}," in
      *,MANIFEST_UNKNOWN,* | *,NAME_UNKNOWN,*)
        echo "absent: ${ref} is not published"
        exit "$ABSENT"
        ;;
    esac
    fail "HTTP 404 without a registry error code (${errcodes:-body is not a registry error}); is ${base} an OCI registry?"
    ;;
  *) fail "HTTP ${code} for the manifest: $(head -c 300 "$tmp/manifest.json")" ;;
esac

manifest_digest="sha256:$(sha256 "$tmp/manifest.json")"
layer="$(jq -r '[.layers[]? | select(.mediaType == "application/vnd.cncf.helm.chart.content.v1.tar+gzip") | .digest]
                | if length == 1 then .[0] else empty end' "$tmp/manifest.json" 2>/dev/null)"
case "$layer" in
  sha256:*) ;;
  *) fail "the artifact at ${ref} (${manifest_digest}) is not a Helm chart: its manifest has no single chart layer" ;;
esac

get "${base}/v2/${repo}/blobs/${layer}" "$tmp/published.tgz"
[ "$code" = 200 ] || fail "HTTP ${code} for the chart layer ${layer}"
[ "sha256:$(sha256 "$tmp/published.tgz")" = "$layer" ] || fail "the chart layer downloaded from ${ref} does not match its digest ${layer}"

# --- compare contents ----------------------------------------------------------------------------

tar -xzf "$tmp/published.tgz" -C "$tmp/published" 2>"$tmp/tar.err" ||
  fail "cannot extract the published package: $(head -c 300 "$tmp/tar.err")"
published_top="$(top_dir "$tmp/published")" || fail "the published package does not hold exactly one chart directory"

# Drops the provenance annotations from helm-written Chart.yaml (two-space indentation, one key
# per line; a multi-line value continues on deeper-indented or blank lines), plus an annotations
# header left with no keys.
strip_provenance='
  inann && /^[^ ]/ { inann = 0; hdr = "" }
  inann {
    if ($0 ~ /^  [^ ]/) {
      skip = ($0 ~ /^  "?org\.opencontainers\.image\.(revision|source|version|ref\.name)"?:/)
      if (skip) next
      if (hdr != "") { print hdr; hdr = "" }
    } else if (skip) next
    print
    next
  }
  /^annotations:[ ]*$/ { inann = 1; hdr = $0; skip = 0; next }
  { print }
'
# The lines the exclusion may remove, as `diff` prints a removed line.
removable_chart='^< (  "?org\.opencontainers\.image\.(revision|source|version|ref\.name)"?:.*|annotations:[ ]*)$'
removable_lock='^< generated:.*$'

normalize() { # $1=dir $2=which side, for messages
  local f allowed extra
  while IFS= read -r -d '' f; do
    case "$(basename "$f")" in
      Chart.yaml) awk "$strip_provenance" "$f" >"$f.norm"; allowed="$removable_chart" ;;
      *) awk '!/^generated:/' "$f" >"$f.norm"; allowed="$removable_lock" ;;
    esac || fail "cannot normalize $f"
    # Every line the exclusion removed must be one it is allowed to remove. diff prints change
    # ranges (digits first) and removed lines ("<"); anything else would be an added line.
    extra="$(diff "$f" "$f.norm" | grep -v '^[0-9]' | grep -Ev "$allowed" | head -n 3)"
    [ -z "$extra" ] || fail "excluding the per-run fields from the $2 ${f#"$1"/} would also remove: ${extra}"
    mv "$f.norm" "$f" || fail "cannot normalize $f"
  done < <(find "$1" -type f \( -name Chart.yaml -o -name Chart.lock -o -name requirements.lock \) -print0)
}

# What is left to compare must be about this chart and must not be empty (see the header).
assert_comparable() { # $1=chart dir $2=which side
  local cy="$1/Chart.yaml" left
  [ -f "$cy" ] || fail "the $2 has no Chart.yaml"
  [ "$(yaml_scalar "$cy" name)" = "$name" ] && [ "$(yaml_scalar "$cy" version)" = "$version" ] ||
    fail "the $2's Chart.yaml does not declare ${name} ${version} (it declares '$(yaml_scalar "$cy" name)' '$(yaml_scalar "$cy" version)')"
  left="$(
    {
      grep -Ev '^(name|version):' "$cy"
      find "$1" -type f ! -path "$cy" -size +0 -print
    } | grep -c .
  )"
  [ "${left:-0}" -gt 0 ] ||
    fail "nothing is left to compare in the $2 once the per-run fields are excluded: it holds only the chart's name and version, which are the lookup key"
}

normalize "$published_top" "published chart"
normalize "$local_top" "package"
assert_comparable "$published_top" "published chart"
assert_comparable "$local_top" "package"

# Compare the chart directories under one name, so the report shows chart-relative paths.
mkdir "$tmp/cmp" && mv "$published_top" "$tmp/cmp/published" && mv "$local_top" "$tmp/cmp/package" ||
  fail "cannot stage the comparison"
(cd "$tmp/cmp" && diff -rq published package) >"$tmp/diff.q" 2>&1
rc=$?
if [ "$rc" = 0 ]; then
  echo "identical: ${ref} is already published (${manifest_digest}) with the same contents"
  exit "$IDENTICAL"
fi
[ "$rc" = 1 ] || fail "diff failed: $(head -c 300 "$tmp/diff.q")"

echo "::error::different: ${ref} is already published (${manifest_digest}) with different contents. A published chart version is immutable: bump 'version' in ${name}'s Chart.yaml."
echo "files that differ (published -> this package):"
awk '
  /^Files published\// { p = $2; sub(/^published\//, "", p); print "  changed:           " p; next }
  /^Only in published/ { d = $3; sub(/:$/, "", d); sub(/^published\/?/, "", d); print "  only in published: " (d == "" ? "" : d "/") $4; next }
  /^Only in package/   { d = $3; sub(/:$/, "", d); sub(/^package\/?/, "", d);   print "  only in package:   " (d == "" ? "" : d "/") $4; next }
  { print "  " $0 }
' "$tmp/diff.q"
echo "first lines of the diff:"
(cd "$tmp/cmp" && diff -ru published package) | head -n 40 | sed 's/^/  /'
exit "$DIFFERENT"
