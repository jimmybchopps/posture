#!/usr/bin/env bash
# build-dist.sh <tag> [out-dir]: builds a release's assets into out-dir (default dist/), the same
# way for .github/workflows/release.yml and `make release-check TAG=...`:
#
#   posture-<version>.tgz   the chart (helm package)
#   SHA256SUMS              of the package
#   RELEASE_NOTES.md        CHANGELOG.md's section for this version
#
# Expects HELM (the helm binary) in the environment; run from the repo root.
set -euo pipefail

tag=${1:?usage: build-dist.sh <tag> [out-dir]}
out=${2:-dist}
here=$(cd "$(dirname "$0")" && pwd)
chart=charts/posture
: "${HELM:?set HELM to the helm binary}"

"$here/check-tag.sh" "$tag" "$chart" CHANGELOG.md
version=${tag#v}

mkdir -p "$out"
"$HELM" package "$chart" -d "$out" >/dev/null
(
  cd "$out"
  sha256sum "posture-${version}.tgz" >SHA256SUMS
)
"$here/release-notes.sh" "$version" CHANGELOG.md >"$out/RELEASE_NOTES.md"
echo "==> built $tag into $out/: posture-${version}.tgz, SHA256SUMS, RELEASE_NOTES.md"
