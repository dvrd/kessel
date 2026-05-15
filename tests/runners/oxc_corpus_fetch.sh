#!/bin/bash
# OXC conformance-corpus fetcher (S26 W6).
#
# Mirrors the four upstream corpora OXC's tasks/coverage/ pulls:
#   * tc39/test262                sparse: test/                         (~100 MB)
#   * microsoft/TypeScript        sparse: tests/cases/ + baselines/     (~150-300 MB)
#   * babel/babel                 sparse: packages/babel-parser/test/   (~50-100 MB)
#   * oxc-project/estree-conformance   full                            (~few MB)
#
# Pins to the exact SHAs OXC uses (lifted from
# .github/scripts/clone-parallel.mjs at oxc-project/oxc@main as of 2026-05-15).
# This guarantees byte-identical input to what OXC tests itself against —
# our pass/fail numbers are directly comparable to OXC's published coverage.
#
# Why sparse-checkout the big corpora: a full clone of microsoft/TypeScript is
# ~2 GB even with --depth=1 (massive `src/` tree). We only need the test
# fixtures. Babel is similar — `packages/babel-parser/test/fixtures/` is
# the only thing we walk.
#
# Why bash, not Odin: matches the existing tests/runners/test262_fetch.sh
# convention; fetch logic is git-native and shells well. Anything more
# would be over-engineering.
#
# Usage:
#   tests/runners/oxc_corpus_fetch.sh                # fetch all four
#   tests/runners/oxc_corpus_fetch.sh typescript     # fetch only typescript
#   tests/runners/oxc_corpus_fetch.sh babel estree   # fetch only those two
#   tests/runners/oxc_corpus_fetch.sh test262        # fetch only test262
#
# Idempotent: re-running on an existing clone fetches the SHA again
# (no-op if already at SHA) and re-applies sparse-checkout + reset.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VENDOR_DIR="${SCRIPT_DIR}/../vendor"
mkdir -p "$VENDOR_DIR"

# SHAs lifted from oxc-project/oxc@main:.github/scripts/clone-parallel.mjs.
# Bump these when we want to track upstream — the runner is otherwise
# fully reproducible against the pinned tree.
TEST262_SHA="ccaac100ff49d81e9ff47a75ff4c60e0bd3f262e"
TYPESCRIPT_SHA="f350b52331494b68c90ab02e2b6d0828d2a22a74"
BABEL_SHA="4079bcda153cafc76f76d2b683aa0ede0a93864c"
ESTREE_CONFORMANCE_SHA="9c67f5e33f7a2d122e87d9b8f6eec5f53861cc53"

# `clone_pinned <dir> <repo-url> <sha> [sparse-pattern]`
#
# Mirrors OXC's clone-parallel.mjs cloneRepo() shape:
#   * git init if no .git/ yet
#   * (re-)set origin URL
#   * if sparse pattern given: enable sparse-checkout, write the pattern
#   * fetch the exact SHA at depth=1
#   * hard-reset to the SHA, clean any cruft
#
# The sparse pattern is written to .git/info/sparse-checkout BEFORE the
# fetch+reset so the working tree only ever materializes the wanted paths.
clone_pinned() {
  local dir="$1"
  local repo_url="$2"
  local sha="$3"
  local sparse_pattern="${4:-}"

  echo "→ ${dir}"
  echo "  url: ${repo_url}"
  echo "  sha: ${sha}"
  if [ -n "$sparse_pattern" ]; then
    echo "  sparse: ${sparse_pattern}"
  fi

  mkdir -p "$dir"

  if [ ! -d "${dir}/.git" ]; then
    git -C "$dir" init --quiet
    git -C "$dir" remote add origin "$repo_url"
  else
    # Idempotent: ensure origin URL matches.
    git -C "$dir" remote set-url origin "$repo_url" 2>/dev/null \
      || git -C "$dir" remote add origin "$repo_url"
  fi

  if [ -n "$sparse_pattern" ]; then
    git -C "$dir" config core.sparseCheckout true
    mkdir -p "${dir}/.git/info"
    # Overwrite (not append) so re-runs with a different pattern work.
    printf '%s\n' "$sparse_pattern" > "${dir}/.git/info/sparse-checkout"
  fi

  # `--depth=1 origin <sha>` works for any reachable SHA on the default
  # branch tip OR any tagged ref. The SHAs we pin are all on `main`.
  git -C "$dir" fetch --quiet --depth=1 origin "$sha"
  git -C "$dir" reset --hard --quiet "$sha"
  git -C "$dir" clean -f -d -q

  echo "  ✓ at $(git -C "$dir" rev-parse --short HEAD)"
  echo
}

