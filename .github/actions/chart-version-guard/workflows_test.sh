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
    CHART_VERSION_GUARD="$here/guard.sh" SHIP_CD="$here/ship-cd.sh" REGISTRY_HOST=ghcr.io REGISTRY_USERNAME="" REGISTRY_PASSWORD="" \
    GIT_SHA="$SHA" SRC_URL="https://github.com/krateo-platformops/fixture" SRC_REF="$CV" \
    run_step "$tmp/release.sh" "$1"
}
pr_check() { # $1=fixture repo; uses $OCI, $AV
  CHART_VERSION_GUARD="$here/guard.sh" SHIP_CD="$here/ship-cd.sh" REGISTRY_HOST=ghcr.io REGISTRY_USERNAME="" REGISTRY_PASSWORD="" GH_TOKEN="" \
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

# --- release-oci: CompositionDefinitions ship inside the package ---------------------------------

# A published chart's file ("" when the package has none).
published_file() { # $1=chart $2=tag $3=path inside the chart directory
  local layer
  layer="$(curl -sS -H 'Accept: application/vnd.oci.image.manifest.v1+json' "http://${reg}/v2/${ns_path}/$1/manifests/$2" |
    jq -r '.layers[] | select(.mediaType == "application/vnd.cncf.helm.chart.content.v1.tar+gzip") | .digest')"
  curl -sS "http://${reg}/v2/${ns_path}/$1/blobs/${layer}" | tar -xzO "$1/$3" 2>/dev/null || true
}
cd_doc() { # $1=chart $2=version $3=url
  printf 'apiVersion: core.krateo.io/v1alpha1\nkind: CompositionDefinition\nmetadata:\n  name: %s\n  namespace: krateo-system\nspec:\n  chart:\n    url: %s\n    version: %s\n' "$1" "$3" "$2"
}
# A builder repository as krateo-blueprints/builder-scaffold seeded it until now: the chart is the
# root, a literal version, and a .helmignore that kept the registration file out of the package.
builder="$tmp/src-builder"
chart "$builder" site 0.4.0
printf '.git/\n.github/\n.helmignore\n/*.tgz\n/compositiondefinition.yaml\n' >"$builder/.helmignore"
cd_doc site 0.4.0 "$ns/site" >"$builder/compositiondefinition.yaml"

# What release-oci published before this change: the same chart, packaged without the file. A chart
# with no CompositionDefinition goes through the step exactly as before, so the current step builds it.
old_builder="$tmp/src-builder-old"
cp -R "$builder" "$old_builder"
rm "$old_builder/compositiondefinition.yaml"
CV=0.4.0 AV="" SHA=7777777777777777777777777777777777777777
release "$old_builder"
expect "cd: (setup) site 0.4.0 published as before, without a CompositionDefinition" 0 "+done: pushed 1, skipped 0" "-ships"
site1="$(digest site 0.4.0)"
expect "cd: ... the published package has no compositiondefinition.yaml" any "=$(published_file site 0.4.0 compositiondefinition.yaml)="

SHA=8888888888888888888888888888888888888888
release "$builder"
expect "cd: re-release of a version published before the file shipped: skipped, not refused" 0 \
  "+was published before release-oci shipped CompositionDefinitions" "+done: pushed 0, skipped 1" "-Pushing" \
  "-different: " "+no longer excludes compositiondefinition.yaml"
expect "cd: ... its digest did not move" any "=$(digest site 0.4.0)=$site1"

builder_changed="$tmp/src-builder-changed"
cp -R "$builder" "$builder_changed"
printf '  extra: changed\n' >>"$builder_changed/templates/cm.yaml"
release "$builder_changed"
expect "cd: the same version with a changed template: refused, nothing pushed" fail \
  "+site-0.4.0.tgz (published with different contents)" "+changed:           templates/cm.yaml" \
  "+pushed nothing" "-Pushing" "-was published before"

builder_next="$tmp/src-builder-next"
cp -R "$builder_changed" "$builder_next"
sed -i 's/^version: 0.4.0/version: 0.4.1/' "$builder_next/Chart.yaml"
sed -i 's/version: 0.4.0/version: 0.4.1/' "$builder_next/compositiondefinition.yaml"
CV=0.4.1 SHA=9999999999999999999999999999999999999999
release "$builder_next"
expect "cd: the next version is pushed carrying its CompositionDefinition" 0 \
  "+carries site/compositiondefinition.yaml installing $ns/site 0.4.1" "+done: pushed 1, skipped 0"
expect "cd: ... the published package carries it, pinned to 0.4.1" any \
  "=$(published_file site 0.4.1 compositiondefinition.yaml | yq -r '.spec.chart.version')=0.4.1" \
  "=$(published_file site 0.4.1 compositiondefinition.yaml | yq -r '.spec.chart.url')=$ns/site"
site2="$(digest site 0.4.1)"
SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
release "$builder_next"
expect "cd: a re-run of that version skips it as identical" 0 \
  "+skipped: site-0.4.1.tgz is already published, contents identical" "-was published before" "-Pushing"
