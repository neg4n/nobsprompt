# Custom prompts with detached mode

Detached mode turns `nbsp` into a small prompt-data backend. It retains the
features that are difficult to implement correctly—cache-only foreground
reads, asynchronous Git refresh, command timing, job tracking, redraw
correction, and external command editing—but it never reads or writes
`PROMPT` or `RPROMPT`.

Use exactly one mode in a shell:

```zsh
# Fixed, opinionated prompt:
eval "$(nbsp init zsh)"

# Or a user-owned prompt backed by nbsp:
eval "$(nbsp init zsh --detached)"
```

The first mode initialized in a shell wins. Put detached initialization after
NVM setup so `node_version` reflects the active version.

## Data available to Zsh

After each `precmd` and each completed asynchronous refresh, detached mode
atomically replaces the global `NBSP_DATA` associative array:

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

Consumers should require the schema versions they understand, address records
by key rather than position, and ignore unknown keys added by a compatible
future version.

On the first prompt in a repository, `git_present` may be `1` while
`git_valid` is `0`. The branch is still available when it can be read from
Git metadata, while the counters remain zero. The asynchronous refresh then
publishes a complete snapshot and redraws the prompt.

## Safely using dynamic text

Zsh treats `%` and control bytes specially during prompt expansion. Escape
path, branch, and other externally derived strings before inserting them:

```zsh
nbsp_prompt_escape "${NBSP_DATA[path]}"
local safe_path=$REPLY
```

`nbsp_prompt_escape` writes the result to `REPLY`, replaces control bytes with
`?`, and doubles `%`. It does not spawn a process.

For prompt functions that should rebuild after asynchronous Git updates, add
their names to `nbsp_data_update_functions`:

```zsh
my_prompt_update() {
  # Assign PROMPT and/or RPROMPT here.
}
nbsp_data_update_functions+=(my_prompt_update)
```

Callbacks run only after a complete schema has been parsed. Detached mode then
asks ZLE to redraw. Callback output is not hidden or redirected.

## Example 1: minimal path and branch

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

## Example 2: custom Git symbols

```zsh
eval "$(nbsp init zsh --detached)"

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

## Example 3: two lines with failure status

```zsh
eval "$(nbsp init zsh --detached)"

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

## Example 4: metadata on the right

```zsh
eval "$(nbsp init zsh --detached)"

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

## Example 5: optional Nerd Font style

The backend has no font requirement. If your terminal already uses a Nerd
Font, presentation code may use its glyphs:

```zsh
eval "$(nbsp init zsh --detached)"

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

## Example 6: prompt substitution

Callbacks can prepare escaped values while `PROMPT_SUBST` performs the final
expansion on every redraw:

```zsh
eval "$(nbsp init zsh --detached)"
setopt promptsubst

typeset -g MY_PATH MY_BRANCH
prepare_prompt_data() {
  nbsp_prompt_escape "${NBSP_DATA[path]}"
  MY_PATH=$REPLY
  nbsp_prompt_escape "${NBSP_DATA[git_branch]}"
  MY_BRANCH=$REPLY
}
nbsp_data_update_functions+=(prepare_prompt_data)

PROMPT='${MY_PATH}${MY_BRANCH:+ [${MY_BRANCH}]} %# '
```

Do not insert unescaped raw fields directly into a `PROMPT_SUBST` expression.

## Example 7: consume `nbsp data` directly

The readable format is useful for inspection and other programs:

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

For lossless Zsh parsing, use NUL records instead of command substitution:

```zsh
typeset -A data
while IFS= read -r -d '' key && IFS= read -r -d '' value; do
  data[$key]=$value
done < <(nbsp data --format nul)
```

Command substitution cannot safely preserve NUL delimiters. Never `eval` data
output.

## Example 8: terminal title and OSC wrappers

Detached mode leaves OSC sequences under your ownership:

```zsh
eval "$(nbsp init zsh --detached)"

title_prompt() {
  local path
  nbsp_prompt_escape "${NBSP_DATA[path]}"
  path=$REPLY

  # %{\e]0;...\a%} changes the terminal title without occupying prompt width.
  PROMPT=$'%{\e]0;'"${path}"$'\a%}'"%F{cyan}${path}%f %# "
}
nbsp_data_update_functions+=(title_prompt)
title_prompt
```

Async completion updates `NBSP_DATA` and requests a redraw. Nobsprompt does not
splice, replace, or interpret the OSC wrapper.

## Operational settings

Detached and opinionated modes share only operational configuration:

```zsh
NBSP_GIT_TIMEOUT_MS=1500
NBSP_CACHE_DIR="$HOME/Library/Caches/nbsp"
```

Colors, symbols, segment visibility, duration thresholds, `PROMPT`, and
`RPROMPT` belong entirely to custom prompt code.
