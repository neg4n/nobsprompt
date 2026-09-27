#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
zig=${1:-zig}
zsh_tests=${NBSP_ZSH_TESTS:-enabled}
iterations=${NBSP_FUZZ_ITERATIONS:-250000}
case "$zsh_tests" in auto|enabled|disabled) ;; *) echo 'NBSP_ZSH_TESTS must be auto, enabled, or disabled' >&2; exit 2 ;; esac
case "$iterations" in ''|*[!0-9]*) echo 'invalid fuzz iteration count' >&2; exit 2 ;; esac
if test "${#iterations}" -gt 8 || test "$iterations" -lt 1 || test "$iterations" -gt 10000000; then echo 'fuzz iterations must be 1..10000000' >&2; exit 2; fi
cd "$root"
"$zig" build test --summary all -Doptimize=Debug -Dzsh_tests="$zsh_tests"
"$zig" build test --summary all -Doptimize=ReleaseSafe -Dzsh_tests="$zsh_tests"
# This executable uses c_allocator. These settings diagnose exercised Darwin
# heap corruption; they are not ASan, UBSan, or LeakSanitizer.
MallocNanoZone=0 MallocScribble=1 MallocPreScribble=1 MallocGuardEdges=1 \
  MallocErrorAbort=1 MallocCorruptionAbort=1 \
  "$zig" build test --summary all -Doptimize=Debug -Dzsh_tests="$zsh_tests"
"$zig" build fuzz -Doptimize=Debug -- "$iterations"
printf '%s\n' 'MEMORY-CHECK-PASS (runtime checks, allocation-failure tests, Darwin heap diagnostics, deterministic mutations)'
