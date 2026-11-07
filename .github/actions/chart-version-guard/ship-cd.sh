#!/usr/bin/env bash
# Ships a chart's CompositionDefinition inside its package, stamped with the version it installs.
# release-oci.yaml runs it on every chart it publishes, and chart-version-guard.yaml runs it on a
# pull request, so a release and a pull request package a chart the same way.
#
#   ship-cd.sh source  <chart dir>               prints the CompositionDefinition the chart ships, or
#                                                nothing when it ships none
#   ship-cd.sh prepare <chart dir> [<version>]   stamps CHART_VERSION and SOURCE_REF in it with
#                                                <version> (left alone when omitted), puts it at
#                                                <chart dir>/compositiondefinition.yaml, and stops the
#                                                chart's .helmignore excluding it
#   ship-cd.sh verify  <chart.tgz> <oci repo>    refuses a package whose CompositionDefinition is
#                                                missing, or installs another chart or another version
#
# Why: the Marketplace installs from the krateo-blueprints helm index, and the index takes the
# archive GHCR holds (krateo-blueprints/charts PUBLISHING.md, rules 1 and 3). That archive has to
# carry the CompositionDefinition that registers it, at <name>/compositiondefinition.yaml, pinned
# to its own version. Before this, release-oci packaged without it and builder repositories packaged
# a second, different archive for the index (event-feedback 0.1.1: GHCR sha256 11b7f74e..., index
# 5f6dfa83...).
#
# Which file: <chart dir>/compositiondefinition.yaml, else the one in the chart directory's parent.
# Those are the two layouts that carry one:
#   - a builder repository (krateo-blueprints/builder-scaffold): the chart IS the repository root,
#     and the file sits beside Chart.yaml. Its .helmignore excluded the file, so `prepare` removes
#     that exclusion in the release's checkout. A seeded repository never receives scaffold updates,
#     so this is the only way the file reaches the ones already out there.
#   - a blueprint repository: blueprints/<name>/compositiondefinition.yaml beside the chart in
#     blueprints/<name>/chart/.
# A chart with neither ships none and is not touched: `source` prints nothing and callers skip the
# rest.
#
# A file found this way is not trusted to be about this chart. `verify` requires it to install
# exactly <oci repo>/<name> at the package's version, so a CompositionDefinition beside a chart for a
# different reason refuses the release, loudly, instead of shipping inside the wrong chart.
#
# Needs: bash, tar, awk, GNU sed, yq v4.
set -euo pipefail

die() {
  echo "::error::$*" >&2
  exit 1
}

source_of() { # $1=chart dir
  if [ -f "$1/compositiondefinition.yaml" ]; then
    printf '%s\n' "$1/compositiondefinition.yaml"
  elif [ -f "$(dirname "$1")/compositiondefinition.yaml" ]; then
    printf '%s\n' "$(dirname "$1")/compositiondefinition.yaml"
  fi
}

# A .helmignore line that excludes exactly this file: with or without the leading slash, with
# surrounding blanks. Anything broader (a glob) is not edited; `verify` then refuses the package,
# naming the file, because what the glob was meant to exclude is not this script's to decide.
unexclude() { # $1=chart dir
  local hi="$1/.helmignore"
  [ -f "$hi" ] || return 0
  awk '{ l = $0; gsub(/^[ \t]+|[ \t\r]+$/, "", l) } l != "/compositiondefinition.yaml" && l != "compositiondefinition.yaml"' \
    "$hi" >"$hi.ship-cd"
  if cmp -s "$hi" "$hi.ship-cd"; then
    rm -f "$hi.ship-cd"
  else
    mv "$hi.ship-cd" "$hi"
    echo "${hi}: no longer excludes compositiondefinition.yaml (in this checkout only), so the package carries it"
  fi
}

cmd="${1:-}"
case "$cmd" in
  source)
    [ $# -eq 2 ] || die "usage: ship-cd.sh source <chart dir>"
    source_of "$2"
    ;;

  prepare)
    [ $# -eq 2 ] || [ $# -eq 3 ] || die "usage: ship-cd.sh prepare <chart dir> [<version>]"
    d="$2"
    version="${3:-}"
    src="$(source_of "$d")"
    [ -n "$src" ] || exit 0
    # The same stamp release-oci applies to Chart.yaml, so chart and CompositionDefinition carry one
    # number. The file is in the release's own checkout; nothing is written back to the repository.
    if [ -n "$version" ]; then
      sed -i "s/CHART_VERSION/${version}/g; s/SOURCE_REF/${version}/g" "$src"
    fi
    dst="$d/compositiondefinition.yaml"
    if ! [ "$src" -ef "$dst" ]; then
      cp "$src" "$dst"
    fi
    unexclude "$d"
    echo "${d}: ships ${src}${version:+, stamped ${version}}"
    ;;

  verify)
    [ $# -eq 3 ] || die "usage: ship-cd.sh verify <chart.tgz> <oci repo>"
    tgz="$2"
    oci="${3%/}"
    command -v yq >/dev/null 2>&1 || die "ship-cd.sh needs yq v4"
    [ -f "$tgz" ] || die "no such package: $tgz"
    # Read the listing once and match with here-strings: `tar | grep -q` can kill tar with SIGPIPE,
    # and under pipefail that fails the test exactly when the file IS there.
    members="$(tar tzf "$tgz")"
    top="$(head -n1 <<<"$members" | cut -d/ -f1)"
    chart_yaml="$(tar -xzOf "$tgz" "${top}/Chart.yaml")"
    name="$(yq -r '.name' <<<"$chart_yaml")"
    version="$(yq -r '.version' <<<"$chart_yaml")"
    base="$(basename "$tgz")"
    grep -qxF "${name}/compositiondefinition.yaml" <<<"$members" ||
      die "${base}: no ${name}/compositiondefinition.yaml in the package. Is it excluded by a .helmignore pattern? Refusing to push."
    cd_yaml="$(tar -xzOf "$tgz" "${name}/compositiondefinition.yaml")"
    count="$(yq ea -r '[select(.kind == "CompositionDefinition")] | length' <<<"$cd_yaml")"
    [ "$count" = 1 ] ||
      die "${base}: ${name}/compositiondefinition.yaml holds ${count} CompositionDefinitions, not one. Refusing to push."
    cd_url="$(yq ea -r 'select(.kind == "CompositionDefinition") | .spec.chart.url' <<<"$cd_yaml")"
    cd_ver="$(yq ea -r 'select(.kind == "CompositionDefinition") | .spec.chart.version' <<<"$cd_yaml")"
    want_url="${oci}/${name}"
    [ "$cd_url" = "$want_url" ] ||
      die "${base}: its CompositionDefinition installs '${cd_url}', not ${want_url}, where this package is pushed. Refusing to push."
    [ "$cd_ver" = "$version" ] ||
      die "${base}: its CompositionDefinition installs version '${cd_ver}', not ${version}. Refusing to push."
    echo "${base}: carries ${name}/compositiondefinition.yaml installing ${want_url} ${version}"
    ;;

  *) die "usage: ship-cd.sh source|prepare|verify ..." ;;
esac
