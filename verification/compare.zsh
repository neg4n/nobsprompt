#!/usr/bin/env zsh
emulate -LR zsh
setopt ERR_EXIT NO_UNSET PIPE_FAIL
if (( $# < 3 || $# > 4 )); then
  print -ru2 -- "usage: $0 C-binary Zig-binary output-directory [iterations]"
  exit 2
fi
typeset reference=${1:A} rewrite=${2:A} output=${3:A}
typeset root=${0:A:h:h} iterations=${4:-1000}
typeset zig_arch=$(uname -m) c_cpu_flags='-march=x86-64 -mtune=generic'
typeset c_compiler=$(clang --version | head -n 1)
typeset c_linker=$(ld -v 2>&1 | head -n 1)
typeset source_dirty=0
[[ -n $(git -C "$root" status --porcelain --untracked-files=no) ]] && source_dirty=1
if [[ $zig_arch == arm64 ]]; then zig_arch=aarch64; c_cpu_flags=-mcpu=generic; fi
typeset tmp=$(mktemp -d /private/tmp/nbsp-matched.XXXXXX)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir -p "$output" "$tmp/plain" "$tmp/repo" "$tmp/dirs" "$tmp/detached"
mkdir -m 700 "$tmp/cache" "$tmp/missing" "$tmp/invalid"
export NBSP_CACHE_DIR="$tmp/cache" NVM_BIN=/nvm/v22.22.0/bin
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
/usr/bin/git -C "$tmp/repo" init -qb main
print -r -- content > "$tmp/repo/tracked"
/usr/bin/git -C "$tmp/repo" add tracked
/usr/bin/git -C "$tmp/repo" -c commit.gpgsign=false -c user.name=Test -c user.email=test@example.invalid commit -qm initial
mkdir -p "$tmp/repo/sub/deep"
print -r -- changed >> "$tmp/repo/tracked"
"$reference" refresh --cwd "$tmp/repo" --force
# Same branch and timestamp in valid and invalid cache workloads.
cp -R "$tmp/cache/git" "$tmp/invalid/git"
for file in "$tmp/invalid/git/"*.cache; do print -r -- malformed > "$file"; done
/usr/bin/git -C "$tmp/repo" worktree add -q --detach "$tmp/worktree"
/usr/bin/git clone -q --no-local "$tmp/repo" "$tmp/detached"
/usr/bin/git -C "$tmp/detached" checkout -q --detach
"$reference" refresh --cwd "$tmp/worktree" --force
"$reference" refresh --cwd "$tmp/detached" --force
for (( i=0; i<128; ++i )); do mkdir "$tmp/dirs/directory-$i"; done
ln -s directory-1 "$tmp/dirs/link"
for name in plain nested valid missing invalid detached worktree dirs; do
  typeset cwd= mode=data cache_root="$tmp/cache"
  case $name in
    plain) cwd="$tmp/plain" ;;
    nested) cwd="$tmp/repo/sub/deep" ;;
    valid) cwd="$tmp/repo" ;;
    missing) cwd="$tmp/repo"; cache_root="$tmp/missing" ;;
    invalid) cwd="$tmp/repo"; cache_root="$tmp/invalid" ;;
    detached) cwd="$tmp/detached" ;;
    worktree) cwd="$tmp/worktree" ;;
    dirs) cwd="$tmp/dirs"; mode=dirs ;;
  esac
  export NBSP_CACHE_DIR=$cache_root
  for implementation in c zig; do
    typeset binary=$rewrite
    [[ $implementation == c ]] && binary=$reference
    for memory_run in 1 2 3 4 5; do
      (cd "$cwd"; /usr/bin/time -l "$binary" "$mode" > /dev/null) 2> "$output/$name-$memory_run-$implementation.memory"
    done
  done
  if [[ -x "$root/zig-out/bin/measure-allocations" ]]; then
    (cd "$cwd"; "$root/zig-out/bin/measure-allocations" "$mode") > "$output/$name.allocations"
  fi
  for repeat in 1 2 3; do
    typeset -a order=(c zig)
    (( repeat % 2 == 0 )) && order=(zig c)
    for implementation in $order; do
      typeset binary=$rewrite
      if [[ $implementation == c ]]; then
        binary=$reference
        export NBSP_BENCH_SOURCE_REVISION=56db8ce9cce0ea50345d66288c76dfca30f67f47 NBSP_BENCH_SOURCE_DIRTY=0
        export NBSP_BENCH_COMPILER=$c_compiler NBSP_BENCH_BUILD_TYPE=release NBSP_BENCH_CFLAGS="-O3 -flto -mmacosx-version-min=13.0 $c_cpu_flags" NBSP_BENCH_LDFLAGS="$c_linker, -flto -dead_strip -mmacosx-version-min=13.0"
      else
        export NBSP_BENCH_SOURCE_REVISION=$(/usr/bin/git -C "$root" rev-parse HEAD) NBSP_BENCH_SOURCE_DIRTY=$source_dirty
        export NBSP_BENCH_COMPILER='Zig 0.16.0' NBSP_BENCH_BUILD_TYPE=ReleaseSafe NBSP_BENCH_CFLAGS="-OReleaseSafe -target $zig_arch-macos.13.0 -mcpu=baseline -fsingle-threaded" NBSP_BENCH_LDFLAGS='LLVM codegen, Zig Mach-O linker, macOS system libc'
      fi
      zsh "$root/bench/benchmark.zsh" --iterations "$iterations" --warmup 100 --cwd "$cwd" --output "$output/$name-$repeat-$implementation.report" -- "$binary" "$mode"
    done
  done
 done
