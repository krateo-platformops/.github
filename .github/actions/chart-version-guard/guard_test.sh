#!/usr/bin/env bash
# Tests guard.sh against a real, empty OCI registry with fixture charts packaged and pushed by
# helm, and against a stub registry that answers badly (testdata/registry_stub.py).
#
# Run: TEST_REGISTRY=localhost:5000 bash guard_test.sh
#   TEST_REGISTRY is a registry:2 reachable over plain http on localhost, e.g.
#   docker run -d -p 127.0.0.1:5000:5000 registry:2. Every run uses its own path in it.
# Needs: helm, python3, and guard.sh's own tools.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
guard="$here/guard.sh"
reg="${TEST_REGISTRY:?set TEST_REGISTRY to a local registry:2, e.g. localhost:5000}"
tmp="$(mktemp -d)"
stub_pid=""
cleanup() { [ -n "$stub_pid" ] && kill "$stub_pid" 2>/dev/null; rm -rf "$tmp"; }
trap cleanup EXIT
run_id="$(date +%s)-$$"
fail=0

# A fresh copy of the fixture chart, edited by the awk program $2 applied to file $3 (optional).
fixture() { # $1=name [$2=awk program] [$3=file relative to the chart]
  rm -rf "${tmp:?}/$1" && mkdir -p "$tmp/$1" && cp -R "$here/testdata/chart" "$tmp/$1/chart"
  if [ -n "${2:-}" ]; then
    awk "$2" "$tmp/$1/chart/$3" >"$tmp/$1/edit" && mv "$tmp/$1/edit" "$tmp/$1/chart/$3"
  fi
}
# Rewrites a file of an existing fixture with an awk program.
edit() { # $1=name $2=awk program $3=file
  awk "$2" "$tmp/$1/chart/$3" >"$tmp/$1/edit" && mv "$tmp/$1/edit" "$tmp/$1/chart/$3"
}
# Packages fixture $1 and prints the .tgz path.
package() {
  local out
  out="$(helm package "$tmp/$1/chart" -d "$tmp/$1/dist")" || { echo "helm package $1 failed" >&2; exit 1; }
  printf '%s' "${out##*: }"
}
push() { # $1=tgz $2=oci repo
  helm push "$1" "$2" >"$tmp/push.out" 2>&1 || { echo "helm push failed:"; cat "$tmp/push.out"; exit 1; }
}
# The four annotations release-oci stamps (krateo-platformops/.github#38), as yq writes them.
stamp_prog() { # $1=revision $2=release tag
  printf '%s' '{ print } /^annotations:/ {
    print "  org.opencontainers.image.revision: '"$1"'"
    print "  org.opencontainers.image.source: https://github.com/krateo-platformops/example"
    print "  org.opencontainers.image.version: '"$2"'"
    print "  org.opencontainers.image.ref.name: '"$2"'" }'
}
no_annotations='/^annotations:/ { skip = 1; next } skip && /^  / { next } { skip = 0; print }'
# For a chart with no annotations of its own, the stamp creates the map.
stamp_new_prog() { # $1=revision
  printf '%s' '{ print } /^version:/ {
    print "annotations:"
    print "  org.opencontainers.image.revision: '"$1"'" }'
}

