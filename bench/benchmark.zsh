#!/usr/bin/env zsh

emulate -LR zsh
setopt ERR_EXIT NO_UNSET PIPE_FAIL
export LC_ALL=C
zmodload zsh/datetime

integer -r max_iterations=100000
integer -r max_warmup=100000
typeset -ra clean_git_command=(
  /usr/bin/env
  -u GIT_DIR
  -u GIT_COMMON_DIR
  -u GIT_WORK_TREE
  -u GIT_IMPLICIT_WORK_TREE
  -u GIT_INDEX_FILE
  -u GIT_OBJECT_DIRECTORY
  -u GIT_ALTERNATE_OBJECT_DIRECTORIES
  -u GIT_CONFIG
  -u GIT_CONFIG_GLOBAL
  -u GIT_CONFIG_SYSTEM
  -u GIT_CONFIG_NOSYSTEM
  -u GIT_CONFIG_PARAMETERS
  -u GIT_CONFIG_COUNT
  -u GIT_CEILING_DIRECTORIES
  -u GIT_DISCOVERY_ACROSS_FILESYSTEM
  -u GIT_NAMESPACE
  -u GIT_SHALLOW_FILE
  -u GIT_GRAFT_FILE
  -u GIT_NO_REPLACE_OBJECTS
  -u GIT_REPLACE_REF_BASE
  -u GIT_REFERENCE_BACKEND
  -u GIT_QUARANTINE_PATH
  -u GIT_PREFIX
  -u GIT_SUPER_PREFIX
  -u GIT_INTERNAL_SUPER_PREFIX
  git
  --no-optional-locks
)

usage() {
  print -ru2 -- \
    "usage: $0 [--iterations N] [--warmup N] [--output PATH|-] [--cwd PATH]" \
    "          [--] [nbsp-binary] [prompt|data|dirs]"
}

