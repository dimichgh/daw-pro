#!/bin/bash
# Runs the Swift test suites. Wrapper exists because the Command Line Tools
# toolchain (no full Xcode) ships Testing.framework outside the default search
# paths — these flags make `swift test` find it at compile, link, and run time.
# With full Xcode installed, plain `swift test` also works.
set -euo pipefail
cd "$(dirname "$0")/.."

# Cap how many tests swift-testing runs at once (2026-10-05, W7-STALL). Uncapped,
# it queues every test body on the shared Swift thread pool at the start; anything
# created after that (a Task.sleep wake-up, a detached loop) waits behind the whole
# queue, and tests with a time limit fail together at one instant. Measured: the
# reproducer went from 13 issues to 0 at width 12 or 18. The variable is
# experimental: if a toolchain drops it, the stall comes back silently. Check: when
# it is honoured, the first test ends within ~0.1 s of the start, not seconds later.
# An explicit value in the environment wins.
: "${SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH:=$(sysctl -n hw.ncpu)}"
export SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH

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
