# nobsprompt

the **No BS prompt** aka **nobsprompt** aka `nbsp` is a small, opinionated prompt for macOS and Zsh. It is written in C,
has no third-party runtime dependencies, uses ASCII symbols, and keeps Git off
the foreground rendering path.

```text
/U/i/D/p/nobsprompt [main +1 ~2 ?3 ^1] [node:22.14.0] [2.4s] [jobs:2] %
```

## Why

General-purpose prompts accumulate format languages, runtime probes, patched
font requirements, and dozens of modules. The visible delay usually comes from
filesystem scans and child processes rather than from drawing colored text.

`nbsp` deliberately supports only:

- a working directory with parent segments abbreviated and the final segment expanded;
- branch plus staged, modified, untracked, conflicted, ahead/behind, and stash counts;
- the active NVM version, derived from `NVM_BIN` without running Node;
- command duration, background jobs, and the exact nonzero exit status.

Successful commands keep the prompt clean. A failure prefixes the prompt
character with a compact red status, such as `e1%` or `e127%`.

The branch is read directly from `.git/HEAD`. Detailed status comes from an
atomic cache while `git status --porcelain=v2` runs in the background. ZLE
redraws the prompt when that refresh completes. There is no daemon, SQLite
database, TOML parser, or Nerd Font prerequisite.

## Install

Requirements are macOS, Zsh 5.8 or newer, a C11 compiler, Git, Meson 1.1+, and
Ninja.

```sh
make test
make install
```

This installs `nbsp` to `~/.local/bin` and its man page to
`~/.local/share/man/man1`. To use another prefix, run for example
`make install PREFIX=/opt/homebrew`.

Add these lines to `~/.zshrc`, after NVM initialization:

```zsh
export PATH="$HOME/.local/bin:$PATH"
eval "$(nbsp init zsh)"
```

Restart Zsh with `exec zsh`, or open a new terminal. If `~/.local/bin` is
already on `PATH`, omit the first line.

## Configuration

Set overrides before `nbsp init zsh`. The integration applies and exports the
defaults for the C renderer.

```zsh
NBSP_COLOR_PATH=default
NBSP_COLOR_GIT=default
NBSP_COLOR_NODE=green
NBSP_COLOR_META=yellow
NBSP_COLOR_OK=none
NBSP_COLOR_ERROR=red
NBSP_PROMPT_CHAR='%#'
NBSP_DURATION_THRESHOLD_MS=2000
NBSP_GIT_TIMEOUT_MS=1500
NBSP_SHOW_GIT=1
NBSP_SHOW_NVM=1
NBSP_SHOW_JOBS=1

eval "$(nbsp init zsh)"
```

Colors are basic Zsh color names, `default`, `none`, or numbers from 0 through
255. Path and Git use `default` so they exactly match the terminal's normal
foreground instead of relying on a palette's interpretation of white. The
default success character uses Zsh's native `%#` expansion: `%` for a regular
shell and `#` for a privileged shell. Set `NBSP_PROMPT_CHAR='$'` to override it
with a dollar prompt. There is no
custom format language. Dynamic paths and branch names are sanitized before
Zsh prompt expansion.

Cache files live in `$NBSP_CACHE_DIR`, `$XDG_CACHE_HOME/nbsp`, or
`~/Library/Caches/nbsp`, in that order. `nbsp cache clear` removes them. `nbsp`
does not change repository Git configuration; users with very large worktrees
may independently enable Git's untracked cache or built-in FSMonitor.

`nbsp refresh --force` skips only the 250 ms duplicate-refresh debounce. The
Zsh integration uses it when a refresh that started before a foreground
command must be followed by a post-command snapshot. Locking, timeout, and
atomic cache publication remain unchanged.

## Performance

Foreground rendering performs directory metadata reads and a small cache read,
but never starts Git or Node. Run the included dependency-free benchmark after
a release build:

```sh
zsh bench/benchmark.zsh ./build/nbsp
```

The project target is a warm p95 below 5 ms on the development Mac. Background
Git work has a 1500 ms default timeout and preserves the last valid snapshot on
failure.

See [PERFORMANCE.md](PERFORMANCE.md) for the measured memory/latency audit,
applied hot-path optimizations, sanitizer coverage, and evaluation of more
aggressive daemon, Zsh-module, memoization, and PGO approaches.

## Development

```sh
meson setup build --buildtype=debug
meson compile -C build
meson test -C build --print-errorlogs
```

The interactive integration test uses macOS's built-in `/usr/bin/expect` to
exercise real ZLE callbacks, wrapped editing buffers, and stdout/stderr
preservation.

Run the full memory-safety suite with AddressSanitizer, UndefinedBehaviorSanitizer,
macOS guarded-allocation diagnostics, and the parser fuzzer:

```sh
NBSP_FUZZ_ITERATIONS=250000 sh tests/run_memory_checks.sh
```

Apple's AddressSanitizer runtime does not provide LeakSanitizer, so the runner
disables that unsupported switch on macOS and compensates with guarded malloc,
scribble-before/after allocation, per-operation heap checks, and measured peak
memory. ASan still checks out-of-bounds access, use-after-free/scope/return,
double-free, and the instrumented libc string operations.

The deterministic mutation fuzzer is optional in normal builds and can also be
run directly. It has no dependency on Apple's separately packaged libFuzzer
runtime:

```sh
meson setup build-fuzz -Dfuzzing=true -Db_lundef=false
meson compile -C build-fuzz fuzz-parsers
./build-fuzz/tests/fuzz-parsers 500000
```

The source layout follows the same compact style as
[`image-square-wizard`](https://github.com/neg4n/image-square-wizard): one root
Meson project, focused C modules, a hand-written man page, and direct tests.

## License

MIT