sha_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | awk '{ print $1 }'; }
# Uploads file $2 as a blob to repository $1 of the test registry and prints its digest.
blob_put() { # $1=repository path $2=file
  local dg loc
  dg="sha256:$(sha_of "$2")"
  loc="$(curl -sS -X POST -D - -o /dev/null "http://${reg}/v2/$1/blobs/uploads/" | tr -d '\r' |
    awk 'tolower($1) == "location:" { print $2 }')"
  case "$loc" in /*) loc="http://${reg}${loc}" ;; esac
  case "$loc" in *\?*) loc="${loc}&digest=${dg}" ;; *) loc="${loc}?digest=${dg}" ;; esac
  curl -sSf -X PUT -H 'Content-Type: application/octet-stream' --data-binary @"$2" "$loc" >/dev/null ||
    { echo "blob upload to $1 failed" >&2; exit 1; }
  printf '%s' "$dg"
}
# Publishes a .tgz as a Helm chart artifact through the registry API, without helm: for packages
# helm would refuse to push, and to put a package under a tag that is not its version.
raw_push() { # $1=tgz $2=repository path (no host) $3=tag
  local cfg="$tmp/raw-config.json" man="$tmp/raw-manifest.json" cd ld
  printf '{}' >"$cfg"
  cd="$(blob_put "$2" "$cfg")" && ld="$(blob_put "$2" "$1")" || exit 1
  printf '{"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json","config":{"mediaType":"application/vnd.cncf.helm.config.v1+json","digest":"%s","size":%s},"layers":[{"mediaType":"application/vnd.cncf.helm.chart.content.v1.tar+gzip","digest":"%s","size":%s}]}' \
    "$cd" "$(wc -c <"$cfg" | tr -d ' ')" "$ld" "$(wc -c <"$1" | tr -d ' ')" >"$man"
  curl -sSf -X PUT -H 'Content-Type: application/vnd.oci.image.manifest.v1+json' --data-binary @"$man" \
    "http://${reg}/v2/$2/manifests/$3" >/dev/null || { echo "manifest upload to $2:$3 failed" >&2; exit 1; }
}
# A hand-made package: one chart directory holding only the Chart.yaml given on stdin.
craft() { # $1=case $2=chart name; prints the .tgz path
  mkdir -p "$tmp/$1/$2" && cat >"$tmp/$1/$2/Chart.yaml" && tar -czf "$tmp/$1.tgz" -C "$tmp/$1" "$2" && printf '%s' "$tmp/$1.tgz"
}
stamps() { # $1=revision: the four stamp keys, as helm writes them
  printf '  org.opencontainers.image.ref.name: 3.1.4%s\n  org.opencontainers.image.revision: %s\n  org.opencontainers.image.source: https://github.com/krateo-platformops/example\n  org.opencontainers.image.version: 3.1.4%s\n' "${1:0:1}" "$1" "${1:0:1}"
}

check() { # $1=case $2=want (0|10|11|error) $3=tgz $4=oci repo [$5=text the output must contain]
  local rc out
  out="$(bash "$guard" "$3" "$4" 2>&1)"
  rc=$?
  local ok=1
  case "$2" in
    error) case "$rc" in 0 | 10 | 11) ok=0 ;; esac
      printf '%s' "$out" | grep -q "could not check" || ok=0 ;;
    *) [ "$rc" = "$2" ] || ok=0 ;;
  esac
  if [ -n "${5:-}" ] && ! printf '%s' "$out" | grep -qF -- "$5"; then ok=0; fi
  if [ "$ok" = 1 ]; then
    echo "ok   $1: exit=$rc"
  else
    echo "FAIL $1: exit=$rc (want $2${5:+, output containing '$5'})"
    printf '%s\n' "$out" | sed 's/^/    /'
    fail=1
  fi
}

ns="oci://${reg}/guard-test-${run_id}"

# 1. Not published yet.
fixture base
base_tgz="$(package base)"
check "absent" 0 "$base_tgz" "$ns" "absent: ${reg}/guard-test-${run_id}/guard-fixture:0.1.0 is not published"

push "$base_tgz" "$ns"

# 2. The same chart packaged again later: the .tgz bytes differ (mtimes), the files do not.
sleep 1
fixture again
again_tgz="$(package again)"
if cmp -s "$base_tgz" "$again_tgz"; then
  echo "FAIL premise: repackaging produced byte-identical .tgz files, so the mtime case proves nothing"; fail=1
else
  echo "ok   premise: the repackaged .tgz differs byte-wise from the published one"
fi
check "identical except mtimes" 10 "$again_tgz" "$ns" "identical: "

# 3. A template changed without a version bump.
fixture tpl '{ print } /^data:/ { print "  extra: \"changed\"" }' templates/configmap.yaml
check "one template changed" 11 "$(package tpl)" "$ns" "changed:           templates/configmap.yaml"

# 4. appVersion changed without a version bump.
fixture appv '{ sub(/^appVersion: "1.0.0"$/, "appVersion: \"1.0.1\""); print }' Chart.yaml
check "Chart.yaml appVersion changed" 11 "$(package appv)" "$ns" "+appVersion: 1.0.1"
check "Chart.yaml appVersion changed: names the file" 11 "$(package appv)" "$ns" "changed:           Chart.yaml"

# More differences that must count.
fixture added
printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: extra\n' >"$tmp/added/chart/templates/extra.yaml"
check "file added" 11 "$(package added)" "$ns" "only in package:   templates/extra.yaml"
fixture subchart '{ sub(/"yes"/, "\"no\""); print }' charts/sub/templates/configmap.yaml
check "vendored subchart changed" 11 "$(package subchart)" "$ns" "changed:           charts/sub/templates/configmap.yaml"
fixture ownann '{ sub(/category: fixture/, "category: other"); print }' Chart.yaml
check "the chart's own annotation changed" 11 "$(package ownann)" "$ns" "+  krateo.io/category: other"

# 5. Content release-oci writes differently on every run must not count.
fixture lock '{ sub(/^generated: .*/, "generated: \"2026-11-03T10:00:00.123456789Z\""); print }' Chart.lock
check "only Chart.lock's generated time differs" 10 "$(package lock)" "$ns" "identical: "
fixture stamped "$(stamp_prog 1111111111111111111111111111111111111111 3.1.31)" Chart.yaml
check "published unstamped, package stamped" 10 "$(package stamped)" "$ns" "identical: "

