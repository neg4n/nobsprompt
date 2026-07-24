# nobsprompt

**nobsprompt**, the No BS prompt (or `nbsp`), is an extremely lightweight prompt
backend for macOS and Zsh. It collects useful shell and repository state without
putting Git or Node on the foreground rendering path. Use the included
opinionated prompt as-is, or use the same backend to build your own.

```text
/U/i/D/p/nobsprompt [main +1 ~2 ?3 ^1] [node:22.14.0] [2.4s] [jobs:2] %
```

`nbsp` is written in C, links no third-party libraries, requires no daemon or
special font, and uses an atomic cache for detailed Git status.

## Install

Requirements: macOS, Zsh 5.8 or newer, a C11 compiler, Git, Meson 1.1+, and
Ninja.

```sh
make test
make install
```

This installs the executable to `~/.local/bin`, the man page to
`~/.local/share/man/man1`, and the custom-prompt guide to
`~/.local/share/doc/nobsprompt`. Set another prefix when needed:

```sh
make install PREFIX=/opt/homebrew
```

Ensure the executable is on `PATH`, then choose one integration in `~/.zshrc`
after NVM initialization:

| Use | Zsh setup | Presentation |
| --- | --- | --- |
| Ready-made prompt | `eval "$(nbsp init zsh)"` | Fixed by `nbsp` |
| Custom prompt | `eval "$(nbsp init zsh --detached)"` | Owned by your Zsh code |

For a default local install:

```zsh
export PATH="$HOME/.local/bin:$PATH"
eval "$(nbsp init zsh)"
```

Open a new terminal or run `exec zsh`.

## The opinionated prompt

The built-in prompt always shows the abbreviated working directory and, when
available:

- Git branch, staged, modified, untracked, conflicted, ahead, behind, and stash
  counts;
- the active NVM version, derived from `NVM_BIN` without starting Node;
- commands lasting at least two seconds;
- background jobs;
- the exact nonzero exit status.

Successful commands keep the prompt clean. A failure prefixes the prompt
character with a compact red status such as `e1%` or `e127%`.

Its colors, symbols, segments, duration threshold, and `%#` prompt character
are intentionally fixed. Use the backend mode when you want to control
presentation.

## Build your own prompt

Detached mode installs the same timing, job tracking, asynchronous refresh,
redraw, and external-editor integration, but never reads or writes `PROMPT` or
`RPROMPT`:

```zsh
eval "$(nbsp init zsh --detached)"
```

It publishes prompt facts in the global `NBSP_DATA` associative array:

```zsh
print -r -- "${NBSP_DATA[path]}"
print -r -- "${NBSP_DATA[git_branch]}"
print -r -- "${NBSP_DATA[node_version]}"
```

Register a callback to rebuild your prompt whenever fresh data arrives. The
backend includes `nbsp_prompt_escape` for safely inserting dynamic values into
Zsh prompt strings.

The same facts are available without the Zsh integration:

```console
$ nbsp data
schema_version=1
cwd=/Users/example/project
path=/U/e/project
status=0
duration_ms=0
jobs=0
node_version=22.14.0
git_present=1
git_valid=1
git_branch=main
...
```

The readable format percent-encodes exceptional bytes. For lossless
machine parsing, use `nbsp data --format nul`; never `eval` data output.

See [Build a custom Zsh prompt](doc/custom-prompts.md) for a working minimal
prompt, the complete schema and lifecycle, safe parsing rules, and layouts
ranging from portable one-line prompts to right-side metadata, Nerd Font
styling, prompt substitution, and OSC terminal titles.

## How it works

Foreground rendering reads directory metadata and a small cache. It never
starts Git or Node.

The branch is read directly from `.git/HEAD`. Detailed status is produced by
`git status --porcelain=v2` in a background process, published through an
atomic cache, and picked up by ZLE on redraw. The first prompt in a repository
can therefore show a branch before its counters arrive.

There is no daemon, database, configuration language, or prompt-format parser.
The built-in prompt owns presentation; detached consumers receive data and own
the resulting prompt completely, including any OSC sequences.

## Shell integration

Both modes track command duration, exit status, and job count through Zsh hooks.
They also bind `Alt+E`, when that key is free, to edit the current command in
`$VISUAL`, `$EDITOR`, or `vi`. Multiline buffers are supported and the command
is returned to Zsh without being executed. `vi`, `vim`, and `nvim` also
preserve the editor cursor position when it can be reported safely.

Existing user or plugin bindings are not replaced. See `man nbsp` for the
complete integration behavior.

## Operational settings

`NBSP_CACHE_DIR` overrides the cache root. Otherwise `nbsp` uses
`$XDG_CACHE_HOME/nbsp` or `~/Library/Caches/nbsp`, in that order.
`nbsp cache clear` removes cache and lock files owned by `nbsp`.

`NBSP_GIT_TIMEOUT_MS` controls the background Git timeout and defaults to
1500 ms. These are operational controls shared by both modes; there are no
presentation environment variables.

`nbsp refresh --force` bypasses only the 250 ms duplicate-refresh debounce.
Locking, the timeout, and atomic cache publication still apply.

## Performance and development

The foreground path is designed to remain small and predictable. The project
target is a warm p95 below 5 ms on the development Mac:

```sh
zsh bench/benchmark.zsh ./build/nbsp
zsh bench/benchmark.zsh ./build/nbsp data
```

[PERFORMANCE.md](PERFORMANCE.md) contains measured latency and memory results,
the hot-path audit, sanitizer and fuzzing coverage, and the evaluation of more
complex alternatives.

For a debug build:

```sh
meson setup build --buildtype=debug
meson compile -C build
meson test -C build --print-errorlogs
```

## Documentation

- [`man nbsp`](doc/nbsp.1) - commands, configuration, editor behavior, and exit
  statuses
- [Build a custom Zsh prompt](doc/custom-prompts.md) - backend schema, lifecycle,
  safety, and complete prompt recipes
- [Performance](PERFORMANCE.md) - benchmarks, memory analysis, and validation

## License

MIT