expect "cd: ... digest unchanged" any "=$(digest site 0.4.1)=$site2"

# A page set: the placeholder in Chart.yaml and in the CompositionDefinition, both stamped.
pages="$tmp/src-pages"
chart "$pages" pageset CHART_VERSION
printf '.git/\n/compositiondefinition.yaml\n' >"$pages/.helmignore"
cd_doc pageset CHART_VERSION "$ns/pageset" >"$pages/compositiondefinition.yaml"
CV=1.2.0 SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
release "$pages"
expect "cd: a page set's CompositionDefinition is stamped with the tag" 0 "+installing $ns/pageset 1.2.0" "+done: pushed 1"
expect "cd: ... and published so" any "=$(published_file pageset 1.2.0 compositiondefinition.yaml | yq -r '.spec.chart.version')=1.2.0"

# A blueprint repository: the CompositionDefinition sits one level above the chart.
bp="$tmp/src-blueprint"
chart "$bp/blueprints/vm/chart" vm CHART_VERSION
cd_doc vm CHART_VERSION "$ns/vm" >"$bp/blueprints/vm/compositiondefinition.yaml"
CV=0.3.0 SHA=cccccccccccccccccccccccccccccccccccccccc
release "$bp"
expect "cd: a CompositionDefinition beside the chart directory is shipped inside it" 0 \
  "+ships ./blueprints/vm/compositiondefinition.yaml, stamped 0.3.0" "+installing $ns/vm 0.3.0" "+done: pushed 1"
expect "cd: ... and published so" any "=$(published_file vm 0.3.0 compositiondefinition.yaml | yq -r '.spec.chart.version')=0.3.0"

# A repository whose root CompositionDefinition is two levels above its charts (frontend, portal,
# observability, snowplow): the charts ship none and package exactly as before, so the published
# svc 1.0.0 from above is still identical.
rootcd="$tmp/src-tag-rootcd"
cp -R "$src_tag" "$rootcd"
cd_doc frontend 9.9.9 "oci://elsewhere/frontend" >"$rootcd/compositiondefinition.yaml"
CV=1.0.0 AV=1.0.0 SHA=dddddddddddddddddddddddddddddddddddddddd
release "$rootcd"
expect "cd: a CompositionDefinition two levels up is not picked up; the chart is unchanged" 0 \
  "+skipped: svc-1.0.0.tgz is already published, contents identical" "-ships" "-carries"

# Refusals, before anything is pushed.
wrongurl="$tmp/src-wrongurl"
chart "$wrongurl" wrongurl 0.1.0
cd_doc wrongurl 0.1.0 "oci://ghcr.io/someone-else/charts/wrongurl" >"$wrongurl/compositiondefinition.yaml"
CV=0.1.0 AV="" SHA=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
release "$wrongurl"
expect "cd: a CompositionDefinition installing another chart: refused, nothing pushed" fail \
  "+installs 'oci://ghcr.io/someone-else/charts/wrongurl', not $ns/wrongurl" "-Pushing"
expect "cd: ... wrongurl 0.1.0 is not published" any "=$(digest wrongurl 0.1.0)=absent"

wrongver="$tmp/src-wrongver"
chart "$wrongver" wrongver 0.5.0
cd_doc wrongver 0.4.0 "$ns/wrongver" >"$wrongver/compositiondefinition.yaml"
CV=0.5.0
release "$wrongver"
expect "cd: a CompositionDefinition pinned to another version: refused, nothing pushed" fail \
  "+installs version '0.4.0', not 0.5.0" "-Pushing"
expect "cd: ... wrongver 0.5.0 is not published" any "=$(digest wrongver 0.5.0)=absent"

globbed="$tmp/src-globbed"
chart "$globbed" globbed 0.1.0
printf 'composition*.yaml\n' >"$globbed/.helmignore"
cd_doc globbed 0.1.0 "$ns/globbed" >"$globbed/compositiondefinition.yaml"
release "$globbed"
expect "cd: a .helmignore glob that still excludes the file: refused, naming it" fail \
  "+no globbed/compositiondefinition.yaml in the package" "-Pushing"

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
pr_check "$builder"
expect "pr: a version published before CompositionDefinitions shipped, unchanged: passes" 0 \
  "+.: 0.4.0 was published before release-oci shipped CompositionDefinitions and is otherwise unchanged" "-different: "
pr_check "$builder_changed"
expect "pr: ... the same version changed: fails" fail "+.: version 0.4.0 is already published with different contents"
pr_check "$builder_next"
expect "pr: a version published with its CompositionDefinition, unchanged: passes" 0 \
  "+.: 0.4.1 is already published with identical contents"
pr_check "$wrongver"
expect "pr: a CompositionDefinition pinned to another version: fails" fail \
  "+installs version '0.4.0', not 0.5.0" "+.: release-oci would refuse this package"

OCI="oci://127.0.0.1:1/charts"
pr_check "$src"
expect "pr: registry unreachable: fails" fail "+could not check 0.1.0 against oci://127.0.0.1:1/charts"

exit "$fail"
