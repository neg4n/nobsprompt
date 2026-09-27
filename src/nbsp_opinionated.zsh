# Opinionated one-line prompt - the default shipped by `nbsp init zsh`.
# This is the same file the docs show. Treat it as a real template:
#   1. quote dynamic fields
#   2. build each segment only when it has something useful to say
#   3. assign PROMPT
#   4. register so redraws rebuild after every successful data load
#
# Skip if already installed (double eval of init is a no-op).
if (( ! $+functions[nbsp_opinionated_prompt] )); then

nbsp_opinionated_prompt() {
  emulate -L zsh
  local path= git= node= duration= jobs= end= piece=
  local -i ms=0 secs=0 mins=0 rem=0 tenths=0 whole=0 frac=0

  # Anything from the backend (path, branch, node, …) must be quoted before
  # it enters PROMPT. That keeps % ! and control characters from breaking
  # prompt expansion under PROMPT_PERCENT / PROMPT_BANG / PROMPT_SUBST.
  nbsp_prompt_quote "${NBSP_DATA[path]-}"
  path=$REPLY

  # Path is always drawn when collection succeeded (backend already abbreviated).
  path="%F{default}${path}%f"

  # Git: only when a repo was found and we have a branch (or short detached oid).
  # Counters come from the cache only when it matches the current HEAD (git_valid).
  # Marker order: staged, worktree, untracked, unmerged, ahead, behind, stashes.
  if [[ ${NBSP_DATA[git_present]-} == 1 && -n ${NBSP_DATA[git_branch]-} ]]; then
    nbsp_prompt_quote "${NBSP_DATA[git_branch]}"
    git=" %F{default}[${REPLY}"
    if [[ ${NBSP_DATA[git_valid]-} == 1 ]]; then
      local -a marker_keys=(
        git_staged git_modified git_untracked git_conflicted
        git_ahead git_behind git_stashes
      )
      local -a marker_chars=('+' '~' '?' '!' '^' 'v' '*')
      local -i i
      for (( i = 1; i <= $#marker_keys; i++ )); do
        (( NBSP_DATA[${marker_keys[i]}] )) || continue
        nbsp_prompt_quote "${marker_chars[i]}"
        git+=" ${REPLY}${NBSP_DATA[${marker_keys[i]}]}"
      done
    else
      # Cache is missing or branch moved; keep the label but mark it stale.
      git+=' ...'
    fi
    git+=']%f'
  fi

  # Node version is parsed from NVM_BIN by the native backend (no node process).
  if [[ -n ${NBSP_DATA[node_version]-} ]]; then
    nbsp_prompt_quote "[node:${NBSP_DATA[node_version]}]"
    node=" %F{green}${REPLY}%f"
  fi

  # Duration only for slow commands (2 seconds and up), same rules as before.
  ms=${NBSP_DATA[duration_ms]-0}
  if (( ms >= 2000 )); then
    if (( ms < 60000 )); then
      tenths=$(( (ms + 50) / 100 ))
      whole=$(( tenths / 10 ))
      frac=$(( tenths % 10 ))
      piece="[${whole}.${frac}s]"
    else
      secs=$(( ms / 1000 ))
      mins=$(( secs / 60 ))
      rem=$(( secs % 60 ))
      printf -v piece '[%dm%02ds]' mins rem
    fi
    nbsp_prompt_quote "$piece"
    duration=" %F{yellow}${REPLY}%f"
  fi

  if (( NBSP_DATA[jobs]-0 > 0 )); then
    nbsp_prompt_quote "[jobs:${NBSP_DATA[jobs]}]"
    jobs=" %F{yellow}${REPLY}%f"
  fi

  # %# is % for you and # for root. Failures keep the exact exit status in red.
  if (( NBSP_DATA[status]-0 == 0 )); then
    end=' %# '
  else
    end="%F{red}e${NBSP_DATA[status]}%#%f "
  fi

  # Full ownership of PROMPT (no splicing). Add titles/OSC wrappers here if needed.
  PROMPT="${path}${git}${node}${duration}${jobs}${end}"
}

# Rebuild after every successful data frame (precmd and post-refresh).
nbsp_data_update_functions+=(nbsp_opinionated_prompt)
# Soft fallback may set PROMPT only when this flag is set (not for detached).
typeset -g _NBSP_OWNS_PROMPT=1

# First paint before the first prompt: load facts, then the callback runs.
if ! _nbsp_load_data && [[ -z ${NBSP_DATA[path]-} ]]; then
  PROMPT='> '
fi

fi