# Resolve which suites to fetch from CLI args (default: all three).
fetch_test262=false
fetch_typescript=false
fetch_babel=false
fetch_estree=false

if [ $# -eq 0 ]; then
  fetch_test262=true
  fetch_typescript=true
  fetch_babel=true
  fetch_estree=true
else
  for arg in "$@"; do
    case "$arg" in
      test262)       fetch_test262=true ;;
      typescript|ts) fetch_typescript=true ;;
      babel)         fetch_babel=true ;;
      estree|estree-conformance) fetch_estree=true ;;
      *) echo "Unknown suite: $arg" >&2; exit 1 ;;
    esac
  done
fi

echo "Fetching OXC conformance corpus → ${VENDOR_DIR}"
echo

if $fetch_test262; then
  # test/ is the only path OXC's coverage loader walks. Keeping docs/tools
  # out of the working tree makes missing-fixture drift easier to audit.
  clone_pinned \
    "${VENDOR_DIR}/test262" \
    "https://github.com/tc39/test262.git" \
    "$TEST262_SHA" \
    "test/"
fi

if $fetch_typescript; then
  # tests/cases/ contains both compiler/ and conformance/ subtrees;
  # tests/baselines/reference/ contains the *.errors.txt files used by
  # the coverage harness's `should_fail` classifier (a fixture is
  # negative iff its baseline lists at least one TS error code that's
  # not in NOT_SUPPORTED_ERROR_CODES). Both are needed for OXC parity.
  # Together they are still <100MB, vs 2GB+ for a full clone.
  clone_pinned \
    "${VENDOR_DIR}/typescript" \
    "https://github.com/microsoft/TypeScript.git" \
    "$TYPESCRIPT_SHA" \
    "$(printf 'tests/cases/\ntests/baselines/reference/\n')"
fi

if $fetch_babel; then
  # packages/babel-parser/test/fixtures/ is the parser fixture tree.
  # Each test is a directory containing `input.{js,ts,tsx,jsx,mjs}` plus
  # an `output.json` (Babel's AST format, not ESTree — we don't compare
  # against it; we only use the `input.*` as kessel↔OXC compare-bait).
  clone_pinned \
    "${VENDOR_DIR}/babel" \
    "https://github.com/babel/babel.git" \
    "$BABEL_SHA" \
    "packages/babel-parser/test/fixtures/"
fi

if $fetch_estree; then
  # estree-conformance is OXC's own ESTree-parity test repo. Small enough
  # to clone in full; tests/acorn-jsx/ has ESTree-format `output.json`
  # references (not Babel format) which gives us a third oracle.
  clone_pinned \
    "${VENDOR_DIR}/estree-conformance" \
    "https://github.com/oxc-project/estree-conformance.git" \
    "$ESTREE_CONFORMANCE_SHA"
fi

echo "Done."
echo
echo "File counts:"
if $fetch_test262 && [ -d "${VENDOR_DIR}/test262/test" ]; then
  test262_count=$(find "${VENDOR_DIR}/test262/test" -type f \( -name "*.js" -o -name "*.mjs" \) | wc -l | tr -d ' ')
  echo "  test262:    ${test262_count} .js/.mjs"
fi
if $fetch_typescript && [ -d "${VENDOR_DIR}/typescript/tests/cases" ]; then
  ts_count=$(find "${VENDOR_DIR}/typescript/tests/cases" -type f -name "*.ts" | wc -l | tr -d ' ')
  tsx_count=$(find "${VENDOR_DIR}/typescript/tests/cases" -type f -name "*.tsx" | wc -l | tr -d ' ')
  echo "  typescript: ${ts_count} .ts + ${tsx_count} .tsx"
fi
if $fetch_babel && [ -d "${VENDOR_DIR}/babel/packages/babel-parser/test/fixtures" ]; then
  babel_count=$(find "${VENDOR_DIR}/babel/packages/babel-parser/test/fixtures" -type f -name "input.*" | wc -l | tr -d ' ')
  echo "  babel:      ${babel_count} input.* fixture files"
fi
if $fetch_estree && [ -d "${VENDOR_DIR}/estree-conformance" ]; then
  estree_count=$(find "${VENDOR_DIR}/estree-conformance" -type f \( -name "*.js" -o -name "*.ts" -o -name "*.jsx" -o -name "*.tsx" \) | wc -l | tr -d ' ')
  echo "  estree:     ${estree_count} source files"
fi
