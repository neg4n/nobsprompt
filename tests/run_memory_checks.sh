#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
asan_build=${NBSP_ASAN_BUILD:-build-asan}
native_build=${NBSP_NATIVE_MEMORY_BUILD:-build-memory-native}
fuzz_build=${NBSP_FUZZ_BUILD:-build-fuzz}
fuzz_iterations=${NBSP_FUZZ_ITERATIONS:-250000}

if test "$(uname -s)" = Darwin; then
  detect_leaks=0
else
  detect_leaks=1
fi
asan_options="abort_on_error=1:halt_on_error=1:detect_leaks=$detect_leaks:strict_string_checks=1:check_initialization_order=1:detect_stack_use_after_return=1"

cd "$root"

for source in src/*.c; do
  "${CC:-cc}" --analyze -std=c11 \
    -D_POSIX_C_SOURCE=200809L -D_DARWIN_C_SOURCE -Isrc \
    -Xanalyzer -analyzer-output=text -o /dev/null "$source"
done

if test -d "$asan_build"; then
  meson setup --reconfigure "$asan_build" \
    -Db_sanitize=address,undefined -Db_lundef=false -Dbuildtype=debug
else
  meson setup "$asan_build" \
    -Db_sanitize=address,undefined -Db_lundef=false -Dbuildtype=debug
fi
meson compile -C "$asan_build"
ASAN_OPTIONS="$asan_options" \
UBSAN_OPTIONS='abort_on_error=1:halt_on_error=1:print_stacktrace=1' \
  meson test -C "$asan_build" --print-errorlogs

if test -d "$native_build"; then
  meson setup --reconfigure "$native_build" -Dbuildtype=debug
else
  meson setup "$native_build" -Dbuildtype=debug
fi
meson compile -C "$native_build"
MallocNanoZone=0 \
MallocScribble=1 \
MallocPreScribble=1 \
MallocGuardEdges=1 \
MallocCheckHeapStart=1 \
MallocCheckHeapEach=1 \
  meson test -C "$native_build" --print-errorlogs

if test -d "$fuzz_build"; then
  meson setup --reconfigure "$fuzz_build" -Dfuzzing=true -Db_lundef=false -Dbuildtype=debug
else
  meson setup "$fuzz_build" -Dfuzzing=true -Db_lundef=false -Dbuildtype=debug
fi
meson compile -C "$fuzz_build" fuzz-parsers
ASAN_OPTIONS="$asan_options" \
UBSAN_OPTIONS='abort_on_error=1:halt_on_error=1:print_stacktrace=1' \
  "$fuzz_build/tests/fuzz-parsers" "$fuzz_iterations"
