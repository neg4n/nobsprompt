emulate -L zsh

# Check quoting against the established protocol goldens.
# Production quoting remains the canonical embedded Zsh function.

if (( $# != 1 )); then
  print -u2 -- 'usage: test_zsh_quote_parity.zsh /absolute/path/to/nbsp'
  exit 2
fi

typeset -gr nbsp=${1:A}

fail() {
  print -u2 -- "zsh quote parity: $1"
  exit 1
}

eval "$("$nbsp" init zsh --detached)" || fail 'init failed'

# Same payload as the original C test fixtures: "100% $(x) `y` ! \\\033\n"
typeset -g _nbsp_quote_sample=$'100% $(x) `y` ! \x5c\033\n'

unsetopt PROMPT_PERCENT PROMPT_SUBST PROMPT_BANG
nbsp_prompt_quote "$_nbsp_quote_sample"
[[ $REPLY == '100% $(x) `y` ! \??' ]] || fail "plain quote was '$REPLY'"

setopt PROMPT_PERCENT
unsetopt PROMPT_SUBST PROMPT_BANG
nbsp_prompt_quote "$_nbsp_quote_sample"
[[ $REPLY == '100%% $(x) `y` ! \??' ]] || fail "percent quote was '$REPLY'"

unsetopt PROMPT_PERCENT PROMPT_SUBST
setopt PROMPT_BANG
nbsp_prompt_quote "$_nbsp_quote_sample"
[[ $REPLY == '100% $(x) `y` !! \??' ]] || fail "bang quote was '$REPLY'"

setopt PROMPT_PERCENT PROMPT_SUBST PROMPT_BANG
nbsp_prompt_quote "$_nbsp_quote_sample"
[[ $REPLY == '${(g::):-'* ]] || fail "subst quote missing open: '$REPLY'"
[[ $REPLY == *'}' ]] || fail "subst quote missing close: '$REPLY'"
[[ $REPLY != *'$(x)'* ]] || fail "subst quote leaked command substitution"
[[ $REPLY != *'`'* ]] || fail "subst quote leaked backtick"
[[ $REPLY == *'\x25\x25'* ]] || fail "subst quote missing doubled percent hex"
[[ $REPLY == *'\x21\x21'* ]] || fail "subst quote missing doubled bang hex"

print -r -- ZSH-QUOTE-PARITY-PASS
