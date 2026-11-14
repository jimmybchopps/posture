#!/usr/bin/env bash
# release-notes.sh <version> <changelog>: prints CHANGELOG.md's section for <version> (without
# its heading), the body of the GitHub release.
set -euo pipefail

version=${1:?usage: release-notes.sh <version> <changelog>}
changelog=${2:?usage: release-notes.sh <version> <changelog>}

awk -v want="$version" '
  /^## / {
    v = $2; sub(/^v/, "", v)
    if (on) exit
    on = (v == want)
    next
  }
  on' "$changelog" | sed -e '/./,$!d'
