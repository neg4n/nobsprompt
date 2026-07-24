#!/bin/sh
set -eu

case $1 in
  /*) nbsp=$1 ;;
  *) nbsp=$(cd "$(dirname "$1")" && pwd)/$(basename "$1") ;;
esac
tmp=$(mktemp -d "${TMPDIR:-/tmp}/nbsp-cli.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

"$nbsp" --version | grep -q '^nbsp 0\.1\.0$'
"$nbsp" --help | grep -q 'nbsp init zsh'
if "$nbsp" prompt --status 999 >/dev/null 2>&1; then
  echo 'invalid status unexpectedly succeeded' >&2
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
printf 'changed\n' >> "$repo/a.txt"
printf 'staged\n' >> "$repo/b.txt"
git -C "$repo" add b.txt
printf 'new\n' > "$repo/c.txt"
sleep 1
NBSP_CACHE_DIR="$cache" "$nbsp" refresh --cwd "$repo"

warm=$(cd "$repo" && NBSP_CACHE_DIR="$cache" "$nbsp" prompt)
printf '%s' "$warm" | grep -Fq "[$branch +1 ~1 ?1]"

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

nvm=$(cd "$repo" && NVM_BIN="$tmp/.nvm/versions/node/v22.14.0/bin" \
  NBSP_SHOW_GIT=0 "$nbsp" prompt --status 1 --duration-ms 2500 --jobs 2)
printf '%s' "$nvm" | grep -Fq '[node:22.14.0]'
printf '%s' "$nvm" | grep -Fq '%F{green}[node:22.14.0]%f'
printf '%s' "$nvm" | grep -Fq '[2.5s]'
printf '%s' "$nvm" | grep -Fq '[jobs:2]'
printf '%s' "$nvm" | grep -Fq '%F{red}e1%#%f'

not_found=$(cd "$repo" && NBSP_SHOW_GIT=0 NBSP_SHOW_NVM=0 \
  "$nbsp" prompt --status 127)
printf '%s' "$not_found" | grep -Fq '%F{red}e127%#%f'

success=$(cd "$repo" && NBSP_SHOW_GIT=0 NBSP_SHOW_NVM=0 "$nbsp" prompt --status 0)
printf '%s' "$success" | grep -Fq ' %# '
if printf '%s' "$success" | grep -Fq 'e0%#'; then
  echo 'successful prompt unexpectedly emitted an exit status' >&2
  exit 1
fi
if printf '%s' "$success" | grep -Fq '%F{green}'; then
  echo 'successful prompt unexpectedly emitted green' >&2
  exit 1
fi

init_check=$(PATH="$(dirname "$nbsp"):$PATH" NBSP_SHOW_GIT=0 zsh -dfc '
  eval "$(nbsp init zsh)"
  eval "$(nbsp init zsh)"
  print -r -- $functions[_nbsp_precmd]
  print -r -- ${#precmd_functions[(I)_nbsp_precmd]}
')
printf '%s' "$init_check" | grep -q '_nbsp_last_status'
test "$(printf '%s\n' "$init_check" | tail -n 1)" = 1

NBSP_CACHE_DIR="$cache" "$nbsp" cache clear
test -z "$(find "$cache/git" -type f 2>/dev/null || true)"
