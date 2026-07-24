# Performance and memory audit

This audit covers the foreground `nbsp prompt` path. The detached
`nbsp data` backend uses the same collector and can be measured by passing
`data` as the second argument to `bench/benchmark.zsh`. Git status refresh is
deliberately asynchronous and is therefore measured for correctness and
bounded execution rather than included in foreground latency.

## Measurement snapshot

Measurements were taken on July 20, 2026 on Apple Silicon with macOS 26.5,
Apple Clang 21, Meson 1.11.2, LTO, and a release build. Latency is measured over
3,000 fresh process invocations. Small differences below roughly 0.02 ms should
be treated as noise.

| Build | Non-repository p95 | Warm repository p95 | Binary |
| --- | ---: | ---: | ---: |
| Baseline `-O3` + LTO | 1.480 ms | 1.493 ms | 53 KiB |
| Optimized `-O3` + LTO | 1.439 ms | 1.455 ms | 53 KiB |
| Optimized for size + LTO | 1.467 ms | not repeated | 55 KiB |
| Local `-mcpu=native` + LTO | 1.477 ms | not repeated | 53 KiB |

macOS process accounting for the baseline and optimized release binary:

| Metric | Baseline | Optimized | Change |
| --- | ---: | ---: | ---: |
| Maximum resident set | 1,441,792 B | 1,425,408 B | -16,384 B |
| Peak memory footprint | 983,328 B | 983,328 B | unchanged |
| Retired instructions | 13,902,164 | 13,730,244 median | about -1.2% |

The foreground path is now dominated by process creation, dyld, libc startup,
and Zsh command substitution. Further normal C micro-optimization has little
room to materially improve the observed wall time.

## Optimizations applied

- Repository discovery now walks with bounded stack buffers and performs no
  heap allocation. Non-repository paths no longer pay for `realpath`.
- Branch reads use `open`/`read` on a stack buffer instead of allocating a
  `FILE` stream and a joined path.
- Warm cache reads use one bounded read and in-place parsing. Percent-decoded
  repository validation and branch copying allocate no memory.
- Prompt segments escape directly into one growable output buffer instead of
  allocating a temporary string for each path, Git, Node, duration, job, and
  prompt-character segment. The data serializer uses the same collected facts
  without rendering or prompt escape expansion.
- NVM version parsing is allocation-free in the foreground renderer.
- Hidden symbols, dead stripping, `-O3`, and LTO keep the executable small.
- Git remains outside the foreground path, uses `posix_spawnp`, has a hard
  timeout and output cap, and atomically publishes only complete snapshots.

## Memory-safety coverage

`sh tests/run_memory_checks.sh` performs three independent passes:

1. Clang's path-sensitive static analyzer over every production translation
   unit, followed by AddressSanitizer and UndefinedBehaviorSanitizer with strict libc string
   checks, stack-use-after-return detection, stack-use-after-scope compiler
   instrumentation, abort-on-first-error, and the full unit/integration suite.
2. Native macOS allocator diagnostics with nano malloc disabled, pre- and
   post-allocation scribbling, guard pages, and a heap check after every
   allocation operation.
3. A deterministic ASan+UBSan mutation harness. The default 250,000 iterations
   mix structured Git/cache/path/NVM seeds with random binary inputs up to
   16 KiB and exercise status parsing, percent codecs, prompt escaping, path
   contraction, NVM parsing, numeric parsing, rendering, and buffer growth.

Integration coverage includes malformed and oversized values, corrupted cache
files, cache identity validation, lock contention, 16 concurrent refreshes,
background Git timeout, preservation of last-good data, worktrees, detached
HEAD, staged/modified/untracked states, hostile `%` branch names, Zsh hook
idempotence, forced debounce bypass, interactive ZLE redraws, terminal prompt
wrapper preservation, external-editor buffer and Unicode cursor round trips,
child file-descriptor isolation, complete stdout/stderr streams, and
verification that foreground rendering and data output never execute Git.

Apple's ASan runtime does not implement LeakSanitizer. Requesting
`detect_leaks=1` aborts before tests start, so the runner disables only that
unsupported feature on Darwin and uses the guarded allocator and macOS process
footprint accounting as complementary coverage.

## More aggressive options

The following are intentionally not enabled by default:

1. **Persistent Zsh coprocess:** removes nearly all per-prompt process startup
   and is the most likely route below 0.5 ms. It introduces crash recovery,
   protocol framing, shell-exit cleanup, and stale-process handling.
2. **Native Zsh module:** avoids IPC and process startup entirely, but couples
   releases to Zsh's module ABI and makes distribution and crash isolation much
   harder.
3. **Per-shell repository memoization:** can skip parent-directory `stat` calls
   until `chpwd`, but needs careful invalidation for deleted/replaced worktrees
   and offers only a small gain while process startup dominates.
4. **Profile-guided optimization:** may trim a few more instructions, but the
   native CPU experiment made p95 slightly worse. PGO is unlikely to justify a
   profile-generation release workflow while startup dominates.

SQLite, memory-mapped cache files, skipped `fsync`, `-ffast-math`, and a default
`-mcpu=native` build were rejected. They either add work to a tiny hot path,
reduce crash consistency, do not apply to this workload, or prevent one binary
from being safely distributed across supported Macs.

For a machine-local build, `-mcpu=native` remains available explicitly:

```sh
meson setup build-native --buildtype=release -Doptimization=3 \
  -Db_lto=true -Dc_args=-mcpu=native
```
