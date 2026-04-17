#!/bin/bash

echo "=== Building Kessel with Profiling ==="

# Build with profiling support
odin build src -out:kessel_profile -o:speed \
    -define:ODIN_DEBUG_PROFILE=true \
    2>&1 | tail -5

echo ""
echo "Profile build created: kessel_profile"
echo "Run with: ./kessel_profile parse <file>"
echo "Then analyze with: Instruments -t Time Profiler"