ns_stamped="${ns}-stamped"
push "$(package stamped)" "$ns_stamped"
fixture restamped "$(stamp_prog 2222222222222222222222222222222222222222 3.1.32)" Chart.yaml
check "published stamped by one commit, package by another" 10 "$(package restamped)" "$ns_stamped" "identical: "
check "published stamped, package unstamped" 10 "$base_tgz" "$ns_stamped" "identical: "
fixture stamped_tpl "$(stamp_prog 3333333333333333333333333333333333333333 3.1.33)" Chart.yaml
edit stamped_tpl '{ print } /^data:/ { print "  extra: \"changed\"" }' templates/configmap.yaml
check "stamped, and a template changed" 11 "$(package stamped_tpl)" "$ns_stamped" "changed:           templates/configmap.yaml"

# Every key release-oci's stamp step writes must be one guard.sh strips. A key it does not know
# would make every unchanged re-release "different", on every caller at once. The keys are read
# from the stamp step itself (the quoted yq paths of krateo-platformops/.github#38), and each is
# stamped with a per-run value onto the chart published above, which must stay "identical".
release_oci="$here/../../workflows/release-oci.yaml"
stamp_keys="$(grep -oE '"org\.opencontainers\.image\.[A-Za-z0-9.-]+"' "$release_oci" | tr -d '"' | sort -u)"
if [ -z "$stamp_keys" ]; then
  if grep -q 'yq -i' "$release_oci"; then
    echo "FAIL stamp keys: release-oci.yaml runs yq -i but no quoted org.opencontainers.image.* key was found; update this test to read the stamp step"
    fail=1
  else
    echo "skip stamp keys: release-oci.yaml does not stamp provenance on this branch (krateo-platformops/.github#38 is not merged)"
  fi
