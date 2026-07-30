#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
asan_build=${NBSP_ASAN_BUILD:-build-asan}
native_build=${NBSP_NATIVE_MEMORY_BUILD:-build-memory-native}
fuzz_build=${NBSP_FUZZ_BUILD:-build-fuzz}
fuzz_iterations=${NBSP_FUZZ_ITERATIONS:-250000}
zsh_tests=${NBSP_ZSH_TESTS:-enabled}
asan_leaks=${NBSP_ASAN_LEAKS:-auto}
analyzer_cc=${NBSP_ANALYZER_CC:-${CC:-cc}}
python=python3
lsan_options='exitcode=86'

case "$zsh_tests" in
  auto|enabled|disabled) ;;
  *)
    printf '%s\n' 'NBSP_ZSH_TESTS must be auto, enabled, or disabled' >&2
    exit 2
    ;;
esac

case "$asan_leaks" in
  auto|enabled|disabled) ;;
  *)
    printf '%s\n' 'NBSP_ASAN_LEAKS must be auto, enabled, or disabled' >&2
    exit 2
    ;;
esac

case "$fuzz_iterations" in
  ''|*[!0-9]*)
    printf '%s\n' 'NBSP_FUZZ_ITERATIONS must be an integer from 1 through 10000000' >&2
    exit 2
    ;;
esac
if test "${#fuzz_iterations}" -gt 8 || \
    test "$fuzz_iterations" -lt 1 || test "$fuzz_iterations" -gt 10000000; then
  printf '%s\n' 'NBSP_FUZZ_ITERATIONS must be an integer from 1 through 10000000' >&2
  exit 2
fi

platform=$(uname -s)
if test "$platform" = Darwin; then
  asan_base_options='abort_on_error=1:halt_on_error=1:strict_string_checks=1:detect_stack_use_after_return=1'
  native_summary='native tests with Darwin malloc scribbling and guard edges, plus unit tests with per-allocation heap checks'
else
  asan_base_options='abort_on_error=1:halt_on_error=1:strict_string_checks=1:check_initialization_order=1:detect_stack_use_after_return=1'
  native_summary='native tests (Darwin malloc diagnostics do not apply on this platform)'
fi

cd "$root"

if ! "$python" -c 'import sys; raise SystemExit(sys.version_info < (3, 9))'; then
  printf '%s\n' 'memory checks require Python 3.9 or newer' >&2
  exit 1
fi

analysis_tmp=$(mktemp -d "${TMPDIR:-/tmp}/nbsp-analyze.XXXXXX")
probe_clean_log=$analysis_tmp/asan-probe-clean.log
probe_leak_log=$analysis_tmp/asan-probe-leak.log
fuzz_probe_clean_log=$analysis_tmp/fuzz-probe-clean.log
fuzz_probe_leak_log=$analysis_tmp/fuzz-probe-leak.log
run_asan_probe() {
  probe_status=$(ASAN_OPTIONS="$probe_options" LSAN_OPTIONS="$lsan_options" \
    "$python" -c '
import subprocess
import sys

with open(sys.argv[2], "wb") as log:
    result = subprocess.run(
        [sys.argv[1], *sys.argv[3:]],
        stdout=log,
        stderr=subprocess.STDOUT,
        check=False,
    )
status = result.returncode if result.returncode >= 0 else 128 - result.returncode
print(status)
' "$@")
}
select_leak_policy() {
  probe_binary=$1
  clean_log=$2
  leak_log=$3
  runtime_label=$4
  if test "$asan_leaks" = disabled; then
    detect_leaks=0
    leak_summary="LeakSanitizer explicitly disabled for the $runtime_label runtime"
    return 0
  fi
  probe_options='detect_leaks=1:halt_on_error=1'
  run_asan_probe "$probe_binary" "$clean_log"
  clean_status=$probe_status
  run_asan_probe "$probe_binary" "$leak_log" --leak
  leak_status=$probe_status
  leak_supported=false
  if test "$clean_status" -eq 0 && test "$leak_status" -eq 86 && \
      grep -Eq 'LeakSanitizer: detected memory leaks|SUMMARY: AddressSanitizer: .* leaked' \
        "$leak_log"; then
    leak_supported=true
  fi

  case "$asan_leaks" in
    auto)
      if test "$leak_supported" = true; then
        detect_leaks=1
        leak_summary="LeakSanitizer enabled after a verified $runtime_label runtime probe"
      else
        detect_leaks=0
        leak_summary="LeakSanitizer unavailable according to the $runtime_label runtime probe"
      fi
      ;;
    enabled)
      if test "$leak_supported" != true; then
        printf '%s\n' \
          "NBSP_ASAN_LEAKS=enabled, but the $runtime_label runtime did not produce the expected intentional-leak diagnostic and exit status" >&2
        return 1
      fi
      detect_leaks=1
      leak_summary="LeakSanitizer explicitly requested and verified for the $runtime_label runtime"
      ;;
  esac
}
cleanup() {
  rm -f -- \
    "$analysis_tmp/nbsp_zsh.c" \
    "$analysis_tmp/nbsp_autosuggest.c" \
    "$probe_clean_log" \
    "$probe_leak_log" \
    "$fuzz_probe_clean_log" \
    "$fuzz_probe_leak_log"
  rmdir "$analysis_tmp" 2>/dev/null || :
}
trap cleanup 0
trap 'exit 129' 1
trap 'exit 130' 2
trap 'exit 143' 15

