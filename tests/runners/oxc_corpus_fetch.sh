#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
vendor_dir="${KESSEL_CORPUS_DIR:-$root/tests/vendor}"
mkdir -p "$vendor_dir"

fetch_corpus() (
  local name=$1 url=$2 revision=$3
  shift 3
  local destination="$vendor_dir/$name" current staging

  if [[ -e "$destination" || -L "$destination" ]]; then
    current=$(git -C "$destination" rev-parse --verify HEAD 2>/dev/null) || current=""
    if [[ "$current" != "$revision" ]]; then
      echo "$destination has revision ${current:-unknown}, expected $revision" >&2
      return 1
    fi
    for directory in "$@"; do
      if [[ ! -d "$destination/$directory" ]]; then
        echo "$destination is missing $directory" >&2
        return 1
      fi
    done
    echo "$name already at $revision"
    return 0
  fi

  staging=$(mktemp -d "$vendor_dir/.$name.XXXXXX")
  trap 'rm -rf -- "$staging"' EXIT
  git -C "$staging" init --quiet
  git -C "$staging" remote add origin "$url"
  git -C "$staging" config remote.origin.promisor true
  git -C "$staging" config remote.origin.partialclonefilter blob:none
  git -C "$staging" fetch --no-tags --depth=1 --filter=blob:none origin "$revision"
  git -C "$staging" sparse-checkout set --cone "$@"
  git -C "$staging" checkout --quiet --detach "$revision"
  mv "$staging" "$destination"
  echo "$name ready at $revision"
)

# Keep these revisions in sync with the SHA checks in the coverage harness.
fetch_corpus test262 https://github.com/tc39/test262.git \
  ccaac100ff49d81e9ff47a75ff4c60e0bd3f262e test
fetch_corpus babel https://github.com/babel/babel.git \
  4079bcda153cafc76f76d2b683aa0ede0a93864c packages/babel-parser/test/fixtures
fetch_corpus typescript https://github.com/microsoft/TypeScript.git \
  f350b52331494b68c90ab02e2b6d0828d2a22a74 tests/cases tests/baselines/reference
fetch_corpus estree-conformance https://github.com/oxc-project/estree-conformance.git \
  9c67f5e33f7a2d122e87d9b8f6eec5f53861cc53 tests
