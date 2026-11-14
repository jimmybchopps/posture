#!/usr/bin/env bash
# Runs check-tag.sh against every case in tag-cases/<name>/ (a Chart.yaml, a CHANGELOG.md, a
# tag, and expect: pass, or a substring of the expected failure), and release-notes.sh against
# one changelog.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
fail=0
for c in "$here"/tag-cases/*/; do
  name=$(basename "$c")
  want=$(cat "$c/expect")
  out=$("$here/check-tag.sh" "$(cat "$c/tag")" "$c" "$c/CHANGELOG.md" 2>&1); rc=$?
  if [[ $want == pass ]]; then
    [[ $rc -eq 0 ]] && ok=1 || ok=0
  else
    [[ $rc -ne 0 ]] && grep -qF -- "$want" <<<"$out" && ok=1 || ok=0
  fi
  if [[ $ok == 1 ]]; then
    echo "==> check-tag case $name: $want"
  else
    echo "FAIL: check-tag case $name: expected $want, got (exit $rc): $out"; fail=1
  fi
done
notes=$("$here/release-notes.sh" 0.2.0 "$here/tag-cases/matching/CHANGELOG.md")
if [[ $notes == "- Something new." ]]; then
  echo "==> release-notes: prints only the version's section"
else
  echo "FAIL: release-notes printed: $notes"; fail=1
fi
exit $fail
