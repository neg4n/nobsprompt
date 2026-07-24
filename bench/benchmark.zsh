#!/usr/bin/env zsh
set -eu
zmodload zsh/datetime

binary=${1:-./build/nbsp}
command=${2:-prompt}
iterations=${NBSP_BENCH_ITERATIONS:-1000}
tmp=$(mktemp "${TMPDIR:-/tmp}/nbsp-bench.XXXXXX")
trap 'rm -f "$tmp"' EXIT HUP INT TERM

if [[ $command != prompt && $command != data ]]; then
  print -ru2 -- "usage: $0 [nbsp-binary] [prompt|data]"
  exit 2
fi

for (( i = 1; i <= iterations; ++i )); do
  start=$EPOCHREALTIME
  "$binary" "$command" >/dev/null
  elapsed=$(( (EPOCHREALTIME - start) * 1000.0 ))
  printf '%.3f\n' $elapsed >> "$tmp"
done

values=( ${(f)"$(sort -n "$tmp")"} )
index=$(( (iterations * 95 + 99) / 100 ))
total=0.0
for value in $values; do
  total=$(( total + value ))
done

printf 'iterations: %d\n' $iterations
printf 'command:    %s\n' $command
printf 'mean:       %.3f ms\n' $(( total / iterations ))
printf 'p95:        %.3f ms\n' ${values[$index]}
printf 'min/max:    %.3f / %.3f ms\n' ${values[1]} ${values[-1]}
