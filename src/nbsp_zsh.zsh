if [[ -z ${_NBSP_INITIALIZED-} ]]; then
  typeset -g _NBSP_INITIALIZED=1
  typeset -g _nbsp_mode=${_NBSP_INIT_MODE:-prompt}
  autoload -Uz add-zsh-hook edit-command-line
  zmodload zsh/datetime
  zmodload zsh/parameter
  zmodload zsh/system 2>/dev/null

  typeset -gx NBSP_GIT_TIMEOUT_MS=${NBSP_GIT_TIMEOUT_MS:-1500}
  [[ -n ${NBSP_CACHE_DIR-} ]] && export NBSP_CACHE_DIR

  typeset -gF _nbsp_started_at=0
  typeset -gi _nbsp_last_status=0
  typeset -gi _nbsp_last_duration_ms=0
  typeset -gi _nbsp_last_jobs=0
  typeset -gi _nbsp_refresh_fd=-1
  typeset -gi _nbsp_refresh_again=0
  typeset -g _nbsp_refresh_pwd=
  typeset -g _nbsp_prompt_body=

  if [[ $_nbsp_mode == detached ]]; then
    typeset -gA NBSP_DATA
    typeset -ga nbsp_data_update_functions
  fi

  nbsp_prompt_quote() {
    local LC_ALL=C input=${1-} char hex
    local -i index repetitions repeat substitute=0
    [[ -o promptsubst ]] && substitute=1
    if (( substitute )); then
      REPLY='${(g::):-'
    else
      REPLY=
    fi
    for (( index = 1; index <= ${#input}; index++ )); do
      char=$input[index]
      [[ $char == [[:cntrl:]] ]] && char='?'
      repetitions=1
      if [[ $char == \! && -o promptbang ]] ||
          [[ $char == % && -o promptpercent ]]; then
        repetitions=2
      fi
      for (( repeat = 0; repeat < repetitions; repeat++ )); do
        if (( substitute )); then
          printf -v hex '%02X' "'$char"
          REPLY+="\\x$hex"
        else
          REPLY+=$char
        fi
      done
    done
    (( substitute )) && REPLY+='}'
  }

  _nbsp_render() {
    local rendered old pattern kept_prefix kept_suffix prompt_option_list
    local -a prompt_options
    [[ -o promptpercent ]] && prompt_options+=(percent)
    [[ -o promptsubst ]] && prompt_options+=(subst)
    [[ -o promptbang ]] && prompt_options+=(bang)
    prompt_option_list=${(j:,:)prompt_options}
    [[ -n $prompt_option_list ]] || prompt_option_list=none
    rendered=$(command nbsp prompt \
      --status "$_nbsp_last_status" \
      --duration-ms "$_nbsp_last_duration_ms" \
      --jobs "$_nbsp_last_jobs" \
      --prompt-options "$prompt_option_list")
    if [[ $? != 0 || -z $rendered ]]; then
      rendered='> '
    fi
    old=$_nbsp_prompt_body
    if [[ -n $old ]]; then
      pattern=${(b)old}
    fi
    if [[ -n $old && $PROMPT == *${~pattern}* ]]; then
      kept_prefix=${PROMPT%%${~pattern}*}
      kept_suffix=${PROMPT#*${~pattern}}
      PROMPT=${kept_prefix}${rendered}${kept_suffix}
    else
      PROMPT=$rendered
    fi
    _nbsp_prompt_body=$rendered
  }

  _nbsp_load_data() {
    local key value callback
    local -A next
    local -i count=0
    while IFS= read -r -d '' key && IFS= read -r -d '' value; do
      case $key in
        schema_version|cwd|path|status|duration_ms|jobs|node_version|\
        git_present|git_valid|git_branch|git_updated_ms|git_staged|\
        git_modified|git_untracked|git_conflicted|git_ahead|git_behind|\
        git_stashes) ;;
        *) return 1 ;;
      esac
      (( $+next[$key] )) && return 1
      next[$key]=$value
      (( count++ ))
    done < <(command nbsp data \
      --status "$_nbsp_last_status" \
      --duration-ms "$_nbsp_last_duration_ms" \
      --jobs "$_nbsp_last_jobs" \
      --format nul)
    (( count == 18 && next[schema_version] == 1 )) || return 1
    NBSP_DATA=( "${(@kv)next}" )
    for callback in "${nbsp_data_update_functions[@]}"; do
      (( $+functions[$callback] )) && "$callback"
    done
    return 0
  }

  _nbsp_cancel_refresh() {
    if (( _nbsp_refresh_fd >= 0 )); then
      zle -F "$_nbsp_refresh_fd" 2>/dev/null
      { exec {_nbsp_refresh_fd}<&- } 2>/dev/null
      _nbsp_refresh_fd=-1
    fi
    _nbsp_refresh_again=0
    _nbsp_refresh_pwd=
  }

  _nbsp_refresh_done() {
    local fd=$1 ignored refresh_pwd=$_nbsp_refresh_pwd
    local -i refresh_again=$_nbsp_refresh_again
    read -r -u "$fd" ignored 2>/dev/null
    zle -F "$fd" 2>/dev/null
    { exec {fd}<&- } 2>/dev/null
    (( fd == _nbsp_refresh_fd )) || return
    _nbsp_refresh_fd=-1
    _nbsp_refresh_again=0
    if [[ $PWD == $refresh_pwd ]]; then
      if (( refresh_again )); then
        _nbsp_schedule_refresh 1
      else
        if [[ $_nbsp_mode == detached ]]; then
          _nbsp_load_data && zle reset-prompt 2>/dev/null
        else
          _nbsp_render
          zle reset-prompt 2>/dev/null
        fi
      fi
    fi
  }

  _nbsp_schedule_refresh() {
    local -i force=${1:-0}
    local -i raw_fd=-1
    local -a refresh_args=(refresh --cwd "$PWD" --notify)
    if (( _nbsp_refresh_fd >= 0 )); then
      [[ $_nbsp_refresh_pwd == $PWD ]] && return
      _nbsp_cancel_refresh
    fi
    (( force )) && refresh_args+=(--force)
    _nbsp_refresh_pwd=$PWD
    _nbsp_refresh_again=0
    exec {raw_fd}< <(command nbsp "${refresh_args[@]}" 2>/dev/null)
    if (( $+builtins[sysopen] )) && \
        sysopen -o cloexec -ru _nbsp_refresh_fd -- /dev/fd/$raw_fd 2>/dev/null; then
      { exec {raw_fd}<&- } 2>/dev/null
    else
      _nbsp_refresh_fd=$raw_fd
    fi
    if ! zle -F "$_nbsp_refresh_fd" _nbsp_refresh_done 2>/dev/null; then
      _nbsp_cancel_refresh
    fi
  }

  _nbsp_preexec() {
    (( _nbsp_refresh_fd >= 0 )) && _nbsp_refresh_again=1
    _nbsp_started_at=$EPOCHREALTIME
  }

  _nbsp_precmd() {
    _nbsp_last_status=$?
    if (( _nbsp_started_at > 0 )); then
      _nbsp_last_duration_ms=$(( (EPOCHREALTIME - _nbsp_started_at) * 1000.0 ))
    else
      _nbsp_last_duration_ms=0
    fi
    _nbsp_started_at=0
    _nbsp_last_jobs=${#jobstates}
    if [[ $_nbsp_mode == detached ]]; then
      _nbsp_load_data
    else
      _nbsp_render
    fi
    _nbsp_schedule_refresh
  }

  _nbsp_chpwd() {
    _nbsp_cancel_refresh
  }

  add-zsh-hook preexec _nbsp_preexec
  add-zsh-hook precmd _nbsp_precmd
  add-zsh-hook chpwd _nbsp_chpwd

  _nbsp_edit_command_line() {
    local -i editor_status=0 track_cursor=0 had_editor_style=0
    local -i changed_editor_style=0 is_vim=0
    local -i cursor=0 index=0
    local -a editor saved_editor lines
    local editor_word cursor_file cursor_record extra escaped_cursor_file
    local initial_buffer final_buffer line column

    if [[ $CONTEXT == start ]] && (( ! REGION_ACTIVE )); then
      track_cursor=1
      if zstyle -a :zle:edit-command-line editor editor; then
        saved_editor=( "${editor[@]}" )
        had_editor_style=1
      fi
      if (( ! $#editor )); then
        editor=( "${(@Q)${(z)${VISUAL:-${EDITOR:-vi}}}}" )
      fi
      for editor_word in "${editor[@]}"; do
        case ${editor_word:t} in
          vi|vim|nvim) is_vim=1; break ;;
        esac
      done
    fi

    if (( track_cursor && is_vim )); then
      cursor_file=$(command mktemp "${TMPDIR:-/tmp}/nbsp-edit-cursor.XXXXXX" 2>/dev/null)
      if [[ -n $cursor_file ]]; then
        escaped_cursor_file=${cursor_file//\'/\'\'}
        editor+=( -c "let g:nbsp_command_buffer=bufnr('%')" )
        editor+=( -c "autocmd VimLeave * call writefile([printf('%d %d %d %d', g:nbsp_command_buffer, bufnr('%'), line('.'), strchars(strpart(getline('.'), 0, col('.') - 1)) + 1)], '$escaped_cursor_file')" )
        zstyle :zle:edit-command-line editor "${editor[@]}"
        changed_editor_style=1
      fi
    fi

    {
      edit-command-line
      editor_status=$?
    } always {
      if (( changed_editor_style )); then
        if (( had_editor_style )); then
          zstyle :zle:edit-command-line editor "${saved_editor[@]}"
        else
          zstyle -d :zle:edit-command-line editor 2>/dev/null
        fi
      fi
      if [[ -n $cursor_file ]]; then
        [[ -s $cursor_file ]] && cursor_record=$(<$cursor_file)
        command rm -f -- "$cursor_file"
      fi
    }

    if (( track_cursor )); then
      read -r initial_buffer final_buffer line column extra <<< "$cursor_record"
      if [[ -z $extra && $initial_buffer == <-> && $final_buffer == <-> &&
            $line == <-> && $column == <-> &&
            ${#initial_buffer} -le 18 && ${#final_buffer} -le 18 &&
            ${#line} -le 18 && ${#column} -le 18 ]] &&
          (( initial_buffer == final_buffer && line >= 1 && column >= 1 )); then
        lines=( "${(@f)BUFFER}" )
        if (( line <= $#lines && column <= ${#lines[line]} + 1 )); then
          cursor=$(( column - 1 ))
          for (( index = 1; index < line; index++ )); do
            (( cursor += ${#lines[index]} + 1 ))
          done
          CURSOR=$cursor
        else
          CURSOR=$#BUFFER
        fi
      else
        CURSOR=$#BUFFER
      fi
    fi
    return $editor_status
  }

  zle -N edit-command-line _nbsp_edit_command_line
  for _nbsp_keymap in emacs viins vicmd; do
    if [[ $(bindkey -M "$_nbsp_keymap" '\ee' 2>/dev/null) == *' undefined-key' ]]; then
      bindkey -M "$_nbsp_keymap" '\ee' edit-command-line
    fi
  done
  unset _nbsp_keymap
fi
unset _NBSP_INIT_MODE
