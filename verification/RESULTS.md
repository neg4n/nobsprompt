# Apple Silicon acceptance results

Measured on macOS 26.6 (Darwin 25.6.0), arm64, Zig 0.16.0. The deployment
minimum is macOS 13. CPU targets are generic/baseline. C uses Apple Clang 21
-O3 with LTO; Zig uses ReleaseSafe. Neither compiler is inferred to be faster
from these machine-local measurements.

Three interleaved matched runs per workload, 100 warmups and 1,000 samples
per run. Each table statistic is the arithmetic mean of its three per-run
statistics. Raw reports and five memory samples per binary are retained in
`release-arm64/` within [raw-measurements.tar.gz](raw-measurements.tar.gz). Positive deltas mean growth.

| Workload | C mean ms | Zig mean ms | Mean delta | p50 delta | p95 delta | RSS growth | Footprint growth |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| plain | 1.343142 | 1.297791 | -3.38% | -4.10% | -7.70% | +1.12% | +0.00% |
| nested | 1.409702 | 1.395905 | -0.98% | -0.87% | -1.49% | +0.00% | -3.08% |
| valid | 1.419658 | 1.415669 | -0.28% | -0.68% | +0.19% | +0.00% | -3.08% |
| missing | 1.392981 | 1.401804 | +0.63% | -0.81% | +2.96% | +0.00% | -3.08% |
| invalid | 1.412174 | 1.399265 | -0.91% | -1.05% | -0.77% | +0.00% | -3.08% |
| detached | 1.426645 | 1.408085 | -1.30% | -1.53% | -1.11% | +0.00% | -3.08% |
| worktree | 1.477148 | 1.417359 | -4.05% | -2.89% | -4.38% | +0.00% | -3.08% |
| dirs | 1.465695 | 1.407628 | -3.96% | -3.87% | -3.79% | +5.75% | +3.28% |

Latency and peak RSS/footprint gates: PASS on this Apple Silicon machine.

Stripped sizes (`strip -x`): C 70,720 bytes; Zig 152,152 bytes. Size is
informational, per the user’s revised constraint. Installed Zig binary:
153,192 bytes. Explicit allocator counts, bytes and live peaks appear in
the workload `.allocations` files, separately from process memory.

Native Intel runtime, matched latency and memory gates: PENDING. Intel
cross-compilation passed; it is not native runtime evidence. GitHub default
branch and Cloudflare production branch remain unchanged.

## Functional verification

- Unit and allocation-failure tests: 22 passed in Debug and ReleaseSafe.
- Darwin malloc diagnostics: unit checks passed.
- Raw C/Zig differential output and exit checks: passed, including both cache directions.
- CLI, Zsh syntax, protocol, quoting/options and process regression checks: passed.
- Full memory runner with required four PTY cases and 250,000 mutations: passed.
- Staged installation and canonical prompt template: passed.
- Debug, ReleaseSafe, ReleaseFast and ReleaseSmall compilation: passed.
- Native Apple Silicon checks and Intel compilation checks: passed.
- Blume docs:ci: passed; 1,064 static audits, zero errors/warnings. External
  network/deployment checks were not part of the static audit.

The final binary SHA-256 is `9489b8426f13299cc7ad1e5e551ab94efe4f1870655f66906f07334c46da9abe`.
The source manifest records the checked native and shell sources. Additional
allocation-failure probes were rerun in Debug, ReleaseSafe and with Darwin
heap diagnostics after the initial Debug phase of the full memory runner.
