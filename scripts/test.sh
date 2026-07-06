#!/bin/bash
# Runs the Swift test suites. Wrapper exists because the Command Line Tools
# toolchain (no full Xcode) ships Testing.framework outside the default search
# paths — these flags make `swift test` find it at compile, link, and run time.
# With full Xcode installed, plain `swift test` also works.
set -euo pipefail
cd "$(dirname "$0")/.."

FW=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
LIBDIR=/Library/Developer/CommandLineTools/Library/Developer/usr/lib

if [[ -d "$FW" ]]; then
    exec swift test --disable-xctest \
        -Xswiftc -F -Xswiftc "$FW" \
        -Xlinker -F -Xlinker "$FW" \
        -Xlinker -rpath -Xlinker "$FW" \
        -Xlinker -rpath -Xlinker "$LIBDIR" \
        "$@"
else
    exec swift test "$@"
fi
