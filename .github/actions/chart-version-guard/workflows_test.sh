#!/usr/bin/env bash
# Runs the REAL scripts of the two workflows that use guard.sh against a local registry: the
# "Discover, version, package & push" step of release-oci.yaml and the check step of
# chart-version-guard.yaml, read out of the workflow files with yq and run the way Actions runs a
# bash step. So what is tested is the push / skip / refuse logic that ships, not a copy of it.
#
# Run: TEST_REGISTRY=localhost:5000 bash workflows_test.sh
#   TEST_REGISTRY as for guard_test.sh. Needs helm, yq v4 and GNU sed: the steps were written for
#   ubuntu runners, so run this on Linux.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
reg="${TEST_REGISTRY:?set TEST_REGISTRY to a local registry:2, e.g. localhost:5000}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
run_id="$(date +%s)-$$"
fail=0

step() { # $1=workflow file $2=job $3=step name
  local s
  s="$(yq ".jobs[\"$2\"].steps[] | select(.name == \"$3\") | .run" "$root/.github/workflows/$1")"
  [ -n "$s" ] && [ "$s" != null ] || { echo "FAIL cannot find step '$3' of $2 in $1"; exit 1; }
  # Expressions are evaluated by Actions, not bash; a step that used one inline could not run here.
  if printf '%s' "$s" | grep -q '\${{'; then echo "FAIL step '$3' uses a \${{ }} expression inline"; exit 1; fi
  printf '%s\n' "$s"
}
step release-oci.yaml package-and-push "Discover, version, package & push every first-class chart" >"$tmp/release.sh" || exit 1
step chart-version-guard.yaml chart-version-guard "Check every chart version against the registry" >"$tmp/pr.sh" || exit 1

# --- fixtures ------------------------------------------------------------------------------------

chart() { # $1=dir $2=name $3=version [$4=appVersion]
  mkdir -p "$1/templates"
  {
    echo "apiVersion: v2"
    echo "name: $2"
    echo "version: $3"
    [ -n "${4:-}" ] && echo "appVersion: \"$4\""
  } >"$1/Chart.yaml"
  printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: %s\ndata:\n  k: v\n' "$2" >"$1/templates/cm.yaml"
}
# Literal versions, like observability: one tag re-releases every chart at its own version.
src="$tmp/src-literal"
chart "$src/charts/app" app 0.1.0 1.0.0
chart "$src/charts/app-crds" app-crds 0.1.0
chart "$src/charts/other" other 0.2.0 2.0.0
# Placeholders, like frontend: the tag is the version, appVersion is the latest app tag.
src_tag="$tmp/src-tag"
chart "$src_tag/helm/svc" svc CHART_VERSION APP_VERSION

ns="oci://${reg}/workflows-test-${run_id}"
ns_path="workflows-test-${run_id}"

digest() { # $1=chart $2=tag [$3=registry path]: the manifest digest, or "absent"
  local d
  d="$(curl -sS -o /dev/null -D - -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
    "http://${reg}/v2/${3:-$ns_path}/$1/manifests/$2" | tr -d '\r' | awk 'tolower($1) == "docker-content-digest:" { print $2 }')"
  printf '%s' "${d:-absent}"
}

# The org.opencontainers.image.revision annotation of a published chart ("" when it has none).
published_revision() { # $1=chart $2=tag
  local layer
  layer="$(curl -sS -H 'Accept: application/vnd.oci.image.manifest.v1+json' "http://${reg}/v2/${ns_path}/$1/manifests/$2" |
    jq -r '.layers[] | select(.mediaType == "application/vnd.cncf.helm.chart.content.v1.tar+gzip") | .digest')"
  curl -sS "http://${reg}/v2/${ns_path}/$1/blobs/${layer}" | tar -xzO "$1/Chart.yaml" |
    awk '/^  org\.opencontainers\.image\.revision:/ { print $2 }' | tr -d "\"'"
}

