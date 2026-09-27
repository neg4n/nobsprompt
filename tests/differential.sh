#!/bin/sh
set -eu
reference=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
rewrite=$(cd "$(dirname "$2")" && pwd)/$(basename "$2")
tmp=$(mktemp -d "${TMPDIR:-/tmp}/nbsp-differential.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
export NBSP_CACHE_DIR="$tmp/cache"
mkdir -m 700 "$NBSP_CACHE_DIR"
mkdir "$tmp/plain" "$tmp/repo" "$tmp/dirs"
git -C "$tmp/repo" init -q
for directory in alpha zeta '.hidden' 'space name'; do mkdir "$tmp/dirs/$directory"; done
ln -s alpha "$tmp/dirs/link"
compare() {
  set +e
  "$reference" "$@" > "$tmp/c.out" 2> "$tmp/c.err"; c_status=$?
  "$rewrite" "$@" > "$tmp/zig.out" 2> "$tmp/zig.err"; zig_status=$?
  set -e
  test "$c_status" = "$zig_status" || { echo "exit mismatch: $* ($c_status/$zig_status)" >&2; exit 1; }
  cmp "$tmp/c.out" "$tmp/zig.out"
}
cd "$tmp/plain"
compare data
compare data --format nul --status 255 --duration-ms 9223372036854775807 --jobs 2147483647
compare --help
compare --version
for args in '--status -1' '--status 256' '--status invalid' '--duration-ms 9223372036854775808' '--jobs 2147483648' '--format bad'; do
  # These are fixed test vectors, with deliberate word splitting.
  compare data $args
done
compare dirs --cwd "$tmp/dirs" --format nul
cd "$tmp/repo"
compare data
"$reference" refresh --force
compare data
compare data --format nul
"$rewrite" refresh --force
compare data
compare data --format nul
# Each producer reads snapshots written by the other; no timestamp normalization.
printf content > tracked
git add tracked
"$reference" refresh --force
compare data
"$rewrite" refresh --force
compare data
"$reference" cache clear
compare data
"$rewrite" refresh --force
"$rewrite" cache clear
compare data
# A real detached HEAD and gitfile/worktree.
git -c commit.gpgsign=false -c user.name=Test -c user.email=test@example.invalid commit -qm initial
git checkout -q --detach
"$reference" refresh --force
compare data
"$rewrite" refresh --force
compare data
git worktree add -q --detach "$tmp/worktree"
cd "$tmp/worktree"
"$reference" refresh --force
compare data
"$rewrite" refresh --force
compare data
# Explicit invalid override never falls back to HOME/XDG.
NBSP_CACHE_DIR=relative compare data
printf '%s\n' DIFFERENTIAL-PASS
