#!/usr/bin/env bash
# check-tag.sh <tag> <chart-dir> <changelog>
#
# A release tag must match the chart: the tag is v<Chart.yaml version>, CHANGELOG.md has a
# "## <version>" section for it, and that section is no longer marked (unreleased). Run by
# .github/workflows/release.yml before anything is built, and by make release-check.
set -euo pipefail

tag=${1:?usage: check-tag.sh <tag> <chart-dir> <changelog>}
chart=${2:?usage: check-tag.sh <tag> <chart-dir> <changelog>}
changelog=${3:?usage: check-tag.sh <tag> <chart-dir> <changelog>}

version=$(sed -n 's/^version: *"\{0,1\}\([^" ]*\)"\{0,1\} *$/\1/p' "$chart/Chart.yaml" | head -1)
[[ -n $version ]] || { echo "FAIL: $chart/Chart.yaml has no version"; exit 1; }
if [[ $tag != "v$version" ]]; then
  echo "FAIL: tag $tag doesn't match $chart/Chart.yaml (version $version, so the tag is v$version)"
  exit 1
fi
heading=$(grep -m1 -E "^## v?${version//./\\.}( |$)" "$changelog" || true)
if [[ -z $heading ]]; then
  echo "FAIL: $changelog has no \"## $version\" section; write the release's changes there"
  exit 1
fi
if grep -qi 'unreleased' <<<"$heading"; then
  echo "FAIL: $changelog: \"$heading\" is still marked unreleased; remove the marker in the release commit"
  exit 1
fi
echo "==> $tag matches $chart/Chart.yaml and $changelog"