# Runs a step script in a fresh copy of a fixture repo, as Actions runs `shell: bash`.
n=0
run_step() { # $1=script $2=fixture repo; env passed through. Sets $rc, $log.
  n=$((n + 1))
  local wd="$tmp/run-$n"
  cp -R "$2" "$wd"
  log="$tmp/run-$n.log"
  (cd "$wd" && bash --noprofile --norc -eo pipefail "$1") >"$log" 2>&1
  rc=$?
}
release() { # $1=fixture repo; uses $OCI, $CV, $AV, $SHA
  CHART_VERSION="$CV" APP_VERSION="$AV" CHART_ROOT=. OCI_REPO="$OCI" \
    CHART_VERSION_GUARD="$here/guard.sh" REGISTRY_HOST=ghcr.io REGISTRY_USERNAME="" REGISTRY_PASSWORD="" \
    GIT_SHA="$SHA" SRC_URL="https://github.com/krateo-platformops/fixture" SRC_REF="$CV" \
    run_step "$tmp/release.sh" "$1"
}
pr_check() { # $1=fixture repo; uses $OCI, $AV
  CHART_VERSION_GUARD="$here/guard.sh" REGISTRY_HOST=ghcr.io REGISTRY_USERNAME="" REGISTRY_PASSWORD="" GH_TOKEN="" \
    OCI_REPO="$OCI" CHART_ROOT=. APP_VERSION_INPUT="$AV" GITHUB_REPOSITORY="krateo-platformops/fixture" \
    run_step "$tmp/pr.sh" "$1"
}

expect() { # $1=case $2=want exit (0, fail, or any: not checked) then any number of: +text (log has it) -text (log lacks it) =a=b (equal)
  local name="$1" want="$2" ok=1 why="" a
  shift 2
  if [ "$want" = 0 ] && [ "$rc" != 0 ]; then ok=0; why="exit $rc"; fi
  if [ "$want" = fail ] && [ "$rc" = 0 ]; then ok=0; why="exit 0"; fi
  for a in "$@"; do
    case "$a" in
      +*) grep -qF -- "${a#+}" "$log" || { ok=0; why="$why; log lacks '${a#+}'"; } ;;
      -*) grep -qF -- "${a#-}" "$log" && { ok=0; why="$why; log has '${a#-}'"; } ;;
      =*) local l="${a#=}"; [ "${l%%=*}" = "${l#*=}" ] || { ok=0; why="$why; '${l%%=*}' != '${l#*=}'"; } ;;
    esac
  done
  if [ "$ok" = 1 ]; then echo "ok   $name (exit $rc)"; else
    echo "FAIL $name:${why}"; sed 's/^/    /' "$log"; fail=1
  fi
}

# --- release-oci: push / skip / refuse -----------------------------------------------------------

OCI="$ns" CV=3.1.31 AV="" SHA=1111111111111111111111111111111111111111
release "$src"
expect "release: first tag publishes every chart" 0 "+Pushing" "+done: pushed 3, skipped 0"
app1="$(digest app 0.1.0)"; crds1="$(digest app-crds 0.1.0)"; other1="$(digest other 0.2.0)"
published() { [ "$1" != absent ] && echo yes || echo no; }
expect "release: ... all three are in the registry" any "=$(published "$app1")=yes" "=$(published "$crds1")=yes" "=$(published "$other1")=yes"

sleep 1 # so a repackage writes different mtimes
CV=3.1.32 SHA=2222222222222222222222222222222222222222
release "$src"
expect "release: next tag, nothing changed: every chart skipped" 0 \
  "+skipped: app-0.1.0.tgz is already published, contents identical" \
  "+skipped: app-crds-0.1.0.tgz is already published, contents identical" \
  "+skipped: other-0.2.0.tgz is already published, contents identical" \
  "-Pushing" "+done: pushed 0, skipped 3"
expect "release: ... and no digest moved" any "=$(digest app 0.1.0)=$app1" "=$(digest app-crds 0.1.0)=$crds1" "=$(digest other 0.2.0)=$other1"
# With provenance stamping (krateo-platformops/.github#38), the second run stamped a new commit
# into its packages; the skip must keep the artifact whose stamp names the commit that first
# published the version.
if grep -q 'org.opencontainers.image.revision' "$tmp/release.sh"; then
  expect "release: ... the published stamp still names the first commit" any \
    "=$(published_revision app 0.1.0)=1111111111111111111111111111111111111111"
else
  echo "--   release-oci does not stamp provenance on this branch; no stamp to check"
fi

changed="$tmp/src-changed"
cp -R "$src" "$changed"
printf '  extra: changed\n' >>"$changed/charts/other/templates/cm.yaml"
sed -i 's/^version: 0.1.0/version: 0.1.1/' "$changed/charts/app/Chart.yaml"
CV=3.1.33 SHA=3333333333333333333333333333333333333333
release "$changed"
expect "release: a template changed without a bump: refused, nothing pushed" fail \
  "+other-0.2.0.tgz (published with different contents)" "+changed:           templates/cm.yaml" \
  "+pushed nothing" "-Pushing"