"$python" tools/embed_zsh.py \
  src/nbsp_zsh.zsh "$analysis_tmp/nbsp_zsh.c"
"$python" tools/embed_zsh.py \
  src/nbsp_autosuggest.zsh "$analysis_tmp/nbsp_autosuggest.c" \
  nbsp_print_zsh_autosuggest

for source in src/*.c; do
  "$analyzer_cc" --analyze -std=c11 \
    -D_POSIX_C_SOURCE=200809L -D_DARWIN_C_SOURCE -Isrc \
    -Xanalyzer -analyzer-output=text \
    -Xanalyzer -analyzer-werror -o /dev/null "$source"
done
for source in "$analysis_tmp"/*.c; do
  "$analyzer_cc" --analyze -std=c11 \
    -D_POSIX_C_SOURCE=200809L -D_DARWIN_C_SOURCE -Isrc \
    -Xanalyzer -analyzer-output=text \
    -Xanalyzer -analyzer-werror -o /dev/null "$source"
done

if test -d "$asan_build"; then
  meson setup --reconfigure "$asan_build" \
    -Db_sanitize=address,undefined -Db_lundef=false -Dbuildtype=debug -Dfuzzing=false \
    -Dzsh_tests="$zsh_tests"
else
  meson setup "$asan_build" \
    -Db_sanitize=address,undefined -Db_lundef=false -Dbuildtype=debug -Dfuzzing=false \
    -Dzsh_tests="$zsh_tests"
fi
meson compile -C "$asan_build" asan-runtime-probe
probe_binary=$asan_build/tests/asan-runtime-probe
select_leak_policy "$probe_binary" "$probe_clean_log" "$probe_leak_log" \
  'test-build'
asan_detect_leaks=$detect_leaks
asan_leak_summary=$leak_summary
asan_options="$asan_base_options:detect_leaks=$asan_detect_leaks"

meson compile -C "$asan_build"
ASAN_OPTIONS="$asan_options" \
LSAN_OPTIONS="$lsan_options" \
UBSAN_OPTIONS='abort_on_error=1:halt_on_error=1:print_stacktrace=1' \
  meson test -C "$asan_build" --print-errorlogs

if test -d "$native_build"; then
  meson setup --reconfigure "$native_build" \
    -Db_sanitize=none -Db_lundef=false -Dbuildtype=debug -Dfuzzing=false \
    -Dzsh_tests="$zsh_tests"
else
  meson setup "$native_build" \
    -Db_sanitize=none -Db_lundef=false -Dbuildtype=debug -Dfuzzing=false \
    -Dzsh_tests="$zsh_tests"
fi
meson compile -C "$native_build"
if test "$platform" = Darwin; then
  native_wrapper='/usr/bin/env MallocNanoZone=0 MallocScribble=1 MallocPreScribble=1 MallocGuardEdges=1 MallocErrorAbort=1 MallocCorruptionAbort=1'
  meson test -C "$native_build" --wrapper "$native_wrapper" --print-errorlogs
  /usr/bin/env \
    MallocNanoZone=0 \
    MallocScribble=1 \
    MallocPreScribble=1 \
    MallocGuardEdges=1 \
    MallocCheckHeapStart=1 \
    MallocCheckHeapEach=1 \
    MallocCheckHeapSleep=0 \
    MallocCheckHeapAbort=1 \
    MallocErrorAbort=1 \
    MallocCorruptionAbort=1 \
    "$native_build/tests/test-unit"
else
  meson test -C "$native_build" --print-errorlogs
fi

if test -d "$fuzz_build"; then
  meson setup --reconfigure "$fuzz_build" \
    -Dfuzzing=true -Db_sanitize=address,undefined -Db_lundef=false -Dbuildtype=debug \
    -Dzsh_tests="$zsh_tests"
else
  meson setup "$fuzz_build" \
    -Dfuzzing=true -Db_sanitize=address,undefined -Db_lundef=false -Dbuildtype=debug \
    -Dzsh_tests="$zsh_tests"
fi
meson compile -C "$fuzz_build" asan-runtime-probe fuzz-parsers
fuzz_probe_binary=$fuzz_build/tests/asan-runtime-probe
select_leak_policy "$fuzz_probe_binary" "$fuzz_probe_clean_log" \
  "$fuzz_probe_leak_log" 'fuzz-build'
fuzz_detect_leaks=$detect_leaks
fuzz_leak_summary=$leak_summary
fuzz_asan_options="$asan_base_options:detect_leaks=$fuzz_detect_leaks"
ASAN_OPTIONS="$fuzz_asan_options" \
LSAN_OPTIONS="$lsan_options" \
UBSAN_OPTIONS='abort_on_error=1:halt_on_error=1:print_stacktrace=1' \
  "$fuzz_build/tests/fuzz-parsers" "$fuzz_iterations"

registered_tests=$(meson test -C "$native_build" --list)
if printf '%s\n' "$registered_tests" | grep -q 'zsh-integration'; then
  expect_summary='Expect-backed tests were registered and executed'
else
  expect_summary='Expect-backed tests were not registered'
fi

printf '%s\n' \
  'Checked: all production C translation units (including generated embedded-Zsh sources),' \
  "ASan+UBSan tests ($asan_leak_summary), $native_summary," \
  "and the deterministic parser mutation harness ($fuzz_leak_summary)." \
  "$expect_summary (zsh_tests=$zsh_tests)."
