#!/usr/bin/env bash
# Regenerate the per-platform sub-package skeletons under npm/platforms/.
#
# Each sub-package is a tiny npm package — a package.json with the right
# `os` / `cpu` fields plus an index.js that exports the absolute path to
# the shared library. The binary itself is placed beside index.js by the
# release workflow before `npm publish` runs for that platform.
#
# This script is idempotent: re-running it overwrites package.json and
# index.js but does not touch any libkessel.* binaries staged in those
# directories.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# tuple: directory  npm-os  npm-cpu  binary-filename
PLATFORMS=(
  "darwin-arm64 darwin arm64 libkessel.dylib"
  "darwin-x64   darwin x64   libkessel.dylib"
  "linux-arm64  linux  arm64 libkessel.so"
  "linux-x64    linux  x64   libkessel.so"
  "win32-x64    win32  x64   libkessel.dll"
)

for row in "${PLATFORMS[@]}"; do
  read -r dir os cpu bin <<< "$row"
  mkdir -p "$ROOT/$dir"

  cat > "$ROOT/$dir/package.json" << JSON
{
  "name": "@dvrdlibs/kessel-$dir",
  "version": "0.0.0",
  "description": "Native libkessel binary for $dir. Installed automatically as an optional dependency of @dvrdlibs/kessel.",
  "main": "index.js",
  "files": [
    "index.js",
    "$bin"
  ],
  "os": ["$os"],
  "cpu": ["$cpu"],
  "license": "MIT",
  "repository": {
    "type": "git",
    "url": "https://github.com/dvrd/kessel.git"
  },
  "publishConfig": {
    "access": "public",
    "provenance": true
  }
}
JSON

  cat > "$ROOT/$dir/index.js" << JS
// Resolver entry for @dvrdlibs/kessel-$dir.
// Exports the absolute path to the platform-specific shared library.
// Loaded by the main @dvrdlibs/kessel package via require() on the
// sub-package name; npm only installs the sub-package whose os/cpu
// fields match the host, so only one resolves on any given machine.
'use strict';
module.exports = require('path').join(__dirname, '$bin');
JS

  echo "wrote $dir/{package.json,index.js}"
done
