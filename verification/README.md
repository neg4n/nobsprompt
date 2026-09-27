# Zig rewrite verification

The functional contract is in [CONTRACT.md](CONTRACT.md). README, MDX pages and
the man page govern behavior. The shell sources remain canonical; the documented
prompt template is checked byte for byte against its source.

The rewrite uses exactly Zig 0.16.0, ReleaseSafe, the baseline CPU and macOS 13
minimum. The application has no package dependencies. Zig's [release notes](https://ziglang.org/download/0.16.0/release-notes.html),
[allocator guidance](https://ziglang.org/documentation/0.16.0/#Choosing-an-Allocator)
and [build-system documentation](https://ziglang.org/learn/build-system/) describe
the APIs used here. Both macOS architectures are supported by the toolchain;
native application tests are still required on each. Pre-1.0 compiler upgrades
must repeat this verification, even when upgrading to another stable release.

## Reproduce native checks

```sh
zig build check
zig build test -Dzsh_tests=enabled
zig build memory-check
zig build -Dtarget=x86_64-macos.13.0 --prefix /tmp/nbsp-intel
DESTDIR=/tmp/nbsp-stage zig build install --prefix /usr/local
```

The memory runner requires Expect by default, runs Debug and ReleaseSafe tests,
then Debug with Darwin malloc diagnostics, then 250,000 deterministic mutations.
Unit tests use `std.testing.allocator` and allocation-failure injection. Mutation
tests use a DebugAllocator. `NBSP_ZSH_TESTS=auto|enabled|disabled` and
`NBSP_FUZZ_ITERATIONS` retain the documented overrides. Runtime checks and these
heap diagnostics are not compiler sanitizers or a whole-program leak detector.

## Frozen C reference

The original source revision is
`56db8ce9cce0ea50345d66288c76dfca30f67f47`. `main` retains it. The original release
binary remains in the ignored `build-zig-reference/` directory. The reports in
`c-baseline/` were captured before removing C sources, with Apple Clang 21, -O3
and LTO. Its default deployment target was macOS 26 and CPU Apple M1.

For matched acceptance, the same frozen C sources were rebuilt with macOS 13
and a generic CPU in the ignored `build-zig-reference-matched/` directory.
Production native builds do not invoke the old build tools. Reproducing the C
comparison alone requires the historical Meson/Ninja/Python/Clang toolchain:

```sh
reference_source=$(mktemp -d /tmp/nbsp-c-reference.XXXXXX)
git archive 56db8ce9cce0ea50345d66288c76dfca30f67f47 \
  src tests tools doc docs meson.build meson_options.txt LICENSE README.md | \
  tar -x -C "$reference_source"
meson setup build-zig-reference-matched "$reference_source" \
  --buildtype=release -Db_lto=true -Dzsh_tests=disabled \
  -Dc_args='-mmacosx-version-min=13.0 -mcpu=generic' \
  -Dc_link_args='-mmacosx-version-min=13.0'
meson compile -C build-zig-reference-matched
sh tests/differential.sh build-zig-reference-matched/nbsp zig-out/bin/nbsp
```

On Intel, use `-march=x86-64 -mtune=generic` in place of `-mcpu=generic`.
The differential script compares raw output and exit status. It controls cache
publication so both producers read the same timestamps; no timestamp
normalization is needed. It verifies C→Zig and Zig→C cache compatibility.
Embedded shell output is compared with the canonical sources separately, since
executable paths and the language-specific comment necessarily differ.

## Raw evidence

All raw measurements, including exploratory runs, are retained byte for byte in
[raw-measurements.tar.gz](raw-measurements.tar.gz). Extract them from the repository
root when inspecting individual format-2 reports:

```sh
tar -xzf verification/raw-measurements.tar.gz -C verification
```

The extracted directories are ignored. Logs, source checksums and RESULTS.md
remain directly reviewable. `release-arm64/` contains final acceptance reports.

## Matched measurements

```sh
zig build
zig build measurement-tools
zsh verification/compare.zsh build-zig-reference-matched/nbsp \
  zig-out/bin/nbsp verification/release-arm64 1000
```

The script creates isolated fixtures, runs three interleaved pairs per workload
(100 warmups, 1,000 measured samples per run), and retains every format-2 raw
report. Within each workload, both binaries use the same physical directory and
unchanged cache snapshots. Git and Node are not benchmarked as foreground
subprocesses. Five separate `/usr/bin/time -l` measurements per binary record
peak resident memory and Apple's peak memory footprint. macOS may require
permission to query resource counters.

The table in RESULTS.md compares the arithmetic mean of the three per-run
statistics, preserving the individual reports for inspection. The latency gate
is at most 5% growth for mean, p50 and p95. Peak process memory may grow by at most
10%. Stripped executable size is recorded but has no strict gate, following the
user's later instruction. Small latency differences are observations on this
machine, not evidence that Zig inherently improves performance.

`.allocations` files count explicit backend allocations through a forwarding
wrapper around c_allocator, including successful growth and peak live requested
bytes. They exclude libc-internal allocations, process startup and serialization
(which uses fixed buffered output). They are diagnostic measurements, separate
from whole-process memory. The frozen C allocator was not instrumented.

Exploratory reports in `zig/`, `matched/`, `final-matched/` and `acceptance-arm64/` predate the final
cache-traversal optimization or matched C target. They do not establish the
acceptance result. One exploratory missing-cache p95 comparison exceeded 5%;
it was followed by removing component allocations and repeating matched runs.

## Promotion

Native Intel runtime and matched performance evidence is pending. Cross-compiled
Intel artifacts are compilation evidence only. Do not promote the branch based
on Apple Silicon results alone.

After native Intel gates pass, change GitHub's default branch to
`codex/zig-rewrite`, keep `main` as the C reference, transfer branch protection,
and verify fresh clone/install instructions. Coordinate Cloudflare Pages'
production branch separately; it still tracks `main`. Check the deployed docs
and retain the frozen C revision for rollback. No remote branch setting or
Cloudflare production setting has been changed by this rewrite.
