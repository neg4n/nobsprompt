#!/bin/sh
set -eu

case $1 in
  /*) nbsp=$1 ;;
  *) nbsp=$(cd "$(dirname "$1")" && pwd)/$(basename "$1") ;;
esac
zsh_source=$2
zsh_autosuggest_source=$3
tmp=$(mktemp -d "${TMPDIR:-/tmp}/nbsp-cli.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

"$nbsp" --version | grep -q '^nbsp 0\.1\.0$'
"$nbsp" --help | grep -q 'nbsp init zsh'
"$nbsp" --help | grep -q 'nbsp init zsh \[--detached\] \[--autosuggest\]'
"$nbsp" --help | grep -q 'nbsp data'
"$nbsp" --help | grep -q 'nbsp refresh \[--cwd PATH\] \[--notify\] \[--force\]'
"$nbsp" --help | grep -q 'nbsp dirs \[--cwd PATH\] \[--format nul\]'
"$nbsp" init zsh > "$tmp/nbsp_zsh.zsh"
test "$(sed -n '1p' "$tmp/nbsp_zsh.zsh")" = 'typeset -g _NBSP_INIT_MODE=prompt'
sed '1d' "$tmp/nbsp_zsh.zsh" > "$tmp/nbsp_zsh_body.zsh"
cmp "$zsh_source" "$tmp/nbsp_zsh_body.zsh"
"$nbsp" init zsh --detached | grep -q '^typeset -g _NBSP_INIT_MODE=detached$'
"$nbsp" init zsh --autosuggest > "$tmp/nbsp_zsh_autosuggest.zsh"
grep -q '^    _nbsp_as_pre_redraw() {' "$tmp/nbsp_zsh_autosuggest.zsh"
zsh_init_bytes=$(wc -c < "$tmp/nbsp_zsh.zsh" | tr -d ' ')
tail -c "+$((zsh_init_bytes + 1))" "$tmp/nbsp_zsh_autosuggest.zsh" > "$tmp/nbsp_zsh_autosuggest_body.zsh"
cmp "$zsh_autosuggest_source" "$tmp/nbsp_zsh_autosuggest_body.zsh"
"$nbsp" init zsh --autosuggest --detached > "$tmp/nbsp_zsh_detached_autosuggest.zsh"
grep -q '^typeset -g _NBSP_INIT_MODE=detached$' "$tmp/nbsp_zsh_detached_autosuggest.zsh"
grep -q '^    _nbsp_as_pre_redraw() {' "$tmp/nbsp_zsh_detached_autosuggest.zsh"
"$nbsp" init zsh --detached --autosuggest >/dev/null
conflict_result=$(zsh -dfc '
  _zsh_autosuggest_start() { :; }
  eval "$("$1" init zsh --autosuggest 2>/dev/null)"
  if (( $+functions[_nbsp_as_pre_redraw] )); then
    print installed
  else
    print skipped
  fi
' _ "$nbsp")
test "$conflict_result" = skipped
if "$nbsp" init zsh --autosuggest --autosuggest >/dev/null 2>&1; then
  echo 'duplicate autosuggest flag unexpectedly succeeded' >&2
  exit 1
else
  test $? -eq 2
fi
if "$nbsp" prompt --status 999 >/dev/null 2>&1; then
  echo 'invalid status unexpectedly succeeded' >&2
  exit 1
else
  test $? -eq 2
fi
if "$nbsp" data --format json >/dev/null 2>&1; then
  echo 'invalid data format unexpectedly succeeded' >&2
  exit 1
else
  test $? -eq 2
fi
if "$nbsp" init zsh --unknown >/dev/null 2>&1; then
  echo 'invalid init mode unexpectedly succeeded' >&2
  exit 1
else
  test $? -eq 2
fi

dirs_root="$tmp/dirs"
mkdir -p "$dirs_root/alpha" "$dirs_root/space dir"
ln -s alpha "$dirs_root/linked"
printf 'not a directory\n' > "$dirs_root/regular"
dirs_check=$(zsh -dfc '
  typeset key value
  typeset -a dirs
  integer schema=0 complete=0
  while IFS= read -r -d "" key && IFS= read -r -d "" value; do
    case $key in
      schema_version) schema=$value ;;
      dir) dirs+=( "$value" ) ;;
      complete) complete=$value ;;
      *) exit 3 ;;
    esac
  done < <("$1" dirs --cwd "$2" --format nul)
  print -r -- "$schema $complete ${(j:,:)dirs}"
' _ "$nbsp" "$dirs_root")
test "$dirs_check" = '1 1 alpha,linked,space dir'
if "$nbsp" dirs --cwd "$dirs_root" --format json >/dev/null 2>&1; then
  echo 'invalid dirs format unexpectedly succeeded' >&2
  exit 1
else
  test $? -eq 2
fi

repo="$tmp/repo percent%"
cache="$tmp/cache"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" config user.name 'nbsp tests'
git -C "$repo" config user.email 'nbsp@example.invalid'
git -C "$repo" config commit.gpgsign false
printf 'one\n' > "$repo/a.txt"
printf 'two\n' > "$repo/b.txt"
git -C "$repo" add a.txt b.txt
git -C "$repo" commit -qm initial
branch=$(git -C "$repo" branch --show-current)

cold=$(cd "$repo" && NBSP_CACHE_DIR="$cache" "$nbsp" prompt)
printf '%s' "$cold" | grep -Fq "[$branch ...]"
printf '%s' "$cold" | grep -Fq "%F{default}[$branch ...]%f"

NBSP_CACHE_DIR="$cache" "$nbsp" refresh --cwd "$repo"
printf 'forced refresh\n' >> "$repo/a.txt"
NBSP_CACHE_DIR="$cache" "$nbsp" refresh --cwd "$repo"
debounced=$(cd "$repo" && NBSP_CACHE_DIR="$cache" "$nbsp" prompt)
printf '%s' "$debounced" | grep -Fq "[$branch]"
NBSP_CACHE_DIR="$cache" "$nbsp" refresh --cwd "$repo" --force
forced=$(cd "$repo" && NBSP_CACHE_DIR="$cache" "$nbsp" prompt)
printf '%s' "$forced" | grep -Fq "[$branch ~1]"

printf 'changed\n' >> "$repo/a.txt"
printf 'staged\n' >> "$repo/b.txt"
git -C "$repo" add b.txt
printf 'new\n' > "$repo/c.txt"
sleep 1
NBSP_CACHE_DIR="$cache" "$nbsp" refresh --cwd "$repo"

warm=$(cd "$repo" && NBSP_CACHE_DIR="$cache" "$nbsp" prompt)
printf '%s' "$warm" | grep -Fq "[$branch +1 ~1 ?1]"

data=$(cd "$repo" && NVM_BIN="$tmp/.nvm/versions/node/v22.14.0/bin" \
  NBSP_CACHE_DIR="$cache" "$nbsp" data --status 7 --duration-ms 2450 --jobs 2)
printf '%s\n' "$data" | grep -Fxq 'schema_version=1'
printf '%s\n' "$data" | grep -Fq 'cwd='
printf '%s\n' "$data" | grep -Fq '%20'
printf '%s\n' "$data" | grep -Fq '%25'
printf '%s\n' "$data" | grep -Fxq 'status=7'
printf '%s\n' "$data" | grep -Fxq 'duration_ms=2450'
printf '%s\n' "$data" | grep -Fxq 'jobs=2'
printf '%s\n' "$data" | grep -Fxq 'node_version=22.14.0'
printf '%s\n' "$data" | grep -Fxq 'git_present=1'
printf '%s\n' "$data" | grep -Fxq 'git_valid=1'
printf '%s\n' "$data" | grep -Fxq "git_branch=$branch"
printf '%s\n' "$data" | grep -Fxq 'git_staged=1'
printf '%s\n' "$data" | grep -Fxq 'git_modified=1'
printf '%s\n' "$data" | grep -Fxq 'git_untracked=1'
test "$(printf '%s\n' "$data" | wc -l | tr -d ' ')" = 18

nul_check=$(cd "$repo" && NVM_BIN="$tmp/.nvm/versions/node/v22.14.0/bin" \
  NBSP_CACHE_DIR="$cache" zsh -dfc '
    typeset -A values
    while IFS= read -r -d "" key && IFS= read -r -d "" value; do
      values[$key]=$value
    done < <("$1" data --status 7 --duration-ms 2450 --jobs 2 --format nul)
    print -r -- "${#values} ${values[schema_version]} ${values[git_branch]} ${values[status]}"
  ' _ "$nbsp")
test "$nul_check" = "18 1 $branch 7"

cache_file=$(find "$cache/git" -name '*.cache' -type f | head -n 1)
printf 'version=1\nrepo=corrupt\nupdated_ms=oops\n' > "$cache_file"
corrupt_prompt=$(cd "$repo" && NBSP_CACHE_DIR="$cache" "$nbsp" prompt)
printf '%s' "$corrupt_prompt" | grep -Fq "[$branch ...]"
NBSP_CACHE_DIR="$cache" "$nbsp" refresh --cwd "$repo"

race_cache="$tmp/race-cache"
i=0
while test "$i" -lt 16; do
  NBSP_CACHE_DIR="$race_cache" "$nbsp" refresh --cwd "$repo" &
  i=$((i + 1))
done
wait
race_prompt=$(cd "$repo" && NBSP_CACHE_DIR="$race_cache" "$nbsp" prompt)
printf '%s' "$race_prompt" | grep -Fq "[$branch +1 ~1 ?1]"

worktree="$tmp/worktree"
git -C "$repo" worktree add -qb worktree-check "$worktree"
worktree_cold=$(cd "$worktree" && NBSP_CACHE_DIR="$cache" "$nbsp" prompt)
printf '%s' "$worktree_cold" | grep -Fq '[worktree-check ...]'
NBSP_CACHE_DIR="$cache" "$nbsp" refresh --cwd "$worktree"
worktree_warm=$(cd "$worktree" && NBSP_CACHE_DIR="$cache" "$nbsp" prompt)
printf '%s' "$worktree_warm" | grep -Fq '[worktree-check]'

git -C "$worktree" switch -qc 'feature/100%'
percent_prompt=$(cd "$worktree" && NBSP_CACHE_DIR="$cache" "$nbsp" prompt)
printf '%s' "$percent_prompt" | grep -Fq '[feature/100%%]'

git -C "$worktree" checkout --detach -q
detached=$(git -C "$worktree" rev-parse --short=8 HEAD)
detached_prompt=$(cd "$worktree" && NBSP_CACHE_DIR="$cache" "$nbsp" prompt)
printf '%s' "$detached_prompt" | grep -Fq "[$detached]"

fakebin="$tmp/fakebin"
mkdir -p "$fakebin"
marker="$tmp/git-was-run"

printf '#!/bin/sh\n/bin/sleep 2\n' > "$fakebin/git"
chmod +x "$fakebin/git"
sleep 1
if (cd "$repo" && PATH="$fakebin:$PATH" NBSP_CACHE_DIR="$cache" \
  NBSP_GIT_TIMEOUT_MS=50 "$nbsp" refresh --cwd "$repo"); then
  echo 'timed-out Git refresh unexpectedly succeeded' >&2
  exit 1
else
  test $? -eq 124
fi
preserved=$(cd "$repo" && NBSP_CACHE_DIR="$cache" "$nbsp" prompt)
printf '%s' "$preserved" | grep -Fq "[$branch +1 ~1 ?1]"

printf '#!/bin/sh\n: > "$NBSP_GIT_MARKER"\nexit 99\n' > "$fakebin/git"
chmod +x "$fakebin/git"
(cd "$repo" && NBSP_GIT_MARKER="$marker" PATH="$fakebin:$PATH" \
  NBSP_CACHE_DIR="$cache" "$nbsp" prompt >/dev/null)
test ! -e "$marker"
(cd "$repo" && NBSP_GIT_MARKER="$marker" PATH="$fakebin:$PATH" \
  NBSP_CACHE_DIR="$cache" "$nbsp" data >/dev/null)
test ! -e "$marker"

nvm=$(cd "$repo" && NVM_BIN="$tmp/.nvm/versions/node/v22.14.0/bin" \
  "$nbsp" prompt --status 1 --duration-ms 2500 --jobs 2)
printf '%s' "$nvm" | grep -Fq '[node:22.14.0]'
printf '%s' "$nvm" | grep -Fq '%F{green}[node:22.14.0]%f'
printf '%s' "$nvm" | grep -Fq '[2.5s]'
printf '%s' "$nvm" | grep -Fq '[jobs:2]'
printf '%s' "$nvm" | grep -Fq '%F{red}e1%#%f'

not_found=$(cd "$repo" && NVM_BIN= "$nbsp" prompt --status 127)
printf '%s' "$not_found" | grep -Fq '%F{red}e127%#%f'

success=$(cd "$repo" && NVM_BIN= "$nbsp" prompt --status 0)
printf '%s' "$success" | grep -Fq ' %# '
if printf '%s' "$success" | grep -Fq 'e0%#'; then
  echo 'successful prompt unexpectedly emitted an exit status' >&2
  exit 1
fi
if printf '%s' "$success" | grep -Fq '%F{green}'; then
  echo 'successful prompt unexpectedly emitted green' >&2
  exit 1
fi

opinionated=$(cd "$tmp" && NVM_BIN="$tmp/.nvm/versions/node/v22.14.0/bin" \
  "$nbsp" prompt --status 1 --duration-ms 2450 --jobs 2)
overridden=$(cd "$tmp" && NVM_BIN="$tmp/.nvm/versions/node/v22.14.0/bin" \
  NBSP_COLOR_PATH=cyan NBSP_COLOR_NODE=red NBSP_PROMPT_CHAR='$' \
  NBSP_DURATION_THRESHOLD_MS=999999 NBSP_SHOW_NVM=0 NBSP_SHOW_JOBS=0 \
  "$nbsp" prompt --status 1 --duration-ms 2450 --jobs 2)
test "$opinionated" = "$overridden"

init_check=$(PATH="$(dirname "$nbsp"):$PATH" zsh -dfc '
  eval "$(nbsp init zsh)"
  eval "$(nbsp init zsh)"
  print -r -- $functions[_nbsp_precmd]
  print -r -- ${#precmd_functions[(I)_nbsp_precmd]}
')
printf '%s' "$init_check" | grep -q '_nbsp_last_status'
test "$(printf '%s\n' "$init_check" | tail -n 1)" = 1

mode_check=$(PATH="$(dirname "$nbsp"):$PATH" zsh -dfc '
  eval "$(nbsp init zsh --detached)"
  eval "$(nbsp init zsh)"
  print -r -- "$_nbsp_mode ${+NBSP_DATA}"
')
test "$mode_check" = 'detached 1'

NBSP_CACHE_DIR="$cache" "$nbsp" cache clear
test -z "$(find "$cache/git" -type f 2>/dev/null || true)"
