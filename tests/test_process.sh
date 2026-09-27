#!/bin/sh
set -eu
nbsp=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
tmp=$(mktemp -d "${TMPDIR:-/tmp}/nbsp-process.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir -m 700 "$tmp/cache"
mkdir "$tmp/repo" "$tmp/bin"
git -C "$tmp/repo" init -qb main
export NBSP_CACHE_DIR="$tmp/cache" NBSP_GIT_TIMEOUT_MS=50
export PATH="$tmp/bin:$PATH"
cat > "$tmp/bin/git" <<'GIT'
#!/bin/sh
# Descendant retains stdout after its parent exits.
/bin/sleep 2 &
exit 0
GIT
chmod +x "$tmp/bin/git"
set +e
"$nbsp" refresh --cwd "$tmp/repo" --force --notify > "$tmp/notify"
result=$?
set -e
test "$result" -eq 124
printf '\n' > "$tmp/newline"
cmp "$tmp/notify" "$tmp/newline"
cat > "$tmp/bin/git" <<'GIT'
#!/bin/sh
printf '# branch.oid (initial)\n# branch.head main\n'
GIT
# Pipe descriptors must be moved away from closed standard descriptors.
export NBSP_GIT_TIMEOUT_MS=1500
("$nbsp" refresh --cwd "$tmp/repo" --force 0<&- 1>&- 2>&-)
(cd "$tmp/repo" && "$nbsp" data) | grep -qx 'git_valid=1'
cat > "$tmp/bin/git" <<'GIT'
#!/bin/sh
printf '# branch.oid (initial)\n# branch.head main\n'
/usr/bin/yes '? file' | /usr/bin/head -n 1300000
GIT
export NBSP_GIT_TIMEOUT_MS=1500
set +e
"$nbsp" refresh --cwd "$tmp/repo" --force --notify > "$tmp/notify"
result=$?
set -e
test "$result" -eq 1
cmp "$tmp/notify" "$tmp/newline"
# Failed refresh must retain the previously published complete snapshot.
(cd "$tmp/repo" && "$nbsp" data) | grep -qx 'git_valid=1'
cat > "$tmp/bin/git" <<'GIT'
#!/bin/sh
: > "$NBSP_TEST_MARKER"
/bin/sleep .1
printf '# branch.oid (initial)\n# branch.head main\n'
GIT
export NBSP_TEST_MARKER="$tmp/started"
"$nbsp" refresh --cwd "$tmp/repo" --force &
worker=$!
while test ! -f "$tmp/started"; do /bin/sleep .01; done
# Clear scans and deletes snapshots while the refresh lock inode survives.
"$nbsp" cache clear
test -n "$(find "$tmp/cache/git" -name '*.lock' -type f)"
wait "$worker"
(cd "$tmp/repo" && "$nbsp" data) | grep -qx 'git_valid=1'
printf '%s\n' PROCESS-REGRESSIONS-PASS
