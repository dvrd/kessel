#!/bin/bash

# Build Kessel as shared library for Node.js binding

echo "Building Kessel shared library..."

# Compile as dynamic library
odin build src -out:kessel_lib -build-mode:dynamic -o:speed \
    -define:ODIN_OS=osx \
    -define:ODIN_ARCH=arm64 \
    2>&1 | head -20

if [ -f kessel_lib.dylib ] || [ -f kessel_lib.so ] || [ -f kessel_lib.dll ]; then
    echo "✓ Shared library built"
    ls -lh kessel_lib.* 2>/dev/null
else
    echo "✗ Failed to build shared library"
    echo "Trying alternative approach..."
    
    # Try static library fallback
    odin build src -out:kessel_lib -build-mode:static -o:speed 2>&1 | head -20
    ls -lh kessel_lib.* 2>/dev/null || echo "Build failed"
fi
