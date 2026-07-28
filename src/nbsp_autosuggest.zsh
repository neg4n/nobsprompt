if [[ -z ${_NBSP_AUTOSUGGEST_INITIALIZED-} ]]; then
  typeset -g _NBSP_AUTOSUGGEST_INITIALIZED=1
  zmodload zsh/parameter

  if (( $+functions[_zsh_autosuggest_start] || $+widgets[autosuggest-accept] )); then
    print -ru2 -- 'nbsp: autosuggestions already provided by another ZLE integration'
  else
    autoload -Uz add-zle-hook-widget is-at-least
    zmodload zsh/system 2>/dev/null
    zmodload zsh/terminfo 2>/dev/null

    typeset -g NBSP_AUTOSUGGEST_HIGHLIGHT_STYLE=${NBSP_AUTOSUGGEST_HIGHLIGHT_STYLE:-fg=8}
    typeset -ga _nbsp_as_history _nbsp_as_dirs _nbsp_as_scan_dirs
    typeset -gi _nbsp_as_history_count=0
    typeset -gi _nbsp_as_scan_fd=-1 _nbsp_as_scan_pid=0
    typeset -gi _nbsp_as_scan_schema=0 _nbsp_as_scan_complete=0
    typeset -gi _nbsp_as_scan_have_key=0
    typeset -gi _nbsp_as_disabled=0
    typeset -gi _nbsp_as_highlight_memo=0
    typeset -g _nbsp_as_full= _nbsp_as_owned= _nbsp_as_highlight=
    typeset -g _nbsp_as_scan_state=empty _nbsp_as_scan_pwd= _nbsp_as_scan_key=
    typeset -g _nbsp_as_executable=${commands[nbsp]-}
    is-at-least 5.9 && _nbsp_as_highlight_memo=1

    _nbsp_as_rebuild_history() {
      emulate -L zsh
      local value
      local -i event=$((HISTCMD - 1)) examined=0
      _nbsp_as_history=()
      while (( event > 0 && $#_nbsp_as_history < 4096 && examined < 8192 )); do
        value=${history[$event]-}
        [[ -n $value ]] && _nbsp_as_history+=( "$value" )
        (( --event, ++examined ))
      done
      _nbsp_as_history_count=$#history
    }

    _nbsp_as_remove_highlight() {
      if [[ -n $_nbsp_as_highlight ]]; then
        local entry expected
        local -a kept
        local -i index target=0
        expected="$#BUFFER $(($#BUFFER + $#POSTDISPLAY)) $NBSP_AUTOSUGGEST_HIGHLIGHT_STYLE"
        for (( index = $#region_highlight; index >= 1; --index )); do
          entry=${region_highlight[index]}
          if (( _nbsp_as_highlight_memo )) &&
              [[ $entry == *' memo=nbsp-autosuggest' ]]; then
            target=$index
            break
          fi
          if [[ $entry == $_nbsp_as_highlight || $entry == $expected ]]; then
            target=$index
            break
          fi
        done
        if (( target > 0 )); then
          for (( index = 1; index <= $#region_highlight; ++index )); do
            (( index == target )) || kept+=( "${region_highlight[index]}" )
          done
          region_highlight=( "${(@)kept}" )
        fi
        _nbsp_as_highlight=
      fi
    }

    _nbsp_as_owns_display() {
      [[ -n $POSTDISPLAY &&
          ( $POSTDISPLAY == $_nbsp_as_owned ||
            ( -n $_nbsp_as_full && "$BUFFER$POSTDISPLAY" == $_nbsp_as_full ) ) ]]
    }

    _nbsp_as_clear_display() {
      local -i owned=0
      _nbsp_as_owns_display && owned=1
      _nbsp_as_remove_highlight
      (( owned )) && POSTDISPLAY=
      _nbsp_as_owned=
    }

    _nbsp_as_close_scan() {
      local -i fd=$_nbsp_as_scan_fd
      if (( fd >= 0 )); then
        zle -F "$fd" 2>/dev/null
        { exec {fd}<&- } 2>/dev/null
      fi
      _nbsp_as_scan_fd=-1
    }

    _nbsp_as_cancel_scan() {
      emulate -L zsh
      if (( _nbsp_as_scan_pid > 0 )); then
        kill -TERM -- "$_nbsp_as_scan_pid" 2>/dev/null
      fi
      _nbsp_as_scan_pid=0
      _nbsp_as_close_scan
      if [[ $_nbsp_as_scan_state == loading ]]; then
        _nbsp_as_scan_state=empty
      fi
      _nbsp_as_scan_dirs=()
      _nbsp_as_scan_schema=0
      _nbsp_as_scan_complete=0
      _nbsp_as_scan_have_key=0
      _nbsp_as_scan_key=
    }

    _nbsp_as_invalidate_dirs() {
      emulate -L zsh
      _nbsp_as_cancel_scan
      _nbsp_as_dirs=()
      _nbsp_as_scan_pwd=
      _nbsp_as_scan_state=empty
      _nbsp_as_full=
    }

    _nbsp_as_scan_done() {
      emulate -L zsh
      local -i fd=$1 invalid=0
      local event=${2-} key value
      while true; do
        if (( !_nbsp_as_scan_have_key )); then
          IFS= read -r -t 0 -d '' -u "$fd" _nbsp_as_scan_key || break
          _nbsp_as_scan_have_key=1
        fi
        IFS= read -r -t 0 -d '' -u "$fd" value || break
        key=$_nbsp_as_scan_key
        _nbsp_as_scan_key=
        _nbsp_as_scan_have_key=0
        case $key in
          schema_version)
            (( _nbsp_as_scan_schema == 0 && value == 1 )) || invalid=1
            _nbsp_as_scan_schema=1
            ;;
          dir)
            (( _nbsp_as_scan_complete == 0 &&
                $#_nbsp_as_scan_dirs < 1024 )) || invalid=1
            _nbsp_as_scan_dirs+=( "$value" )
            ;;
          complete)
            (( _nbsp_as_scan_schema == 1 &&
                _nbsp_as_scan_complete == 0 && value == 1 )) || invalid=1
            _nbsp_as_scan_complete=1
            ;;
          *) invalid=1 ;;
        esac
      done

      if (( invalid )); then
        _nbsp_as_cancel_scan
        _nbsp_as_scan_state=failed
        return
      fi
      if (( _nbsp_as_scan_complete )); then
        _nbsp_as_close_scan
        _nbsp_as_scan_pid=0
        if [[ $PWD == $_nbsp_as_scan_pwd ]]; then
          _nbsp_as_dirs=( "${(@)_nbsp_as_scan_dirs}" )
          _nbsp_as_scan_state=ready
        else
          _nbsp_as_dirs=()
          _nbsp_as_scan_state=empty
        fi
        _nbsp_as_scan_dirs=()
        _nbsp_as_pre_redraw
        zle -R 2>/dev/null
      elif [[ -n $event ]]; then
        _nbsp_as_cancel_scan
        _nbsp_as_scan_state=failed
      fi
    }

    _nbsp_as_schedule_scan() {
      [[ $_nbsp_as_scan_state == empty && -n $_nbsp_as_executable ]] || return
      local -i raw_fd=-1
      _nbsp_as_scan_pwd=$PWD
      _nbsp_as_scan_schema=0
      _nbsp_as_scan_complete=0
      _nbsp_as_scan_have_key=0
      _nbsp_as_scan_key=
      _nbsp_as_scan_dirs=()
      _nbsp_as_scan_state=loading
      exec {raw_fd}< <(
        print -r -- $sysparams[pid]
        exec "$_nbsp_as_executable" dirs --cwd "$_nbsp_as_scan_pwd" --format nul 2>/dev/null
      )
      if ! IFS= read -r -u "$raw_fd" _nbsp_as_scan_pid ||
          [[ $_nbsp_as_scan_pid != <-> || $_nbsp_as_scan_pid -le 0 ]]; then
        { exec {raw_fd}<&- } 2>/dev/null
        _nbsp_as_scan_pid=0
        _nbsp_as_scan_state=failed
        return
      fi
      if (( $+builtins[sysopen] )) &&
          sysopen -o cloexec -ru _nbsp_as_scan_fd -- /dev/fd/$raw_fd 2>/dev/null; then
        { exec {raw_fd}<&- } 2>/dev/null
      else
        _nbsp_as_scan_fd=$raw_fd
      fi
      if ! zle -F "$_nbsp_as_scan_fd" _nbsp_as_scan_done 2>/dev/null; then
        _nbsp_as_cancel_scan
        _nbsp_as_scan_state=failed
      fi
    }

    _nbsp_as_offer() {
      local full=$1 suffix
      [[ -n $full && $full != *$'\n'* && $full == "$BUFFER"* &&
          $full != "$BUFFER" ]] || return 1
      (( $#full <= 4096 )) || return 1
      suffix=${full#$BUFFER}
      POSTDISPLAY=$suffix
      _nbsp_as_owned=$suffix
      _nbsp_as_full=$full
      _nbsp_as_highlight="$#BUFFER $(($#BUFFER + $#suffix)) $NBSP_AUTOSUGGEST_HIGHLIGHT_STYLE"
      if (( _nbsp_as_highlight_memo )); then
        _nbsp_as_highlight+=' memo=nbsp-autosuggest'
      fi
      region_highlight+=( "$_nbsp_as_highlight" )
      return 0
    }

    _nbsp_as_directory_full() {
      local argument prefix lead= candidate escaped
      local LC_ALL=C
      local -i low=1 high=$#_nbsp_as_dirs middle
      [[ $BUFFER == 'cd '* ]] || return 1
      argument=${BUFFER[4,-1]}
      [[ -n $argument ]] || return 1
      if [[ $argument == ./* ]]; then
        lead=./
        prefix=${argument[3,-1]}
      else
        prefix=$argument
      fi
      [[ -n $prefix && $prefix != -* && $prefix != */* &&
          ${(q)prefix} == $prefix ]] || return 1

      if [[ $_nbsp_as_scan_state != ready || $_nbsp_as_scan_pwd != $PWD ]]; then
        _nbsp_as_schedule_scan
        return 1
      fi
      while (( low <= high )); do
        middle=$(( (low + high) / 2 ))
        if [[ ${_nbsp_as_dirs[middle]} < $prefix ]]; then
          low=$(( middle + 1 ))
        else
          high=$(( middle - 1 ))
        fi
      done
      (( low <= $#_nbsp_as_dirs )) || return 1
      candidate=${_nbsp_as_dirs[low]}
      [[ $candidate == "$prefix"* ]] || return 1
      if (( low < $#_nbsp_as_dirs )) &&
          [[ ${_nbsp_as_dirs[low + 1]} == "$prefix"* ]]; then
        return 1
      fi
      escaped=${(q)candidate}
      REPLY="cd ${lead}${escaped}/"
      return 0
    }

    _nbsp_as_pre_redraw() {
      emulate -L zsh
      setopt EXTENDED_GLOB
      _nbsp_as_clear_display
      [[ -z $POSTDISPLAY ]] || return
      if (( $+functions[_zsh_autosuggest_start] ||
          $+widgets[autosuggest-accept] )); then
        _nbsp_as_disabled=1
        _nbsp_as_cancel_scan
        _nbsp_as_full=
        return
      fi
      (( !_nbsp_as_disabled && $#BUFFER > 0 && $#BUFFER <= 256 &&
          CURSOR == $#BUFFER && !REGION_ACTIVE )) || return
      [[ $BUFFER != *$'\n'* && $BUFFER != [[:space:]]* ]] || return

      if [[ -n $_nbsp_as_full && $_nbsp_as_full == "$BUFFER"* ]]; then
        _nbsp_as_offer "$_nbsp_as_full"
        return
      fi
      _nbsp_as_full=
      (( PENDING == 0 && ${KEYS_QUEUED_COUNT:-0} == 0 )) || return

      local pattern="${(b)BUFFER}*" suggestion
      suggestion=${_nbsp_as_history[(r)$pattern]}
      if _nbsp_as_offer "$suggestion"; then
        return
      fi
      if _nbsp_as_directory_full; then
        _nbsp_as_offer "$REPLY"
      fi
    }

    _nbsp_as_line_finish() {
      emulate -L zsh
      _nbsp_as_clear_display
      _nbsp_as_cancel_scan
      _nbsp_as_full=
    }

    _nbsp_as_precmd() {
      emulate -L zsh
      local latest=${history[$((HISTCMD - 1))]-}
      if (( $#history < _nbsp_as_history_count ||
          $#history > _nbsp_as_history_count + 1 )); then
        _nbsp_as_rebuild_history
      elif [[ -n $latest && $latest != ${_nbsp_as_history[1]-} ]]; then
        _nbsp_as_history=( "$latest" "${(@)_nbsp_as_history[1,4095]}" )
        _nbsp_as_history_count=$#history
      else
        _nbsp_as_history_count=$#history
      fi
      _nbsp_as_invalidate_dirs
    }

    _nbsp_as_accept() {
      emulate -L zsh
      local suffix
      if (( CURSOR == $#BUFFER )) && _nbsp_as_owns_display; then
        suffix=$POSTDISPLAY
        _nbsp_as_clear_display
        BUFFER+=$suffix
        CURSOR=$#BUFFER
        _nbsp_as_full=
        zle -R
      else
        zle .forward-char
      fi
    }

    _nbsp_as_toggle() {
      emulate -L zsh
      (( _nbsp_as_disabled = !_nbsp_as_disabled ))
      if (( _nbsp_as_disabled )); then
        _nbsp_as_clear_display
        _nbsp_as_cancel_scan
        _nbsp_as_full=
      fi
      zle -R
    }

    _nbsp_as_rebuild_history
    add-zsh-hook precmd _nbsp_as_precmd
    add-zsh-hook preexec _nbsp_as_cancel_scan
    add-zsh-hook chpwd _nbsp_as_invalidate_dirs
    add-zle-hook-widget line-pre-redraw _nbsp_as_pre_redraw
    add-zle-hook-widget line-finish _nbsp_as_line_finish
    zle -N nbsp-autosuggest-accept _nbsp_as_accept
    zle -N nbsp-autosuggest-toggle _nbsp_as_toggle

    if [[ $widgets[forward-char] == builtin ]]; then
      typeset -ga _nbsp_as_right_keys
      _nbsp_as_right_keys=( "${terminfo[kcuf1]-}" $'\e[C' $'\eOC' )
      for _nbsp_as_keymap in emacs viins; do
        for _nbsp_as_right_key in "${(@u)_nbsp_as_right_keys}"; do
          if [[ -n $_nbsp_as_right_key &&
              $(bindkey -M "$_nbsp_as_keymap" "$_nbsp_as_right_key" 2>/dev/null) == *' forward-char' ]]; then
            bindkey -M "$_nbsp_as_keymap" "$_nbsp_as_right_key" nbsp-autosuggest-accept
          fi
        done
      done
      unset _nbsp_as_keymap _nbsp_as_right_key _nbsp_as_right_keys
    fi
  fi
fi
