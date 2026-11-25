#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
stage=$(mktemp -d "${TMPDIR:-/tmp}/kessel-coexist.XXXXXX")
trap 'rm -rf -- "$stage"' EXIT
stage=$(cd "$stage" && pwd)

case "$(node -p 'process.platform')" in
  darwin) extension=dylib ;;
  linux) extension=so ;;
  win32) extension=dll ;;
  *) echo "Unsupported native package platform" >&2; exit 1 ;;
esac

source_dir="$root/npm/kessel"
binary="${KESSEL_PACKAGE_BINARY:-$root/bin/libkessel.$extension}"
mkdir -p "$stage/previous"
for copy in candidate-a candidate-b; do
  mkdir -p "$stage/$copy/npm/kessel" "$stage/$copy/bin"
  cp "$binary" "$stage/$copy/bin/libkessel.$extension"
  cp "$source_dir/"{index.js,async-fallback.js,parse-worker.js,binary-reader.js,package.json,package-lock.json} "$stage/$copy/npm/kessel/"
  (cd "$stage/$copy/npm/kessel" && npm ci --no-audit --no-fund)
done

# The old dependency is intentional. A single deduplicated Koffi would
# hide the typed-array decoder crash this test is intended to catch.
(cd "$stage/previous" && npm install --no-audit --no-fund --save-exact \
  @dvrdlibs/kessel@0.21.0 koffi@3.0.1)

candidate="$stage/candidate-a/npm/kessel"
previous="$stage/previous/node_modules/@dvrdlibs/kessel"
second_candidate="$stage/candidate-b/npm/kessel"
case "$(node -p 'process.platform')" in
  win32)
    candidate=$(cygpath --windows "$candidate")
    previous=$(cygpath --windows "$previous")
    second_candidate=$(cygpath --windows "$second_candidate")
    ;;
esac

node "$root/tests/runners/npm_coexistence.js" "$candidate" "$previous"
node "$root/tests/runners/npm_coexistence.js" "$previous" "$candidate"
node "$root/tests/runners/npm_coexistence.js" "$candidate" "$second_candidate"
node "$root/tests/runners/npm_coexistence.js" "$second_candidate" "$candidate"