else
  for key in $stamp_keys; do
    fixture "stampkey-${key##*.}" '{ print } /^annotations:/ { print "  '"$key"': per-run-'"$run_id"'" }' Chart.yaml
    check "release-oci stamps ${key}: guard.sh strips it" 10 "$(package "stampkey-${key##*.}")" "$ns" "identical: "
  done
fi

# A chart with no annotations of its own: the stamp creates the map, and removing the stamp must
# remove the map with it.
ns_bare="${ns}-bare"
fixture bare "$no_annotations" Chart.yaml
push "$(package bare)" "$ns_bare"
fixture bare_stamped "$no_annotations" Chart.yaml
edit bare_stamped "$(stamp_new_prog 4444444444444444444444444444444444444444)" Chart.yaml
check "no own annotations: published unstamped, package stamped" 10 "$(package bare_stamped)" "$ns_bare" "identical: "

# 6. The exclusion can never make the comparison vacuous.
# Two packages whose only content is the lookup key (name, version) plus the stamp: once the stamp
# is excluded nothing is left, so "identical" would prove nothing. helm refuses to package such a
# chart, so these are made by hand and published through the registry API.
ns_raw_path="guard-test-${run_id}-raw"
published_vacuous="$(printf 'annotations:\n%s\nname: guard-vacuous\nversion: 0.1.0\n' "$(stamps aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)" | craft vac-pub guard-vacuous)"
raw_push "$published_vacuous" "${ns_raw_path}/guard-vacuous" 0.1.0
local_vacuous="$(printf 'annotations:\n%s\nname: guard-vacuous\nversion: 0.1.0\n' "$(stamps bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb)" | craft vac-loc guard-vacuous)"
check "error: only the stamp differs, and nothing else is left to compare" error "$local_vacuous" "oci://${reg}/${ns_raw_path}" "nothing is left to compare"
# Control: the same hand-made pair with one real field is compared, and found identical.
published_minimal="$(printf 'annotations:\n%s\napiVersion: v2\nname: guard-minimal\nversion: 0.1.0\n' "$(stamps aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)" | craft min-pub guard-minimal)"
raw_push "$published_minimal" "${ns_raw_path}/guard-minimal" 0.1.0
local_minimal="$(printf 'annotations:\n%s\napiVersion: v2\nname: guard-minimal\nversion: 0.1.0\n' "$(stamps bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb)" | craft min-loc guard-minimal)"
check "control: the same pair plus one real field compares identical" 10 "$local_minimal" "oci://${reg}/${ns_raw_path}" "identical: "

# The exclusion may remove only the stamp lines. A stamp key with a multi-line value would take
# more lines with it, so the check stops rather than compare what is left.
fixture multiline '{ print } /^annotations:/ { print "  org.opencontainers.image.revision: |"; print "    first line"; print "    second line" }' Chart.yaml
check "error: a stamp key with a multi-line value" error "$(package multiline)" "$ns" "would also remove"

# The published package must be the chart and version it is published as.
raw_push "$base_tgz" "${ns_raw_path}/guard-fixture" 0.2.0
fixture v020 '{ sub(/^version: 0.1.0$/, "version: 0.2.0"); print }' Chart.yaml
check "error: the artifact under a tag declares another version" error "$(package v020)" "oci://${reg}/${ns_raw_path}" "does not declare guard-fixture 0.2.0"

# 7. The existence check errors: never "absent".
python3 -I "$here/testdata/registry_stub.py" "$tmp/stub.port" &
stub_pid=$!
for _ in $(seq 1 50); do [ -s "$tmp/stub.port" ] && break; sleep 0.1; done
stub="127.0.0.1:$(cat "$tmp/stub.port")"
check "error: nothing listening" error "$base_tgz" "oci://127.0.0.1:1/charts"
check "error: registry answers 500" error "$base_tgz" "oci://${stub}/e500" "HTTP 500"
check "error: 404 that is not a registry error" error "$base_tgz" "oci://${stub}/html404" "HTTP 404 without a registry error code"
check "error: token endpoint refuses" error "$base_tgz" "oci://${stub}/denied" "answered HTTP 403"
check "error: the artifact is not a Helm chart" error "$base_tgz" "oci://${stub}/notchart" "is not a Helm chart"
check "absent: stub answers NAME_UNKNOWN" 0 "$base_tgz" "oci://${stub}/other"

# Credentials go only to the host they are for, as helm's login is for one host.
REGISTRY_HOST="$stub" REGISTRY_USERNAME=u REGISTRY_PASSWORD=p \
  check "credentials for the repo's host are used" 0 "$base_tgz" "oci://${stub}/creds" "absent: "
REGISTRY_HOST=ghcr.io REGISTRY_USERNAME=u REGISTRY_PASSWORD=p \
  check "credentials for another host are not sent" error "$base_tgz" "oci://${stub}/creds" "answered HTTP 403"
REGISTRY_USERNAME=u REGISTRY_PASSWORD=p \
  check "error: credentials without the host they are for" error "$base_tgz" "oci://${stub}/creds" "without REGISTRY_HOST"

# 8. Bad input.
check "error: not a package" error "$here/testdata/chart/values.yaml" "$ns"
check "error: not an oci:// repo" error "$base_tgz" "https://${reg}/charts"

exit "$fail"
