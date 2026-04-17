#!/bin/bash

# Kessel Build Script
# Usage: ./build.sh [debug|release]

set -e

MODE="${1:-release}"
TARGET="kessel"

if [ "$MODE" = "debug" ]; then
    echo "Building kessel in debug mode..."
    odin build src -out:$TARGET -debug
else
    echo "Building kessel in release mode..."
    odin build src -out:$TARGET -o:speed
fi

echo "Build complete: ./$TARGET"
