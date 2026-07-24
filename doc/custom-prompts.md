# Build a custom Zsh prompt

Detached mode turns `nbsp` into a prompt-data backend for Zsh. It retains the
cache-only foreground path, asynchronous Git refresh, command timing, job
tracking, redraw correction, and external command editing, while leaving
`PROMPT` and `RPROMPT` entirely under your control.

Use exactly one integration in a shell:

```zsh
# Ready-made, opinionated prompt:
eval "$(nbsp init zsh)"

# User-owned prompt backed by nbsp:
eval "$(nbsp init zsh --detached)"
```

The first mode initialized in a shell wins. Put initialization after NVM setup
so `node_version` reflects the active version.

## Start with a minimal prompt

Add detached initialization and a prompt callback to `~/.zshrc`:

```zsh
eval "$(nbsp init zsh --detached)"

minimal_prompt() {
  local path branch=

  nbsp_prompt_escape "${NBSP_DATA[path]}"
  path=$REPLY

  if [[ ${NBSP_DATA[git_present]} == 1 ]]; then
    nbsp_prompt_escape "${NBSP_DATA[git_branch]}"
    branch=" [$REPLY]"
  fi

  PROMPT="${path}${branch} %# "
}

nbsp_data_update_functions+=(minimal_prompt)
minimal_prompt
```

The explicit final call prepares the initial prompt. The registered callback
rebuilds it after later data updates, including completed asynchronous Git
refreshes.

## Integration lifecycle

After every `precmd`, detached mode replaces the global `NBSP_DATA` associative
array with one complete schema. A background Git refresh can subsequently
replace it again and ask ZLE to redraw.

To rebuild presentation when that happens, append function names to
`nbsp_data_update_functions`:

```zsh
my_prompt_update() {
  # Assign PROMPT and/or RPROMPT here.
}

nbsp_data_update_functions+=(my_prompt_update)
my_prompt_update
```

Callbacks run only after a complete schema has been parsed. Their output is
not hidden or redirected.

Detached mode does not inspect, splice, or restore your prompt strings. Your
code owns colors, symbols, layout, duration thresholds, prompt substitution,
and OSC wrappers.

## Safely embed dynamic text

Zsh treats `%` and control bytes specially during prompt expansion. Escape
paths, branch names, and other externally derived strings before inserting
them:

```zsh
nbsp_prompt_escape "${NBSP_DATA[path]}"
local safe_path=$REPLY
```

`nbsp_prompt_escape` writes the result to `REPLY`, replaces control bytes with
`?`, and doubles `%`. It does not start a process.

Do not insert unescaped raw fields into `PROMPT`, `RPROMPT`, or a
`PROMPT_SUBST` expression.

## Data reference

`NBSP_DATA` contains these keys:

| Key | Meaning |
| --- | --- |
| `schema_version` | Data contract version, currently `1` |
| `cwd` | Full working directory |
| `path` | Abbreviated display path |
| `status` | Previous command's exact exit status |
| `duration_ms` | Previous command duration in milliseconds |
| `jobs` | Background job count |
| `node_version` | Active NVM version, or empty |
| `git_present` | `1` when the directory is inside a repository |
| `git_valid` | `1` when status counters came from a valid cache snapshot |
| `git_branch` | Branch name or short detached commit |
| `git_updated_ms` | Snapshot wall-clock timestamp in milliseconds |
| `git_staged` | Staged path count |
| `git_modified` | Modified path count |
| `git_untracked` | Untracked path count |
| `git_conflicted` | Conflicted path count |
| `git_ahead` | Commits ahead of upstream |
| `git_behind` | Commits behind upstream |
| `git_stashes` | Stash count |

Consumers should require a schema version they understand, address records by
key rather than position, and ignore unknown keys added by a compatible future
version.

On the first prompt in a repository, `git_present` may be `1` while
`git_valid` is `0`. The branch is still available when it can be read directly
from Git metadata, while status counters remain zero. The asynchronous refresh
then publishes a complete snapshot and redraws the prompt.

## Prompt recipes

Each recipe below assumes `eval "$(nbsp init zsh --detached)"` has already run.
Use one recipe as your prompt callback, or combine the presentation logic
deliberately.

### Detailed Git state

```zsh
git_prompt() {
  local path git= branch
  nbsp_prompt_escape "${NBSP_DATA[path]}"
  path=$REPLY

  if [[ ${NBSP_DATA[git_present]} == 1 ]]; then
    nbsp_prompt_escape "${NBSP_DATA[git_branch]}"
    branch=$REPLY
    git=" %F{cyan}git:${branch}%f"
    (( NBSP_DATA[git_staged] ))     && git+=" %F{green}+${NBSP_DATA[git_staged]}%f"
    (( NBSP_DATA[git_modified] ))   && git+=" %F{yellow}~${NBSP_DATA[git_modified]}%f"
    (( NBSP_DATA[git_untracked] ))  && git+=" %F{blue}?${NBSP_DATA[git_untracked]}%f"
    (( NBSP_DATA[git_conflicted] )) && git+=" %F{red}!${NBSP_DATA[git_conflicted]}%f"
    (( NBSP_DATA[git_ahead] ))      && git+=" ↑${NBSP_DATA[git_ahead]}"
    (( NBSP_DATA[git_behind] ))     && git+=" ↓${NBSP_DATA[git_behind]}"
    (( NBSP_DATA[git_stashes] ))    && git+=" ≡${NBSP_DATA[git_stashes]}"
    [[ ${NBSP_DATA[git_valid]} == 0 ]] && git+=" %F{yellow}…%f"
  fi

  PROMPT="%F{magenta}${path}%f${git} %# "
}

nbsp_data_update_functions+=(git_prompt)
git_prompt
```

