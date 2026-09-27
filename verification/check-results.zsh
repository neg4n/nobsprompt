#!/usr/bin/env zsh
emulate -LR zsh
setopt ERR_EXIT NO_UNSET PIPE_FAIL
(( $# == 1 )) || { print -ru2 'usage: check-results.zsh report-directory'; exit 2; }
typeset output=${1:A}
integer failed=0
for workload in plain nested valid missing invalid detached worktree dirs; do
  awk -F= -v workload="$workload" '
    FILENAME ~ /-c\.(report|memory)$/ { impl="c" }
    FILENAME ~ /-zig\.(report|memory)$/ { impl="zig" }
    $1 == "mean_ms" || $1 == "p50_ms" || $1 == "p95_ms" {
      total[impl,$1]+=$2; count[impl,$1]++
    }
    /maximum resident set size/ || /peak memory footprint/ {
      split($0, words, /[[:space:]]+/)
      value=$0+0
      metric=($0 ~ /maximum resident/ ? "rss" : "footprint")
      total[impl,metric]+=value; count[impl,metric]++
    }
    END {
      n=split("mean_ms p50_ms p95_ms rss footprint", metrics, " ")
      for (i=1;i<=n;i++) {
        m=metrics[i]; expected=(i<=3 ? 3 : 5); limit=(i<=3 ? 5 : 10)
        if (count["c",m]!=expected || count["zig",m]!=expected || total["c",m]<=0) {
          printf "%s %s: incomplete measurements\n", workload,m; failed=1; continue
        }
        growth=(total["zig",m]/total["c",m]-1)*100
        printf "%s %s: %+.2f%% %s\n", workload,m,growth,(growth<=limit ? "PASS" : "FAIL")
        if (growth>limit) failed=1
      }
      exit failed
    }
  ' "$output/$workload-"*.report "$output/$workload-"*.memory || failed=1
done
exit $failed
