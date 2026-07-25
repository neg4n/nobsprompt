# nobsprompt

**nobsprompt**, the No BS prompt, is an extremely lightweight prompt backend
for macOS and Zsh. It collects useful shell and repository state without
putting Git or Node on the foreground rendering path.

```text
/U/i/D/p/nobsprompt [main +1 ~2 ?3 ^1] [node:22.14.0] [2.4s] [jobs:2] %
```

`nbsp` is written in C, links no third-party libraries, requires no daemon or
special font, and uses an atomic cache for detailed Git status. Use the
included opinionated prompt as-is, or keep the backend and build the prompt
yourself.

[Read the documentation](https://nobsprompt.pages.dev) or continue below for
the shortest route to a working prompt.

## Quick start

Requirements: macOS, Zsh 5.8 or newer, a C11 compiler, Git, Meson 1.1+, and
Ninja.

```sh
make test
make install
```

This installs the executable, man page, and Markdown documentation under
`~/.local`. The `PREFIX` make variable can override that location when needed.

Put the executable on `PATH`, then choose one integration in `~/.zshrc` after
NVM initialization:

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

## Two ways to use it

### Opinionated prompt

The built-in prompt always shows the abbreviated working directory. It adds
Git state, the active NVM version, commands lasting at least two seconds,
background jobs, and exact nonzero exit status only when relevant.

Its colors, symbols, segments, layout, duration threshold, and prompt character
are deliberately fixed. See the
[opinionated prompt guide](https://nobsprompt.pages.dev/get-started/opinionated-prompt)
for its complete behavior.

### Custom prompt backend

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

Register a callback to rebuild your prompt whenever fresh data arrives. Use
`nbsp_prompt_escape` before inserting dynamic values into Zsh prompt strings.

For other consumers, the same facts are available without Zsh integration:

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

The readable format percent-encodes exceptional bytes. Use
`nbsp data --format nul` for lossless machine parsing. Never `eval` data
output.

The [custom prompt guide](https://nobsprompt.pages.dev/custom-prompts) includes
the complete schema and lifecycle, safe parsing rules, and practical layouts
from portable one-line prompts to right-side metadata, Nerd Font styling,
prompt substitution, and OSC terminal titles.

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

Read [internals](https://nobsprompt.pages.dev/internals) for the full
foreground, background refresh, cache, and redraw lifecycle.

## Shell behavior

Both modes track command duration, exit status, and job count through Zsh
hooks. They bind `Alt+E`, when that key is free, to edit the current command in
`$VISUAL`, `$EDITOR`, or `vi`. Multiline commands are supported, and vi, vim,
and nvim restore the cursor to the final edited line and character when the
command returns to Zsh. Other editors place it at the end of the edited
command. Existing user and plugin bindings are preserved. See the
[external editor guide](https://nobsprompt.pages.dev/reference/external-editor)
for the complete behavior.

## Operational settings

`NBSP_CACHE_DIR` overrides the cache root. Otherwise `nbsp` uses
`$XDG_CACHE_HOME/nbsp` or `~/Library/Caches/nbsp`, in that order.
`nbsp cache clear` removes cache and lock files owned by `nbsp`.

`NBSP_GIT_TIMEOUT_MS` controls the background Git timeout and defaults to
1500 ms. These are operational controls shared by both modes; there are no
presentation environment variables.

`nbsp refresh --force` bypasses only the 250 ms duplicate-refresh debounce.
Locking, the timeout, and atomic cache publication still apply.

## Performance

The foreground path is designed to remain small and predictable. The project
target is a warm p95 below 5 ms on the development Mac:

```sh
zsh bench/benchmark.zsh ./build/nbsp
zsh bench/benchmark.zsh ./build/nbsp data
```

[Performance and memory](https://nobsprompt.pages.dev/internals/performance)
contains measured latency and memory results, the hot-path audit, sanitizer
and fuzzing coverage, and the evaluation of more complex alternatives.

## Development

For the C project:

```sh
meson setup build --buildtype=debug
meson compile -C build
meson test -C build --print-errorlogs
```

The documentation content lives in `docs/`. The separate Blume project lives
in `docs-website/`. Use its pinned Node version and pnpm through Corepack:

```sh
cd docs-website
corepack enable
pnpm install --frozen-lockfile
pnpm docs:dev
```

Validate the same static build used by Cloudflare Pages:

```sh
pnpm run docs:ci
```

See [Documentation deployment](docs-website/DOCS_DEPLOYMENT.md) for the
one-time Cloudflare Pages Git integration setup and
[Brand assets](docs-website/BRAND_ASSETS.md) for the future logo file map. The
deployed site is fully static and does not use Workers.

## License

MIT
