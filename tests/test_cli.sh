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

"$nbsp" --version | grep -q '^nbsp 0\.2\.0$'
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
conflict_message=$(zsh -dfc '
  _zsh_autosuggest_start() { :; }
  eval "$("$1" init zsh --autosuggest)"
' _ "$nbsp" 2>&1 >/dev/null)
test "$conflict_message" = 'nbsp: --autosuggest disabled because another autosuggestion plugin is active; use only one engine or remove --autosuggest'
mkdir -p "$tmp/home/Desktop/programming" "$tmp/path parser/space dir"
zsh -dfc '
  autoload -Uz add-zsh-hook
  cd "$2" || exit 10
  eval "$("$1" init zsh --autosuggest)"
  HOME=$3
  cdpath=()
  check_path() {
    local line=$1 expected_root=$2 expected_leaf=$3
    local -a reply
    _nbsp_as_parse_cd "$line" || exit 11
    [[ ${reply[1]-} == $expected_root && ${reply[2]-} == $expected_leaf ]] || exit 12
  }
  check_rejected() {
    local -a reply
    _nbsp_as_parse_cd "$1" && exit 13
    return 0
  }
  check_path "cd relative" "$PWD" relative
  check_path "cd ./alpha/be" "$PWD/./alpha" be
  check_path "cd ../pa" "$PWD/.." pa
  check_path "cd /tmp/ab" /tmp ab
  check_path "cd ~/Desktop/programming/w" "$3/Desktop/programming" w
  check_path "cd \"space dir\"/n" "$PWD/space dir" n
  check_path "cd space\\ dir/n" "$PWD/space dir" n
  check_path "cd -- -dash" "$PWD" -dash
  check_rejected "cd \$HOME/w"
  check_rejected "cd \$(pwd)/w"
  check_rejected "cd foo*"
  check_rejected "cd ~someone/w"
  check_rejected "cd \"unterminated"
  check_rejected "cd one two"
  cdpath=( "$3/Desktop/programming" )
  check_path "cd relative" "$PWD" relative
  check_path "cd ./relative" "$PWD/." relative
  check_path "cd ../relative" "$PWD/.." relative
  setopt posixcd
  check_rejected "cd relative"
  check_path "cd ./relative" "$PWD/." relative
  check_path "cd ../relative" "$PWD/.." relative
' _ "$nbsp" "$tmp/path parser" "$tmp/home"
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
for invalid_prompt_options in '' percent,percent none,percent percent,unknown percent,; do
  if "$nbsp" prompt --prompt-options "$invalid_prompt_options" >/dev/null 2>&1; then
    echo "invalid prompt options unexpectedly succeeded: $invalid_prompt_options" >&2
    exit 1
  else
    test $? -eq 2
  fi
done
plain_prompt=$(cd "$tmp" && "$nbsp" prompt --status 1 --prompt-options none)
printf '%s' "$plain_prompt" | grep -Fq 'e1'
if printf '%s' "$plain_prompt" | grep -Eq '%F\{|%#|%f'; then
  echo 'plain prompt unexpectedly emitted percent escapes' >&2
  exit 1
fi
if "$nbsp" data --format json >/dev/null 2>&1; then
  echo 'invalid data format unexpectedly succeeded' >&2
  exit 1
else
  test $? -eq 2
fi
for deleted_cwd_command in prompt data; do
  deleted_cwd="$tmp/deleted-cwd-$deleted_cwd_command"
  deleted_cwd_output="$tmp/deleted-cwd-$deleted_cwd_command.out"
  mkdir "$deleted_cwd"
  if (
    cd "$deleted_cwd"
    rmdir "$deleted_cwd" || exit 10
    "$nbsp" "$deleted_cwd_command" > "$deleted_cwd_output"
  ); then
    echo "$deleted_cwd_command from a deleted working directory unexpectedly succeeded" >&2
    exit 1
  else
    test $? -eq 1
  fi
  test ! -s "$deleted_cwd_output"
done
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

insecure_cache="$tmp/insecure-cache"
mkdir -m 0755 "$insecure_cache"
if NBSP_CACHE_DIR="$insecure_cache" "$nbsp" refresh --cwd "$repo" --force; then
  echo 'refresh unexpectedly accepted an insecure cache root' >&2
  exit 1
else
  test $? -eq 1
fi

printf 'changed\n' >> "$repo/a.txt"
printf 'staged\n' >> "$repo/b.txt"
git -C "$repo" add b.txt
printf 'new\n' > "$repo/c.txt"
sleep 1
NBSP_CACHE_DIR="$cache" "$nbsp" refresh --cwd "$repo"

warm=$(cd "$repo" && NBSP_CACHE_DIR="$cache" "$nbsp" prompt)
printf '%s' "$warm" | grep -Fq "[$branch +1 ~1 ?1]"

selector_repo="$tmp/selector-repo"
mkdir -p "$selector_repo"
git -C "$selector_repo" init -q
git -C "$selector_repo" config user.name 'nbsp tests'
git -C "$selector_repo" config user.email 'nbsp@example.invalid'
git -C "$selector_repo" config commit.gpgsign false
printf 'foreign\n' > "$selector_repo/foreign.txt"
git -C "$selector_repo" add foreign.txt
git -C "$selector_repo" commit -qm initial
printf 'foreign staged\n' >> "$selector_repo/foreign.txt"
git -C "$selector_repo" add foreign.txt
selector_excludes="$tmp/selector-excludes"
printf '*\n' > "$selector_excludes"
selector_global_config="$tmp/selector-global-config"
git config -f "$selector_global_config" core.excludesFile "$selector_excludes"
selector_real_git=$(command -v git)
selector_bin="$tmp/selector-bin"
mkdir "$selector_bin"
cat > "$selector_bin/git" <<'EOF'
#!/bin/sh
if test "${GIT_CONFIG_GLOBAL+x}" = x || \
    test "${GIT_CONFIG_SYSTEM+x}" = x || \
    test "${GIT_CONFIG_NOSYSTEM+x}" = x; then
  exit 97
fi
exec "$NBSP_TEST_REAL_GIT" "$@"
EOF
chmod 0755 "$selector_bin/git"
GIT_DIR="$selector_repo/.git" GIT_WORK_TREE="$selector_repo" \
  GIT_INDEX_FILE="$selector_repo/.git/index" GIT_CONFIG_COUNT=1 \
  GIT_CONFIG_KEY_0=core.worktree GIT_CONFIG_VALUE_0="$selector_repo" \
  GIT_CONFIG_GLOBAL="$selector_global_config" \
  GIT_CONFIG_SYSTEM="$selector_global_config" GIT_CONFIG_NOSYSTEM=1 \
  NBSP_TEST_REAL_GIT="$selector_real_git" PATH="$selector_bin:$PATH" \
  NBSP_CACHE_DIR="$cache" \
  "$nbsp" refresh --cwd "$repo" --force
selector_isolated=$(cd "$repo" && NBSP_CACHE_DIR="$cache" "$nbsp" prompt)
printf '%s' "$selector_isolated" | grep -Fq "[$branch +1 ~1 ?1]"

data=$(cd "$repo" && NVM_BIN="$tmp/.nvm/versions/node/v22.14.0/bin" \
  NBSP_CACHE_DIR="$cache" "$nbsp" data --status 7 --duration-ms 2450 --jobs 2)
printf '%s\n' "$data" | grep -Fxq 'schema_version=2'
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
test "$nul_check" = "18 2 $branch 7"

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

mkdir -p "$repo/nested"
logical_path="$tmp/logical-nested"
logical_cache="$tmp/logical-cache"
ln -s "$repo/nested" "$logical_path"
NBSP_CACHE_DIR="$logical_cache" "$nbsp" refresh --cwd "$logical_path" --force
logical_prompt=$(cd "$repo/nested" && NBSP_CACHE_DIR="$logical_cache" "$nbsp" prompt)
printf '%s' "$logical_prompt" | grep -Fq "[$branch +1 ~1 ?1]"

worktree="$tmp/worktree"
git -C "$repo" worktree add -qb worktree-check "$worktree"
worktree_cold=$(cd "$worktree" && NBSP_CACHE_DIR="$cache" "$nbsp" prompt)
printf '%s' "$worktree_cold" | grep -Fq '[worktree-check ...]'
NBSP_CACHE_DIR="$cache" "$nbsp" refresh --cwd "$worktree"
worktree_warm=$(cd "$worktree" && NBSP_CACHE_DIR="$cache" "$nbsp" prompt)
printf '%s' "$worktree_warm" | grep -Fq '[worktree-check]'

git -C "$worktree" switch -qc 'feature/100%'
percent_prompt=$(cd "$worktree" && NBSP_CACHE_DIR="$cache" "$nbsp" prompt)
printf '%s' "$percent_prompt" | grep -Fq '[feature/100%% ...]'

danger_branch='feature/$(touch${IFS}$NBSP_PROMPT_MARKER)-`touch${IFS}$NBSP_PROMPT_MARKER`-!-%'
git -C "$worktree" switch -qc "$danger_branch"
danger_prompt=$(cd "$worktree" && NBSP_CACHE_DIR="$cache" \
  "$nbsp" prompt --prompt-options percent,subst,bang)
printf '%s' "$danger_prompt" | grep -Fq '${(g::):-'
if printf '%s' "$danger_prompt" | grep -Fq '$(touch'; then
  echo 'PROMPT_SUBST-safe renderer leaked raw command substitution syntax' >&2
  exit 1
fi
prompt_marker="$tmp/prompt-subst-ran"
NBSP_PROMPT_MARKER="$prompt_marker" NBSP_RENDERED_PROMPT="$danger_prompt" \
  zsh -dfc 'setopt promptpercent promptsubst promptbang; PROMPT=$NBSP_RENDERED_PROMPT; print -Pr -- "$PROMPT" >/dev/null'
test ! -e "$prompt_marker"

git -C "$worktree" checkout --detach -q
detached=$(git -C "$worktree" rev-parse --short=8 HEAD)
detached_prompt=$(cd "$worktree" && NBSP_CACHE_DIR="$cache" "$nbsp" prompt)
printf '%s' "$detached_prompt" | grep -Fq "[$detached ...]"

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

printf '#!/bin/sh\nexec 1>&-\n/bin/sleep 2\n' > "$fakebin/git"
chmod +x "$fakebin/git"
if (cd "$repo" && PATH="$fakebin:$PATH" NBSP_CACHE_DIR="$cache" \
  NBSP_GIT_TIMEOUT_MS=50 "$nbsp" refresh --cwd "$repo" --force); then
  echo 'Git process that closed stdout escaped its timeout' >&2
  exit 1
else
  test $? -eq 124
fi

printf '#!/bin/sh\nexit 99\n' > "$fakebin/git"
chmod +x "$fakebin/git"
if (cd "$repo" && PATH="$fakebin:$PATH" NBSP_CACHE_DIR="$cache" \
  "$nbsp" refresh --cwd "$repo" --force); then
  echo 'failed Git refresh unexpectedly succeeded' >&2
  exit 1
else
  test $? -eq 1
fi

printf '#!/bin/sh\nexit 0\n' > "$fakebin/git"
chmod +x "$fakebin/git"
if (cd "$repo" && PATH="$fakebin:$PATH" NBSP_CACHE_DIR="$cache" \
  "$nbsp" refresh --cwd "$repo" --force); then
  echo 'empty Git status unexpectedly succeeded' >&2
  exit 1
else
  test $? -eq 1
fi

printf '#!/bin/sh\nprintf "# branch.oid 1234567890abcdef1234567890abcdef12345678\\n# branch.head main\\nbogus\\n"\n' > "$fakebin/git"
chmod +x "$fakebin/git"
if (cd "$repo" && PATH="$fakebin:$PATH" NBSP_CACHE_DIR="$cache" \
  "$nbsp" refresh --cwd "$repo" --force); then
  echo 'malformed Git status unexpectedly succeeded' >&2
  exit 1
else
  test $? -eq 1
fi

printf '#!/bin/sh\nprintf "ref: refs/heads/mismatch\\n" > "$NBSP_GIT_REPO/.git/HEAD"\nprintf "# branch.oid 1234567890abcdef1234567890abcdef12345678\\n# branch.head %%s\\n" "$NBSP_GIT_OLD_BRANCH"\n' > "$fakebin/git"
chmod +x "$fakebin/git"
if (cd "$repo" && NBSP_GIT_REPO="$repo" NBSP_GIT_OLD_BRANCH="$branch" \
  PATH="$fakebin:$PATH" NBSP_CACHE_DIR="$cache" \
  "$nbsp" refresh --cwd "$repo" --force); then
  echo 'branch-changing Git refresh unexpectedly succeeded' >&2
  exit 1
else
  test $? -eq 1
fi
mismatch_data=$(cd "$repo" && NBSP_CACHE_DIR="$cache" "$nbsp" data)
printf '%s\n' "$mismatch_data" | grep -Fxq 'git_branch=mismatch'
printf '%s\n' "$mismatch_data" | grep -Fxq 'git_valid=0'
git -C "$repo" symbolic-ref HEAD "refs/heads/$branch"
NBSP_CACHE_DIR="$cache" "$nbsp" refresh --cwd "$repo" --force

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
test -z "$(find "$cache/git" -type f ! -name '*.lock' 2>/dev/null || true)"
test -n "$(find "$cache/git" -type f -name '*.lock' 2>/dev/null | head -n 1)"
