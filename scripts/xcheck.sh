#!/usr/bin/env bash
# Cross-platform build verification via containers.
# Usage: scripts/xcheck.sh <platform>
#   platform = linux/arm64 | linux/amd64
#
# Builds libkessel.so inside a fresh Ubuntu container that matches the
# corresponding GitHub Actions runner. Verifies the Odin source compiles
# and links cleanly on that target. Does NOT run the npm smoke test —
# koffi loads native bindings and would require Node inside the container.

set -euo pipefail

PLATFORM="${1:?platform required: linux/arm64 | linux/amd64}"
case "$PLATFORM" in
  linux/arm64) ODIN_ARCH=arm64 ;;
  linux/amd64) ODIN_ARCH=amd64 ;;
  *) echo "unsupported platform: $PLATFORM" >&2; exit 2 ;;
esac

ODIN_RELEASE="dev-2026-05"
ODIN_TARBALL="odin-linux-${ODIN_ARCH}-${ODIN_RELEASE}.tar.gz"
ODIN_URL="https://github.com/odin-lang/Odin/releases/download/${ODIN_RELEASE}/${ODIN_TARBALL}"
OUT_DIR="bin/xcheck"
OUT_NAME="libkessel-linux-${ODIN_ARCH}.so"

mkdir -p "$OUT_DIR"

echo "==> xcheck $PLATFORM (Odin $ODIN_RELEASE)"

docker run --rm \
  --platform "$PLATFORM" \
  -v "$PWD":/work \
  -w /work \
  -e ODIN_URL="$ODIN_URL" \
  -e OUT_DIR="$OUT_DIR" \
  -e OUT_NAME="$OUT_NAME" \
  ubuntu:24.04 \
  bash -euxc '
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends \
      ca-certificates curl tar xz-utils \
      llvm-18 clang-18 lld-18 \
      libc6-dev
    update-alternatives --install /usr/bin/clang clang /usr/bin/clang-18 100
    update-alternatives --install /usr/bin/ld ld /usr/bin/ld.lld-18 100

    curl -sSL "$ODIN_URL" -o /tmp/odin.tar.gz
    mkdir -p /opt/odin
    tar -xzf /tmp/odin.tar.gz -C /opt/odin --strip-components=1
    export PATH="/opt/odin:$PATH"
    odin version

    odin build src \
      -build-mode:shared \
      -out:"$OUT_DIR/$OUT_NAME" \
      -o:speed \
      -no-bounds-check

    file "$OUT_DIR/$OUT_NAME"
    ls -la "$OUT_DIR/$OUT_NAME"
  '
