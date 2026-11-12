#!/usr/bin/env bash
#
# pin-actions.sh - Replace "uses: owner/repo@vX" with "uses: owner/repo@<commit sha> # vX".
# Usage: scripts/pin-actions.sh .github/workflows/*.yaml
#
set -euo pipefail

if [[ $# -eq 0 ]]; then
  echo "Usage: ${0##*/} <workflow files...>" >&2
  exit 2
fi

refs="$(grep -hoE 'uses: [A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@v[0-9][A-Za-z0-9_.-]*' "$@" | sed 's/^uses: //' | sort -u || true)"

while IFS= read -r ref; do
  [[ -n $ref ]] || continue
  path="${ref%@*}"
  tag="${ref#*@}"
  slug="$(cut -d/ -f1-2 <<< "$path")"
  url="https://github.com/${slug}.git"

  # Annotated tags need the peeled (^{}) commit; lightweight tags do not.
  sha="$(git ls-remote "$url" "refs/tags/${tag}^{}" | awk '{print $1}')"
  if [[ -z $sha ]]; then
    sha="$(git ls-remote "$url" "refs/tags/${tag}" | awk '{print $1}')"
  fi
  if [[ -z $sha ]]; then
    echo "ERROR: tag ${tag} does not exist in ${slug}" >&2
    exit 1
  fi

  echo "pinning ${path}@${tag} -> ${sha}"
  sed -i "s#uses: ${ref}\$#uses: ${path}@${sha} \# ${tag}#" "$@"
done <<< "$refs"