emulate -L zsh

if (( $# != 1 )); then
  print -u2 -- 'usage: test_zsh_options.zsh /absolute/path/to/nbsp_zsh.zsh'
  exit 2
fi

typeset -gr init_source=${1:A}
typeset -g test_tmp
test_tmp=$(command mktemp -d "${TMPDIR:-/tmp}/nbsp-zsh-options.XXXXXX") || exit 1
trap 'command rm -rf -- "$test_tmp"' EXIT HUP INT TERM

fail() {
  print -u2 -- "zsh option isolation: $1"
  exit 1
}

command mkdir -p -- "$test_tmp/bin"
typeset -gr prompt_log=$test_tmp/prompt.log
{
  print -r -- '#!/bin/sh'
  print -r -- 'case $1 in'
  print -r -- '  prompt)'
  print -r -- '    printf "%s\n" "$*" >> "$NBSP_TEST_PROMPT_LOG"'
  print -r -- "    printf '%s\n' 'rendered> '"
  print -r -- '    ;;'
  print -r -- '  refresh)'
  print -r -- "    printf '\n'"
  print -r -- '    ;;'
  print -r -- '  *) exit 2 ;;'
  print -r -- 'esac'
} >| "$test_tmp/bin/nbsp"
command chmod 0700 "$test_tmp/bin/nbsp"

typeset -gx PATH=$test_tmp/bin:$PATH
typeset -gx NBSP_TEST_PROMPT_LOG=$prompt_log
typeset -g _NBSP_INIT_MODE=prompt

setopt KSH_ARRAYS SH_WORD_SPLIT EXTENDED_GLOB PROMPT_SUBST PROMPT_BANG
unsetopt PROMPT_PERCENT
source "$init_source" || fail 'initialization failed with hostile caller options'
[[ -o ksharrays && -o shwordsplit && -o extendedglob ]] ||
  fail 'initialization changed hostile caller options'
[[ ! -o promptpercent && -o promptsubst && -o promptbang ]] ||
  fail 'initialization changed caller prompt options'
preexec_functions=()
precmd_functions=()
chpwd_functions=()

nbsp_prompt_quote '%!'
[[ $REPLY == '${(g::):-\x25\x21\x21}' ]] ||
  fail "promptsubst/promptbang quote was '$REPLY'"
[[ -o ksharrays && -o shwordsplit && -o extendedglob ]] ||
  fail 'prompt quoting changed hostile caller options'
[[ ! -o promptpercent && -o promptsubst && -o promptbang ]] ||
  fail 'prompt quoting changed caller prompt options'

: >| "$prompt_log"
PROMPT='before> '
_nbsp_render || fail 'render failed with hostile caller options'
typeset render_args=
IFS= read -r render_args < "$prompt_log"
[[ $render_args == *'--prompt-options subst,bang'* ]] ||
  fail "render forwarded the wrong prompt options: '$render_args'"
[[ -o ksharrays && -o shwordsplit && -o extendedglob ]] ||
  fail 'render changed hostile caller options'
[[ ! -o promptpercent && -o promptsubst && -o promptbang ]] ||
  fail 'render changed caller prompt options'

setopt PROMPT_PERCENT
unsetopt PROMPT_SUBST PROMPT_BANG
nbsp_prompt_quote '%!'
[[ $REPLY == '%%!' ]] || fail "promptpercent quote was '$REPLY'"

: >| "$prompt_log"
false
_nbsp_precmd
typeset -i hook_status=$?
(( hook_status == 0 )) || fail "precmd returned $hook_status"
(( _nbsp_last_status == 1 )) || fail "precmd lost status 1 as $_nbsp_last_status"
IFS= read -r render_args < "$prompt_log"
[[ $render_args == *'--prompt-options percent'* ]] ||
  fail "precmd forwarded the wrong prompt options: '$render_args'"
[[ -o ksharrays && -o shwordsplit && -o extendedglob ]] ||
  fail 'precmd changed hostile caller options'
[[ -o promptpercent && ! -o promptsubst && ! -o promptbang ]] ||
  fail 'precmd changed caller prompt options'

_nbsp_preexec ignored || fail 'preexec returned nonzero'
_nbsp_chpwd || fail 'chpwd returned nonzero'
_nbsp_schedule_refresh 1 || fail 'refresh scheduling returned nonzero'
_nbsp_cancel_refresh || fail 'refresh cancellation returned nonzero'

setopt PROMPT_SUBST PROMPT_BANG
unsetopt PROMPT_PERCENT
: >| "$prompt_log"
typeset -gi refresh_fd=-1
exec {refresh_fd}< <(print)
_nbsp_refresh_fd=$refresh_fd
_nbsp_refresh_pwd=$PWD
_nbsp_refresh_again=0
_nbsp_refresh_done "$refresh_fd" || fail 'refresh callback returned nonzero'
IFS= read -r render_args < "$prompt_log"
[[ $render_args == *'--prompt-options subst,bang'* ]] ||
  fail "refresh callback forwarded the wrong prompt options: '$render_args'"
[[ -o ksharrays && -o shwordsplit && -o extendedglob ]] ||
  fail 'refresh callback changed hostile caller options'
[[ ! -o promptpercent && -o promptsubst && -o promptbang ]] ||
  fail 'refresh callback changed caller prompt options'

print -r -- ZSH-OPTION-ISOLATION-PASS