expect "release: ... the bumped chart was not pushed either" any "=$(digest app 0.1.1)=absent" "=$(digest other 0.2.0)=$other1"

appv="$tmp/src-appv"
cp -R "$src" "$appv"
sed -i 's/^appVersion: "1.0.0"/appVersion: "1.0.1"/' "$appv/charts/app/Chart.yaml"
release "$appv"
expect "release: appVersion changed without a bump: refused" fail \
  "+app-0.1.0.tgz (published with different contents)" "+changed:           Chart.yaml" "+appVersion: 1.0.1" "-Pushing"
expect "release: ... digest unchanged" any "=$(digest app 0.1.0)=$app1"

OCI="oci://127.0.0.1:1/charts"
release "$src"
expect "release: registry unreachable: refused, nothing pushed" fail \
  "+could not check" "+(could not check the registry)" "+pushed nothing" "-Pushing"
OCI="$ns"

crds="$tmp/src-crds"
cp -R "$src" "$crds"
sed -i 's/^version: 0.1.0/version: 0.1.1/' "$crds/charts/app-crds/Chart.yaml"
CV=3.1.34 SHA=4444444444444444444444444444444444444444
release "$crds"
expect "release: only the CRD chart bumped: it is pushed, its skipped app chart does not hold it back" 0 \
  "+skipped: app-0.1.0.tgz" "+Pushing" "-holding back" "+done: pushed 1, skipped 2"
expect "release: ... app-crds 0.1.1 is published" any "=$(published "$(digest app-crds 0.1.1)")=yes"

# Placeholder charts: each tag is a new version; a re-run of a tag skips. A re-run that resolves a
# different APP_VERSION (the app repo was tagged since) would change appVersion under the same
# version, so it is refused.
CV=1.0.0 AV=1.0.0 SHA=5555555555555555555555555555555555555555
release "$src_tag"
expect "release (placeholders): tag 1.0.0 publishes" 0 "+Pushing" "+done: pushed 1, skipped 0"
SHA=6666666666666666666666666666666666666666
release "$src_tag"
expect "release (placeholders): re-run of tag 1.0.0 skips" 0 "+skipped: svc-1.0.0.tgz" "-Pushing"
AV=1.0.1
release "$src_tag"
expect "release (placeholders): re-run with a newer APP_VERSION is refused" fail "+appVersion: 1.0.1" "+pushed nothing"

# --- chart-version-guard.yaml: the pull-request check --------------------------------------------

AV=1.0.0
pr_check "$src"
expect "pr: nothing changed: passes, noting each chart is unchanged" 0 \
  "+./charts/other: 0.2.0 is already published with identical contents; the next release skips it" \
  "+3 already published and unchanged"
pr_check "$changed"
expect "pr: a template changed without a bump: fails, naming chart, version and file" fail \
  "+./charts/other: version 0.2.0 is already published with different contents" \
  "+changed:           templates/cm.yaml" "+./charts/app: 0.1.1 is not published yet"
bumped="$tmp/src-bumped"
cp -R "$changed" "$bumped"
sed -i 's/^version: 0.2.0/version: 0.2.1/' "$bumped/charts/other/Chart.yaml"
pr_check "$bumped"
expect "pr: the same change with a bump: passes" 0 "+./charts/other: 0.2.1 is not published yet" "+0 refused"
pr_check "$src_tag"
expect "pr: a CHART_VERSION chart is listed, not checked" 0 "+./helm/svc: version is set by the release tag"
srcref="$tmp/src-srcref"
cp -R "$src" "$srcref"
printf 'annotations:\n  source: https://github.com/krateo-platformops/fixture/tree/SOURCE_REF\n' >>"$srcref/charts/other/Chart.yaml"
pr_check "$srcref"
expect "pr: a literal version that uses SOURCE_REF fails" fail "+./charts/other: version 0.2.0 is literal, but Chart.yaml uses CHART_VERSION or SOURCE_REF"
OCI="oci://127.0.0.1:1/charts"
pr_check "$src"
expect "pr: registry unreachable: fails" fail "+could not check 0.1.0 against oci://127.0.0.1:1/charts"

exit "$fail"
