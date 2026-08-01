<a href="https://nobsprompt.pages.dev">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs-website/public/logo-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="docs-website/public/logo-light.svg">
    <img align="right" alt="nobsprompt logo" height="150" src="docs-website/public/logo-light.svg" width="150">
  </picture>
</a>

# nobsprompt

**nobsprompt**, the No BS prompt, is a native prompt backend for macOS and Zsh.
It collects shell and repository state without spawning Git or Node on the
foreground rendering path. That path still reads the current directory,
repository metadata, `NVM_BIN`, and a validated status cache.

```text
/U/i/D/p/nobsprompt [main +1 ~2 ?3 ^1] [node:22.14.0] [2.4s] [jobs:2] %
```

`nbsp` is written in C, links no third-party libraries, requires no daemon or
special font, and uses a versioned cache for detailed Git status. Completed
snapshots are published with atomic pathname replacement. Use the included
opinionated prompt as-is, or keep the backend and build the prompt yourself.

[Read the documentation](https://nobsprompt.pages.dev) or continue below for
the shortest route to a working prompt.

## Quick start

Requirements: macOS, Zsh 5.8 or newer, a C11 compiler, Git 2.25+, Meson 1.1+,
Ninja, Make, and Python 3.9 or newer. Expect is optional for normal builds; it
is required to run the four interactive PTY tests.

```sh
git clone --depth 1 --filter=blob:none --sparse --no-tags https://github.com/neg4n/nobsprompt.git && cd nobsprompt && git sparse-checkout set src tools tests bench doc docs
```

This skips the website project and videos. For the complete repository, use
`git clone https://github.com/neg4n/nobsprompt.git && cd nobsprompt` instead.

Before building, review the exact commit you checked out. The
[installation guide](https://nobsprompt.pages.dev/get-started) provides a
copyable, evidence-focused audit prompt for an AI coding agent. AI review can
improve visibility, but it cannot prove that software is safe.

```sh
make install
```

This installs the executable, man page, and MDX documentation sources under
`~/.local`. The `PREFIX` make variable can override that location when needed.

Put the executable on `PATH`, then choose one integration in `~/.zshrc`:

| Use | Zsh setup | Presentation |
| --- | --- | --- |
| Opinionated prompt | `eval "$(nbsp init zsh --autosuggest)"` | Fixed by `nbsp` |
| Detached mode | `eval "$(nbsp init zsh --detached --autosuggest)"` | Owned by your Zsh code |

The backend reads `NVM_BIN` during each collection, so this integration does
not have to follow NVM initialization. The Node segment reflects the value in
the environment when `nbsp` runs.

For a default local install:

```zsh
export PATH="$HOME/.local/bin:$PATH"
eval "$(nbsp init zsh --autosuggest)"
```

`PATH` is required so `nbsp init` can run; the generated script pins
`_NBSP_BIN` to that binary for later hooks. This enables the recommended
fish-like ghost text. Recent history handles
ordinary commands. For safely parseable `cd` paths, a bounded asynchronous
snapshot of the typed parent directory defines the candidate set, so history
paths absent from that snapshot are not offered as navigation targets.

> [!WARNING]
> Use only one autosuggestion engine. If `zsh-autosuggestions` or another
> ghost-text plugin is already active, omit `--autosuggest` and initialize with
> `eval "$(nbsp init zsh)"` instead. Nobsprompt detects common conflicts,
> disables its engine, and leaves the prompt working.

Each directory worker reads one level of the typed parent - even for nested paths
such as `~/Desktop/programming/w` - and subsequent matches use binary search over
the point-in-time snapshot. A child can still disappear before acceptance.
Directory-aware suggestions require exactly one nonempty static operand.
Relative, absolute, `./`, `../`, `~/`, nested, closed-quoted, and
backslash-escaped paths are supported. Variables, substitutions, globs
(including `^` and `#` under
`EXTENDED_GLOB`), operators, redirections, unmatched quotes, named directories,
and multiple operands remain history-only or Tab-completion cases.

Explicit `.`, `..`, `./…`, and `../…` operands resolve from `$PWD` without a
`CDPATH` search. For other relative operands with `POSIX_CD` off, the current
directory is scanned when Zsh's `cdpath`/`CDPATH` has no `.` or empty entry, or
when such an entry is first. With `POSIX_CD` on, it is scanned when `cdpath` is
empty or its first entry is `.` or empty; otherwise nobsprompt cannot guarantee
that `$PWD` is Zsh's first search root and does not enter directory-aware mode.
Right Arrow accepts a suggestion in native Emacs and Vi insert keymaps when its
existing binding is the standard `forward-char` or `vi-forward-char`; custom
bindings are never replaced. Tab remains Zsh completion and never accepts
nobsprompt ghost text.
See [Autosuggestions](https://nobsprompt.pages.dev/reference/autosuggestions)
for exact scope and compatibility.

Open a new terminal or run `exec zsh`.

## Two ways to use it

### Opinionated prompt

The built-in prompt is ordinary Zsh: it loads `NBSP_DATA` and assigns `PROMPT`
in a commented callback you can read and copy. It always shows the abbreviated
working directory, and adds Git state, a version derived from `NVM_BIN`,
commands lasting at least two seconds, background jobs, and exact nonzero exit
status only when relevant.

Its colors, symbols, segments, layout, duration threshold, and prompt character
are deliberately fixed in that file. See the
[opinionated prompt guide](https://nobsprompt.pages.dev/get-started/opinionated-prompt)
for the full source and segment rules.

Dynamic fields go through `nbsp_prompt_quote` for the current `PROMPT_PERCENT`,
`PROMPT_SUBST`, and `PROMPT_BANG` settings without changing those options.

### Detached mode

Detached mode installs the same timing, job tracking, asynchronous refresh,
redraw, and external-editor integration, but never reads or writes `PROMPT` or
`RPROMPT`:

```zsh
eval "$(nbsp init zsh --detached --autosuggest)"
```

It publishes prompt facts in the global `NBSP_DATA` associative array:

```zsh
print -r -- "${NBSP_DATA[path]}"
print -r -- "${NBSP_DATA[git_branch]}"
print -r -- "${NBSP_DATA[node_version]}"
```

Register a callback to rebuild your prompt after every successfully parsed,
complete data frame. A callback can therefore run when values are unchanged,
including after a failed asynchronous refresh leaves the previous valid cache
in place. Use `nbsp_prompt_quote` before inserting dynamic values into Zsh
prompt strings; it quotes for the current `PROMPT_PERCENT`, `PROMPT_SUBST`, and
`PROMPT_BANG` settings without changing those options.

The [detached mode guide](https://nobsprompt.pages.dev/detached-mode) includes
the complete schema and lifecycle, safe parsing rules, and practical layouts
from portable one-line prompts to right-side metadata, Nerd Font styling,
prompt substitution, and OSC terminal titles.

## How it works

Each foreground `prompt` or `data` collection starts with `getcwd(3)` and uses
that physical absolute path rather than the logical spelling in `$PWD`. If
`getcwd` fails, the command exits with status 1 and writes no prompt or data.
The collector then reads repository metadata, the resolved Git directory's
`HEAD`, `NVM_BIN`, and any valid cache snapshot. It does not start Git or Node.

The background refresh runs this command with repository-selecting Git
environment variables removed:

```text
git --no-optional-locks -C <root> --git-dir=<git-dir> --work-tree=<root> status --porcelain=v2 --branch --show-stash --untracked-files=normal --ignore-submodules=dirty --no-renames
```

The counters represent porcelain records. With normal untracked handling, an
untracked directory can be one record; submodule worktree dirt is ignored and
rename detection is disabled. Refresh re-reads `HEAD` and publishes only when
its branch still matches the collected branch. Foreground collection likewise
uses cached counters only when the cached branch matches the current direct
`HEAD` value, so a branch can appear with `...` while no coherent counter
snapshot is available.

The same collector is available to tooling through the versioned
[`nbsp data` protocol](https://nobsprompt.pages.dev/reference/data-protocol),
with percent-encoded line records and a raw NUL-framed format.

There is no daemon, database, configuration language, or prompt-format parser.
The built-in prompt owns presentation; detached consumers receive data and own
the resulting prompt completely, including any OSC sequences.

Read [internals](https://nobsprompt.pages.dev/internals) for the full
foreground, background refresh, cache, and redraw lifecycle.

## Shell behavior

Both modes track command duration, exit status, and job count through Zsh
hooks. They define the private `nbsp-edit-command-line` widget without
replacing a public `edit-command-line` widget. On each of the Emacs, Vi insert,
and Vi command keymaps, `Alt+E` is bound only when that key is undefined.
Editor selection uses the `:zle:edit-command-line` `editor` zstyle first, then
`$VISUAL`, `$EDITOR`, or `vi`. Multiline commands are supported. For a
whole-buffer edit, vi, vim, and nvim restore the cursor from a validated final
line-and-character report when the command returns to Zsh; if that report is
absent or invalid, or for other editors, the cursor is placed at the end.
Existing user and plugin bindings are preserved. See the
[external editor guide](https://nobsprompt.pages.dev/reference/external-editor)
for the complete behavior.

## Operational settings

An explicitly set `NBSP_CACHE_DIR` selects the cache root and must be an
absolute path; an invalid or insecure override fails closed instead of falling
back. Cache-dependent prompt facts then remain unavailable, while cache
mutation commands fail. Otherwise an absolute `$XDG_CACHE_HOME` selects
`$XDG_CACHE_HOME/nbsp`; a relative XDG value is ignored, and the fallback is
`$HOME/Library/Caches/nbsp`. The cache root and its `git` subdirectory must be
owned by the current user with mode `0700`. Cache and lock artifacts must be
owned, single-link regular files with mode `0600`; symlink path components are
rejected apart from the exact macOS system aliases for `/tmp` and `/var`.

Status publication fsyncs a completed temporary file before renaming it over
the cache pathname. This is atomic pathname replacement, not a claim that the
directory entry survives sudden power loss. `nbsp cache clear` snapshots the
matching `.cache` and `.cache.tmp.*` names and removes secure regular files
with those names, while leaving per-repository lock files in place. A
concurrent refresh can lose its temporary file and fail publication; the
preserved lock inode keeps later refreshes synchronized.

`NBSP_GIT_TIMEOUT_MS` controls the background Git timeout. Values from 50
through 60,000 ms are accepted; an absent or invalid value uses 1,500 ms.
These operational controls are shared by both modes. The built-in prompt has
no presentation environment variables; optional ghost text exposes only
`NBSP_AUTOSUGGEST_HIGHLIGHT_STYLE`.

`nbsp refresh --force` bypasses only the 250 ms duplicate-refresh debounce.
Locking, the timeout, and pathname-replacement cache publication still apply.

Exit status 0 covers success and benign refresh no-ops, including a
non-repository directory, debounce, or an already-held refresh lock. Status 2
means invalid command-line usage; status 1 means an operational,
serialization, cache, or non-timeout Git failure; and a Git timeout from
`refresh` returns 124. A `dirs` timeout terminates that process with `SIGALRM`
instead of returning 1.

## Performance

Generate a report for a specific binary and working directory rather than
relying on an unversioned result:

```sh
zsh bench/benchmark.zsh --output data.report ./build/nbsp data
zsh bench/benchmark.zsh --output dirs.report ./build/nbsp dirs
```

[Performance and memory](https://nobsprompt.pages.dev/internals/performance)
documents the measurement method, hot-path audit, verification suite, and
tradeoffs. Each format-2 report records mandatory binary and harness hashes,
machine and Zsh details, declared build metadata, workload/repository and cache
inputs, an unchanged before/after workload digest, exact invocation, warmup and
sample counts, aggregates, and all sorted samples. No latency or executable
size result is claimed here without its raw report and build provenance.

## Development

For the C project:

```sh
meson setup build --buildtype=debug
meson compile -C build
meson test -C build --print-errorlogs
```

With Expect installed, the default `zsh_tests=auto` setup registers four PTY
tests. Use `-Dzsh_tests=enabled` to require Expect and fail configuration when
it is missing, or `-Dzsh_tests=disabled` to omit those four tests explicitly.

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