### Two lines with failure status

```zsh
two_line_prompt() {
  local path state=
  nbsp_prompt_escape "${NBSP_DATA[path]}"
  path=$REPLY

  if (( NBSP_DATA[status] )); then
    state="%F{red}exit ${NBSP_DATA[status]}%f "
  fi

  PROMPT="%F{blue}${path}%f
${state}%# "
}

nbsp_data_update_functions+=(two_line_prompt)
two_line_prompt
```

### Metadata on the right

```zsh
right_prompt() {
  local path right=
  nbsp_prompt_escape "${NBSP_DATA[path]}"
  path=$REPLY
  PROMPT="${path} %# "

  [[ -n ${NBSP_DATA[node_version]} ]] &&
    right+="%F{green}node ${NBSP_DATA[node_version]}%f"
  (( NBSP_DATA[duration_ms] >= 500 )) &&
    right+=" %F{yellow}${NBSP_DATA[duration_ms]}ms%f"
  (( NBSP_DATA[jobs] )) &&
    right+=" %F{cyan}jobs ${NBSP_DATA[jobs]}%f"
  RPROMPT=$right
}

nbsp_data_update_functions+=(right_prompt)
right_prompt
```

### Optional Nerd Font style

The backend has no font requirement. If your terminal already uses a Nerd
Font, presentation code can use its glyphs:

```zsh
nerd_prompt() {
  local path branch=
  nbsp_prompt_escape "${NBSP_DATA[path]}"
  path=$REPLY

  if [[ ${NBSP_DATA[git_present]} == 1 ]]; then
    nbsp_prompt_escape "${NBSP_DATA[git_branch]}"
    branch=" %F{cyan} $REPLY%f"
  fi

  PROMPT="%F{blue} ${path}%f${branch}
%F{magenta}❯%f "
}

nbsp_data_update_functions+=(nerd_prompt)
nerd_prompt
```

Replace ``, ``, and `❯` with `dir`, `git`, and `>` for a portable version.

### Prompt substitution

Callbacks can prepare escaped values while `PROMPT_SUBST` performs final
expansion on every redraw:

```zsh
setopt promptsubst

typeset -g MY_PATH MY_BRANCH
prepare_prompt_data() {
  nbsp_prompt_escape "${NBSP_DATA[path]}"
  MY_PATH=$REPLY
  nbsp_prompt_escape "${NBSP_DATA[git_branch]}"
  MY_BRANCH=$REPLY
}

nbsp_data_update_functions+=(prepare_prompt_data)
prepare_prompt_data

PROMPT='${MY_PATH}${MY_BRANCH:+ [${MY_BRANCH}]} %# '
```

### Terminal title and OSC wrappers

```zsh
title_prompt() {
  local path
  nbsp_prompt_escape "${NBSP_DATA[path]}"
  path=$REPLY

  # %{\e]0;...\a%} changes the title without occupying prompt width.
  PROMPT=$'%{\e]0;'"${path}"$'\a%}'"%F{cyan}${path}%f %# "
}

nbsp_data_update_functions+=(title_prompt)
title_prompt
```

Async completion updates `NBSP_DATA` and requests a redraw. `nbsp` does not
replace or interpret the OSC wrapper.

## Consume `nbsp data` directly

The line format is convenient for inspection and programs that do not need raw
values:

```console
$ nbsp data --status 1 --duration-ms 2400 --jobs 2
schema_version=1
cwd=/Users/example/project
path=/U/e/project
status=1
...
```

Values use percent encoding, so common values stay readable while spaces,
newlines, `%`, `=`, and other exceptional bytes remain unambiguous.

For lossless Zsh parsing, use alternating NUL-delimited keys and values:

```zsh
typeset -A data
while IFS= read -r -d '' key && IFS= read -r -d '' value; do
  data[$key]=$value
done < <(nbsp data --format nul)
```

Command substitution cannot safely preserve NUL delimiters. Never `eval` data
output.

Direct consumers own their update schedule. The detached Zsh integration is
what provides command lifecycle tracking, asynchronous refresh callbacks, and
automatic redraws.

## Operational settings

Detached and opinionated modes share only operational configuration:

```zsh
NBSP_GIT_TIMEOUT_MS=1500
NBSP_CACHE_DIR="$HOME/Library/Caches/nbsp"
```

Colors, symbols, segment visibility, duration thresholds, `PROMPT`, and
`RPROMPT` belong entirely to custom prompt code.
