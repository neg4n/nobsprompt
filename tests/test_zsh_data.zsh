emulate -L zsh

if (( $# != 2 )); then
  print -u2 -- 'usage: test_zsh_data.zsh /absolute/path/to/nbsp /absolute/path/to/nbsp_zsh.zsh'
  exit 2
fi

typeset -gr nbsp=${1:A}
typeset -gr init_source=${2:A}
typeset -g test_tmp
test_tmp=$(command mktemp -d "${TMPDIR:-/tmp}/nbsp-zsh-data.XXXXXX") || exit 1
trap 'command rm -rf -- "$test_tmp"' EXIT HUP INT TERM

fail() {
  print -u2 -- "zsh data protocol: $1"
  exit 1
}

command mkdir -p -- "$test_tmp/live" "$test_tmp/cache" "$test_tmp/fakebin"
typeset -gr good_frame=$test_tmp/good.frame
if ! (cd -- "$test_tmp/live" &&
    NBSP_CACHE_DIR="$test_tmp/cache" "$nbsp" data --format nul) >| "$good_frame"; then
  fail 'native data command failed'
fi

make_frame() {
  local mode=$1 target=$2 key value
  local -i pair_count=0
  {
    while IFS= read -r -d '' key && IFS= read -r -d '' value; do
      (( ++pair_count ))
      if [[ $mode == missing && $key == jobs ]]; then
        continue
      fi
      [[ $mode == schema1 && $key == schema_version ]] && value=1
      print -rn -- "$key"$'\0'"$value"$'\0'
    done < "$good_frame"
    (( pair_count == 18 )) || return 1
    case $mode in
      unknown)
        print -rn -- future2_key$'\0'$'opaque\nvalue'$'\0'
        ;;
      duplicate)
        print -rn -- cwd$'\0'/duplicate$'\0'
        ;;
      invalid_key)
        print -rn -- Future-field$'\0'opaque$'\0'
        ;;
      odd)
        print -rn -- orphan
        ;;
      trailer)
        print -rn -- $'\0'0$'\0'
        ;;
    esac
  } >| "$target"
}

typeset -gr unknown_frame=$test_tmp/unknown.frame
typeset -gr missing_frame=$test_tmp/missing.frame
typeset -gr duplicate_frame=$test_tmp/duplicate.frame
typeset -gr schema1_frame=$test_tmp/schema1.frame
typeset -gr invalid_key_frame=$test_tmp/invalid-key.frame
typeset -gr odd_frame=$test_tmp/odd.frame
typeset -gr trailer_frame=$test_tmp/trailer.frame
make_frame unknown "$unknown_frame" || fail 'could not create unknown-key fixture'
make_frame missing "$missing_frame" || fail 'could not create missing-key fixture'
make_frame duplicate "$duplicate_frame" || fail 'could not create duplicate-key fixture'
make_frame schema1 "$schema1_frame" || fail 'could not create schema-1 fixture'
make_frame invalid_key "$invalid_key_frame" || fail 'could not create invalid-key fixture'
make_frame odd "$odd_frame" || fail 'could not create malformed-frame fixture'
make_frame trailer "$trailer_frame" || fail 'could not create premature-trailer fixture'

{
  print -r -- '#!/bin/sh'
  print -r -- '/bin/cat "$NBSP_TEST_FRAME"'
  print -r -- 'exit "${NBSP_TEST_STATUS:-0}"'
} >| "$test_tmp/fakebin/nbsp"
command chmod 0700 "$test_tmp/fakebin/nbsp"

typeset -gx PATH=$test_tmp/fakebin:$PATH
typeset -gx NBSP_TEST_FRAME=$good_frame
typeset -gx NBSP_TEST_STATUS=0
typeset -g _NBSP_INIT_MODE=detached
setopt KSH_ARRAYS SH_WORD_SPLIT EXTENDED_GLOB
source "$init_source"
[[ -o ksharrays && -o shwordsplit && -o extendedglob ]] ||
  fail 'initialization changed hostile caller options'
unsetopt KSH_ARRAYS SH_WORD_SPLIT EXTENDED_GLOB

typeset -gi callback_count=0
data_protocol_callback() {
  (( ++callback_count ))
}
nbsp_data_update_functions=(data_protocol_callback)

expect_accepted() {
  local frame=$1 label=$2
  NBSP_DATA=(sentinel preserved)
  NBSP_TEST_FRAME=$frame
  NBSP_TEST_STATUS=0
  export NBSP_TEST_FRAME NBSP_TEST_STATUS
  setopt KSH_ARRAYS SH_WORD_SPLIT EXTENDED_GLOB
  _nbsp_load_data
  local -i load_status=$? options_preserved=0
  [[ -o ksharrays && -o shwordsplit && -o extendedglob ]] && options_preserved=1
  unsetopt KSH_ARRAYS SH_WORD_SPLIT EXTENDED_GLOB
  (( load_status == 0 )) || fail "$label was rejected"
  (( options_preserved )) || fail "$label changed hostile caller options"
  (( ${#NBSP_DATA} == 18 )) || fail "$label did not publish exactly 18 known fields"
  [[ ${NBSP_DATA[schema_version]-} == 2 ]] || fail "$label lost schema 2"
  [[ -n ${NBSP_DATA[cwd]-} ]] || fail "$label lost cwd"
  (( ${+NBSP_DATA[future2_key]} == 0 )) || fail "$label published an unknown field"
}

expect_rejected() {
  local frame=$1 producer_status=$2 label=$3
  local -i callbacks_before=$callback_count
  NBSP_DATA=(sentinel preserved)
  NBSP_TEST_FRAME=$frame
  NBSP_TEST_STATUS=$producer_status
  export NBSP_TEST_FRAME NBSP_TEST_STATUS
  setopt KSH_ARRAYS SH_WORD_SPLIT EXTENDED_GLOB
  _nbsp_load_data
  local -i load_status=$? options_preserved=0
  [[ -o ksharrays && -o shwordsplit && -o extendedglob ]] && options_preserved=1
  unsetopt KSH_ARRAYS SH_WORD_SPLIT EXTENDED_GLOB
  (( options_preserved )) || fail "$label changed hostile caller options"
  if (( load_status == 0 )); then
    fail "$label was accepted"
  fi
  (( ${#NBSP_DATA} == 1 )) || fail "$label partially replaced NBSP_DATA"
  [[ ${NBSP_DATA[sentinel]-} == preserved ]] || fail "$label changed the prior snapshot"
  (( callback_count == callbacks_before )) || fail "$label ran update callbacks"
}

expect_accepted "$good_frame" 'complete schema-2 frame'
expect_accepted "$unknown_frame" 'valid additive field'
expect_rejected "$missing_frame" 0 'missing known field'
expect_rejected "$duplicate_frame" 0 'duplicate known field'
expect_rejected "$schema1_frame" 0 'schema-1 frame'
expect_rejected "$invalid_key_frame" 0 'syntactically invalid unknown field'
expect_rejected "$odd_frame" 0 'unpaired frame data'
expect_rejected "$trailer_frame" 0 'producer-supplied completion trailer'
expect_rejected "$good_frame" 7 'nonzero producer status'

print -r -- ZSH-DATA-PROTOCOL-PASS