percent_encode() {
  emulate -L zsh
  setopt NO_MULTIBYTE
  local input=$1 encoded= char hex
  integer index
  for (( index = 1; index <= ${#input}; ++index )); do
    char=$input[$index]
    case $char in
      [A-Za-z0-9._~/:+,]|-)
        encoded+=$char
        ;;
      *)
        printf -v hex '%02X' "'$char"
        encoded+="%$hex"
        ;;
    esac
  done
  REPLY=$encoded
}

write_text_field() {
  percent_encode "$2"
  print -r -- "$1=$REPLY"
}

sha256_file() {
  local path=$1 digest_line digest
  if (( $+commands[sha256sum] )); then
    digest_line=$(command sha256sum "$path") || return 1
  elif (( $+commands[shasum] )); then
    digest_line=$(command shasum -a 256 "$path") || return 1
  else
    return 1
  fi
  digest=${digest_line%%[[:space:]]*}
  [[ ${#digest} == 64 && $digest != *[^0-9A-Fa-f]* ]] || return 1
  REPLY=${digest:l}
}

git_dirty_state() {
  emulate -L zsh
  setopt PIPE_FAIL
  local root=$1 first_record
  if ! first_record=$("${clean_git_command[@]}" -C "$root" status \
      --porcelain --untracked-files=normal --ignore-submodules=none \
      2>/dev/null | command sed -n '1p'); then
    REPLY=unreported
  elif [[ -n $first_record ]]; then
    REPLY=dirty
  else
    REPLY=clean
  fi
}

git_repo_root() {
  emulate -L zsh
  local directory=$1 result
  if result=$("${clean_git_command[@]}" -C "$directory" rev-parse \
      --show-toplevel 2>&1); then
    REPLY=${result:A}
    REPLY_STATUS=found
  elif [[ $result == 'fatal: not a git repository'* ]]; then
    REPLY=none
    REPLY_STATUS=none
  else
    REPLY=unreported
    REPLY_STATUS=error
  fi
}

iterations=${NBSP_BENCH_ITERATIONS:-1000}
warmup=${NBSP_BENCH_WARMUP:-100}
output=${NBSP_BENCH_OUTPUT:--}
bench_cwd=${NBSP_BENCH_CWD:-$PWD}
prompt_status=${NBSP_BENCH_STATUS:-17}
duration_ms=${NBSP_BENCH_DURATION_MS:-2345}
jobs=${NBSP_BENCH_JOBS:-2}
prompt_options=${NBSP_BENCH_PROMPT_OPTIONS:-percent}

while (( $# > 0 )); do
  case $1 in
    --iterations)
      (( $# >= 2 )) || { usage; exit 2; }
      iterations=$2
      shift 2
      ;;
    --warmup)
      (( $# >= 2 )) || { usage; exit 2; }
      warmup=$2
      shift 2
      ;;
    --output)
      (( $# >= 2 )) || { usage; exit 2; }
      output=$2
      shift 2
      ;;
    --cwd)
      (( $# >= 2 )) || { usage; exit 2; }
      bench_cwd=$2
      shift 2
      ;;
    --)
      shift
      break
      ;;
    -*)
      usage
      exit 2
      ;;
    *)
      break
      ;;
  esac
done

binary=${1:-./build/nbsp}
mode=${2:-prompt}
(( $# <= 2 )) || { usage; exit 2; }
case $mode in
  prompt|data|dirs) ;;
  *)
    usage
    exit 2
    ;;
esac

[[ $iterations == <1-> && ${#iterations} -le 6 ]] || {
  print -ru2 -- 'iterations must be an integer from 1 through 100000'
  exit 2
}
[[ $warmup == <0-> && ${#warmup} -le 6 ]] || {
  print -ru2 -- 'warmup must be an integer from 0 through 100000'
  exit 2
}
integer iterations_value=$(( 10#$iterations ))
integer warmup_value=$(( 10#$warmup ))
(( iterations_value >= 1 && iterations_value <= max_iterations )) || {
  print -ru2 -- 'iterations must be an integer from 1 through 100000'
  exit 2
}
(( warmup_value >= 0 && warmup_value <= max_warmup )) || {
  print -ru2 -- 'warmup must be an integer from 0 through 100000'
  exit 2
}
iterations=$iterations_value
warmup=$warmup_value

if [[ $mode != dirs ]]; then
  [[ $prompt_status == <0-> && ${#prompt_status} -le 3 ]] || {
    print -ru2 -- 'NBSP_BENCH_STATUS must be an integer from 0 through 255'
    exit 2
  }
  integer prompt_status_value=$(( 10#$prompt_status ))
  (( prompt_status_value <= 255 )) || {
    print -ru2 -- 'NBSP_BENCH_STATUS must be an integer from 0 through 255'
    exit 2
  }
  prompt_status=$prompt_status_value

  [[ $duration_ms == <0-> && ${#duration_ms} -le 18 ]] || {
    print -ru2 -- 'NBSP_BENCH_DURATION_MS must be a non-negative integer of at most 18 digits'
    exit 2
  }
  [[ $jobs == <0-> && ${#jobs} -le 10 ]] || {
    print -ru2 -- 'NBSP_BENCH_JOBS must be an integer from 0 through 2147483647'
    exit 2
  }
  integer duration_value=$(( 10#$duration_ms ))
  integer jobs_value=$(( 10#$jobs ))
  (( duration_value >= 0 )) || {
    print -ru2 -- 'NBSP_BENCH_DURATION_MS exceeds Zsh integer range'
    exit 2
  }
  (( jobs_value >= 0 && jobs_value <= 2147483647 )) || {
    print -ru2 -- 'NBSP_BENCH_JOBS must be an integer from 0 through 2147483647'
    exit 2
  }
  duration_ms=$duration_value
  jobs=$jobs_value
fi

[[ -n $output ]] || {
  print -ru2 -- 'output path must not be empty'
  exit 2
}
[[ $mode != prompt || -n $prompt_options ]] || {
  print -ru2 -- 'NBSP_BENCH_PROMPT_OPTIONS must not be empty'
  exit 2
}
[[ -d $bench_cwd ]] || {
  print -ru2 -- "benchmark cwd is not a directory: $bench_cwd"
  exit 2
}

binary=${binary:A}
bench_cwd=${bench_cwd:A}
[[ -x $binary && -f $binary ]] || {
  print -ru2 -- "nbsp binary is not an executable regular file: $binary"
  exit 2
}

if [[ $output != - ]]; then
  output=${output:a}
  [[ ! -d $output && -d ${output:h} ]] || {
    print -ru2 -- "output must name a file in an existing directory: $output"
    exit 2
  }
  [[ ! -h $output ]] || {
    print -ru2 -- "output must not be a symbolic link: $output"
    exit 2
  }
  if [[ -e $output && ! -f $output ]]; then
    print -ru2 -- "existing output must be a regular file: $output"
    exit 2
  fi
  output_identity=${output:h:A}/${output:t}
  if [[ $output_identity == $binary ]] || \
      { [[ -e $output ]] && [[ $output -ef $binary ]]; }; then
    print -ru2 -- 'output must not replace the benchmarked binary'
    exit 2
  fi
fi

typeset -a invocation
case $mode in
  prompt)
    invocation=(
      "$binary" prompt
      --status "$prompt_status"
      --duration-ms "$duration_ms"
      --jobs "$jobs"
      --prompt-options "$prompt_options"
    )
    ;;
  data)
    invocation=(
      "$binary" data
      --status "$prompt_status"
      --duration-ms "$duration_ms"
      --jobs "$jobs"
      --format lines
    )
    ;;
  dirs)
    invocation=("$binary" dirs --cwd "$bench_cwd")
    ;;
esac

# Capture provenance before warm-up or measured invocations can alter caches.
timestamp_start_utc=$(TZ=UTC command date '+%Y-%m-%dT%H:%M:%SZ')
binary_version_before=$("$binary" --version)
binary_size_before=$(command wc -c < "$binary")
binary_size_before=${binary_size_before//[[:space:]]/}
sha256_file "$binary" || {
  print -ru2 -- 'a working sha256sum or shasum command is required'
  exit 1
}
binary_sha256_before=$REPLY

harness_checkout=${0:A:h:h}
sha256_file "$harness_checkout/bench/benchmark.zsh" || {
  print -ru2 -- 'could not hash the benchmark harness'
  exit 1
}
harness_script_sha256=$REPLY
harness_repo_root=none
harness_revision=unreported
harness_dirty=not-applicable
git_repo_root "$harness_checkout"
harness_repo_root=$REPLY
if [[ $REPLY_STATUS == found ]]; then
  harness_revision=$("${clean_git_command[@]}" -C "$harness_repo_root" \
    rev-parse --verify HEAD 2>/dev/null) || harness_revision=unreported
  git_dirty_state "$harness_repo_root"
  harness_dirty=$REPLY
elif [[ $REPLY_STATUS == error ]]; then
  harness_dirty=unreported
fi

workload_repo_root=none
workload_head=none
workload_dirty=not-applicable
git_repo_root "$bench_cwd"
workload_repo_root=$REPLY
if [[ $REPLY_STATUS == found ]]; then
  workload_head=$("${clean_git_command[@]}" -C "$workload_repo_root" \
    rev-parse --verify HEAD \
    2>/dev/null) || workload_head=unreported
  git_dirty_state "$workload_repo_root"
  workload_dirty=$REPLY
elif [[ $REPLY_STATUS == error ]]; then
  workload_head=unreported
  workload_dirty=unreported
fi

system=$(command uname -srm)
os_build=$(command uname -v)
if (( $+commands[sw_vers] )); then
  product_version=$(command sw_vers -productVersion 2>/dev/null) || product_version=unreported
  build_version=$(command sw_vers -buildVersion 2>/dev/null) || build_version=unreported
  os_build="$product_version ($build_version)"
fi
cpu_brand=unreported
hardware_model=unreported
if (( $+commands[sysctl] )) && \
    cpu_value=$(command sysctl -n machdep.cpu.brand_string 2>/dev/null) && \
    [[ -n $cpu_value ]]; then
  cpu_brand=$cpu_value
fi
if (( $+commands[sysctl] )) && \
    hardware_value=$(command sysctl -n hw.model 2>/dev/null) && \
    [[ -n $hardware_value ]]; then
  hardware_model=$hardware_value
fi

binary_source_revision=${NBSP_BENCH_SOURCE_REVISION:-unreported}
binary_source_dirty=${NBSP_BENCH_SOURCE_DIRTY:-unreported}
build_type=${NBSP_BENCH_BUILD_TYPE:-unreported}
compiler=${NBSP_BENCH_COMPILER:-unreported}
compiler_flags=${NBSP_BENCH_CFLAGS:-unreported}
linker_flags=${NBSP_BENCH_LDFLAGS:-unreported}
cache_dir_env=${NBSP_CACHE_DIR-<unset>}
xdg_cache_home_env=${XDG_CACHE_HOME-<unset>}
git_timeout_env=${NBSP_GIT_TIMEOUT_MS-<unset>}
nvm_bin_env=${NVM_BIN-<unset>}
if (( ${+NBSP_CACHE_DIR} )); then
  cache_root_candidate=$NBSP_CACHE_DIR
elif [[ ${XDG_CACHE_HOME-} == /* ]]; then
  cache_root_candidate=$XDG_CACHE_HOME/nbsp
elif (( ${+HOME} )); then
  cache_root_candidate=$HOME/Library/Caches/nbsp
else
  cache_root_candidate=unavailable
fi
zsh_version=$ZSH_VERSION
invocation_text=${(j: :)${(@qq)invocation}}

typeset -a snapshot_invocation
case $mode in
  prompt|data)
    snapshot_invocation=(
      "$binary" data
      --status "$prompt_status"
      --duration-ms "$duration_ms"
      --jobs "$jobs"
      --format nul
    )
    workload_snapshot_kind=data-nul
    ;;
  dirs)
    snapshot_invocation=("$binary" dirs --cwd "$bench_cwd" --format nul)
    workload_snapshot_kind=dirs-nul
    ;;
esac

temp_root=${TMPDIR:-/tmp}
[[ $temp_root == /* && -d $temp_root ]] || {
  print -ru2 -- 'TMPDIR must be an absolute path to an existing directory'
  exit 2
}
temp_root=${temp_root:A}
sample_file=
report_file=
workload_before_file=
workload_after_file=
cleanup() {
  [[ -z $sample_file ]] || rm -f -- "$sample_file"
  [[ -z $report_file ]] || rm -f -- "$report_file"
  [[ -z $workload_before_file ]] || rm -f -- "$workload_before_file"
  [[ -z $workload_after_file ]] || rm -f -- "$workload_after_file"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
sample_file=$(mktemp "$temp_root/nbsp-bench-samples.XXXXXX")
sample_file=${sample_file:A}
workload_before_file=$(mktemp "$temp_root/nbsp-bench-workload-before.XXXXXX")
workload_before_file=${workload_before_file:A}
workload_after_file=$(mktemp "$temp_root/nbsp-bench-workload-after.XXXXXX")
workload_after_file=${workload_after_file:A}

builtin cd -- "$bench_cwd"

"${snapshot_invocation[@]}" > "$workload_before_file"
workload_snapshot_size=$(command wc -c < "$workload_before_file")
workload_snapshot_size=${workload_snapshot_size//[[:space:]]/}
sha256_file "$workload_before_file" || {
  print -ru2 -- 'could not hash the initial workload snapshot'
  exit 1
}
workload_snapshot_sha256=$REPLY

for (( index = 1; index <= warmup; ++index )); do
  "${invocation[@]}" >/dev/null
done

typeset -a samples
for (( index = 1; index <= iterations; ++index )); do
  start=$EPOCHREALTIME
  "${invocation[@]}" >/dev/null
  elapsed=$(( (EPOCHREALTIME - start) * 1000.0 ))
  (( elapsed >= 0.0 && elapsed <= 86400000.0 )) || {
    print -ru2 -- 'wall-clock timing produced a negative, non-finite, or implausible interval'
    exit 1
  }
  samples+=( "$elapsed" )
done
printf '%.6f\n' "${samples[@]}" > "$sample_file"

typeset -a values
values=( ${(f)"$(command sort -n -- "$sample_file")"} )
(( ${#values} == iterations )) || {
  print -ru2 -- 'sample count changed while sorting'
  exit 1
}
integer p50_index=$(( (iterations * 50 + 99) / 100 ))
integer p95_index=$(( (iterations * 95 + 99) / 100 ))
float total=0.0
for value in $values; do
  total=$(( total + value ))
done

# Refuse to publish a report if an observable workload input changed mid-run.
"${snapshot_invocation[@]}" > "$workload_after_file"
workload_snapshot_size_after=$(command wc -c < "$workload_after_file")
workload_snapshot_size_after=${workload_snapshot_size_after//[[:space:]]/}
sha256_file "$workload_after_file" || {
  print -ru2 -- 'could not hash the final workload snapshot'
  exit 1
}
workload_snapshot_sha256_after=$REPLY
if [[ $workload_snapshot_size_after != $workload_snapshot_size || \
      $workload_snapshot_sha256_after != $workload_snapshot_sha256 ]]; then
  print -ru2 -- 'observable workload snapshot changed during the run; report discarded'
  exit 1
fi

if [[ $workload_repo_root != none ]]; then
  workload_repo_after=$("${clean_git_command[@]}" -C "$bench_cwd" \
    rev-parse --show-toplevel 2>/dev/null) || workload_repo_after=unreported
  [[ $workload_repo_after == unreported ]] || \
    workload_repo_after=${workload_repo_after:A}
  workload_head_after=$("${clean_git_command[@]}" -C "$workload_repo_root" \
    rev-parse --verify HEAD 2>/dev/null) || workload_head_after=unreported
  git_dirty_state "$workload_repo_root"
  workload_dirty_after=$REPLY
  if [[ $workload_repo_after != $workload_repo_root || \
        $workload_head_after != $workload_head || \
        $workload_dirty_after != $workload_dirty ]]; then
    print -ru2 -- 'workload repository summary changed during the run; report discarded'
    exit 1
  fi
fi

# Refuse to publish a report if the measured executable changed mid-run.
binary_version_after=$("$binary" --version)
binary_size_after=$(command wc -c < "$binary")
binary_size_after=${binary_size_after//[[:space:]]/}
sha256_file "$binary" || {
  print -ru2 -- 'could not re-hash the benchmarked binary'
  exit 1
}
binary_sha256_after=$REPLY
if [[ $binary_version_after != $binary_version_before || \
      $binary_size_after != $binary_size_before || \
      $binary_sha256_after != $binary_sha256_before ]]; then
  print -ru2 -- 'benchmarked binary changed during the run; report discarded'
  exit 1
fi
timestamp_end_utc=$(TZ=UTC command date '+%Y-%m-%dT%H:%M:%SZ')

if [[ $output == - ]]; then
  report_file=$(mktemp "$temp_root/nbsp-bench-report.XXXXXX")
else
  report_file=$(mktemp "${output:h}/.nbsp-bench-report.XXXXXX")
fi
report_file=${report_file:A}

{
  print -r -- 'format_version=2'
  print -r -- 'text_encoding=percent-bytes'
  write_text_field timestamp_start_utc "$timestamp_start_utc"
  write_text_field timestamp_end_utc "$timestamp_end_utc"
  write_text_field system "$system"
  write_text_field os_build "$os_build"
  write_text_field cpu_brand "$cpu_brand"
  write_text_field hardware_model "$hardware_model"
  write_text_field zsh_version "$zsh_version"
  write_text_field timing_clock EPOCHREALTIME-wall-clock
  write_text_field harness_repo_root "$harness_repo_root"
  write_text_field harness_revision "$harness_revision"
  write_text_field harness_dirty "$harness_dirty"
  print -r -- "harness_script_sha256=$harness_script_sha256"
  write_text_field binary_source_revision_declared "$binary_source_revision"
  write_text_field binary_source_dirty_declared "$binary_source_dirty"
  write_text_field build_type_declared "$build_type"
  write_text_field compiler_declared "$compiler"
  write_text_field compiler_flags_declared "$compiler_flags"
  write_text_field linker_flags_declared "$linker_flags"
  write_text_field binary "$binary"
  write_text_field binary_version "$binary_version_before"
  print -r -- "binary_size_bytes=$binary_size_before"
  print -r -- "binary_sha256=$binary_sha256_before"
  write_text_field cwd "$bench_cwd"
  write_text_field workload_repo_root "$workload_repo_root"
  write_text_field workload_head "$workload_head"
  write_text_field workload_dirty "$workload_dirty"
  write_text_field workload_snapshot_kind "$workload_snapshot_kind"
  print -r -- "workload_snapshot_size_bytes=$workload_snapshot_size"
  print -r -- "workload_snapshot_sha256=$workload_snapshot_sha256"
  write_text_field cache_root_candidate "$cache_root_candidate"
  write_text_field nbsp_cache_dir_env "$cache_dir_env"
  write_text_field xdg_cache_home_env "$xdg_cache_home_env"
  write_text_field nbsp_git_timeout_ms_env "$git_timeout_env"
  write_text_field nvm_bin_env "$nvm_bin_env"
  write_text_field mode "$mode"
  write_text_field invocation "$invocation_text"
  print -r -- "warmup=$warmup"
  print -r -- "iterations=$iterations"
  printf 'mean_ms=%.6f\n' $(( total / iterations ))
  printf 'p50_ms=%.6f\n' ${values[$p50_index]}
  printf 'p95_ms=%.6f\n' ${values[$p95_index]}
  printf 'min_ms=%.6f\n' ${values[1]}
  printf 'max_ms=%.6f\n' ${values[-1]}
  for value in $values; do
    printf 'sample_sorted_ms=%.6f\n' $value
  done
} > "$report_file"

if [[ $output == - ]]; then
  command cat -- "$report_file"
else
  command mv -f -- "$report_file" "$output"
  print -r -- "wrote benchmark report: $output"
fi
