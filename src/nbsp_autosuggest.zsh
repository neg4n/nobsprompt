if [[ -z ${_NBSP_AUTOSUGGEST_INITIALIZED-} ]]; then
  zmodload zsh/parameter

  if (( $+functions[_zsh_autosuggest_start] || $+widgets[autosuggest-accept] )); then
    print -ru2 -- 'nbsp: --autosuggest disabled because another autosuggestion plugin is active; use only one engine or remove --autosuggest'
  else
    typeset -g _NBSP_AUTOSUGGEST_INITIALIZED=1
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
    typeset -gi _nbsp_as_conflict_warned=0
    typeset -gi _nbsp_as_highlight_memo=0
    typeset -g _nbsp_as_full= _nbsp_as_full_kind= _nbsp_as_owned=
    typeset -g _nbsp_as_highlight=
    typeset -g _nbsp_as_scan_state=empty _nbsp_as_scan_pwd=
    typeset -g _nbsp_as_scan_root= _nbsp_as_scan_key=
    typeset -g _nbsp_as_executable=${_NBSP_BIN:-${commands[nbsp]-}}
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
      _nbsp_as_scan_root=
      _nbsp_as_scan_state=empty
      _nbsp_as_full=
      _nbsp_as_full_kind=
    }

    _nbsp_as_scan_done() {
      local -i caller_posix_cd=0
      [[ -o posixcd ]] && caller_posix_cd=1
      emulate -L zsh
      (( caller_posix_cd )) && setopt posixcd
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
        if [[ $PWD == $_nbsp_as_scan_pwd && -n $_nbsp_as_scan_root ]]; then
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
      local root=$1
      [[ -n $root && -n $_nbsp_as_executable ]] || return
      if [[ $_nbsp_as_scan_root == $root &&
          ( $_nbsp_as_scan_state == loading || $_nbsp_as_scan_state == ready ||
            $_nbsp_as_scan_state == failed ) ]]; then
        return
      fi
      _nbsp_as_cancel_scan
      _nbsp_as_dirs=()
      _nbsp_as_scan_state=empty
      local -i raw_fd=-1
      _nbsp_as_scan_pwd=$PWD
      _nbsp_as_scan_root=$root
      _nbsp_as_scan_schema=0
      _nbsp_as_scan_complete=0
      _nbsp_as_scan_have_key=0
      _nbsp_as_scan_key=
      _nbsp_as_scan_dirs=()
      _nbsp_as_scan_state=loading
      exec {raw_fd}< <(
        print -r -- $sysparams[pid]
        exec "$_nbsp_as_executable" dirs --cwd "$_nbsp_as_scan_root" --format nul 2>/dev/null
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
      local full=$1 kind=${2:-history} suffix
      [[ -n $full && $full != *$'\n'* && $full == "$BUFFER"* &&
          $full != "$BUFFER" ]] || return 1
      (( $#full <= 4096 )) || return 1
      suffix=${full#$BUFFER}
      POSTDISPLAY=$suffix
      _nbsp_as_owned=$suffix
      _nbsp_as_full=$full
      _nbsp_as_full_kind=$kind
      _nbsp_as_highlight="$#BUFFER $(($#BUFFER + $#suffix)) $NBSP_AUTOSUGGEST_HIGHLIGHT_STYLE"
      if (( _nbsp_as_highlight_memo )); then
        _nbsp_as_highlight+=' memo=nbsp-autosuggest'
      fi
      region_highlight+=( "$_nbsp_as_highlight" )
      return 0
    }

    _nbsp_as_static_quotes_complete() {
      local value=$1 character state=plain
      local -i index escaped=0
      for (( index = 1; index <= $#value; ++index )); do
        character=$value[index]
        if (( escaped )); then
          escaped=0
          continue
        fi
        if [[ $state == single ]]; then
          [[ $character == "'" ]] && state=plain
        elif [[ $state == double ]]; then
          if [[ $character == $'\\' ]]; then
            escaped=1
          elif [[ $character == '"' ]]; then
            state=plain
          fi
        elif [[ $character == $'\\' ]]; then
          escaped=1
        elif [[ $character == "'" ]]; then
          state=single
        elif [[ $character == '"' ]]; then
          state=double
        fi
      done
      [[ $state == plain && escaped -eq 0 ]]
    }

    _nbsp_as_pwd_is_first_cd_root() {
      emulate -L zsh
      local -i posix_cd=$1
      local component

      (( ! ${+cdpath} || $#cdpath == 0 )) && return 0
      if (( posix_cd )); then
        [[ -z ${cdpath[1]} || ${cdpath[1]} == . ]]
        return
      fi
      for component in "${(@)cdpath}"; do
        if [[ -z $component || $component == . ]]; then
          [[ -z ${cdpath[1]} || ${cdpath[1]} == . ]]
          return
        fi
      done
      return 0
    }

    _nbsp_as_parse_cd() {
      local -i caller_posix_cd=${2:--1}
      if (( caller_posix_cd < 0 )); then
        caller_posix_cd=0
        [[ -o posixcd ]] && caller_posix_cd=1
      fi
      emulate -L zsh
      local line=$1 raw_path path parent relative
      local -a words
      local -i has_double_dash=0 expand_home=0
      reply=()

      if [[ $line == 'cd ' || $line == 'cd -- ' ]]; then
        reply=( "$PWD" '' )
        return 0
      fi
      _nbsp_as_static_quotes_complete "$line" || return 1
      words=( ${(z)line} ) 2>/dev/null || return 1
      if (( $#words == 2 )) && [[ ${(Q)words[1]} == cd ]]; then
        raw_path=$words[2]
      elif (( $#words == 3 )) && [[ ${(Q)words[1]} == cd &&
          ${(Q)words[2]} == -- ]]; then
        raw_path=$words[3]
        has_double_dash=1
      else
        return 1
      fi
      [[ -n $raw_path ]] || return 1
      case $raw_path in
        *'$'*|*'`'*|*'*'*|*'?'*|*'['*|*']'*|*'{'*|*'}'*|*'('*|*')'*|\
        *'<'*|*'>'*|*'|'*|*'&'*|*';'*|*'^'*|*'#'*) return 1 ;;
      esac

      _nbsp_as_static_quotes_complete "$raw_path" || return 1
      path=${(Q)raw_path}
      [[ -n $path ]] || return 1
      (( has_double_dash )) || [[ $path != -* ]] || return 1
      [[ $raw_path != '='* ]] || return 1
      if [[ $raw_path == '~' || $raw_path == '~/'* ]]; then
        expand_home=1
      elif [[ $raw_path == '~'* ]]; then
        return 1
      fi
      if (( ! expand_home )) &&
          [[ $path != /* && $path != . && $path != .. &&
             $path != ./* && $path != ../* ]]; then
        _nbsp_as_pwd_is_first_cd_root "$caller_posix_cd" || return 1
      fi

      if [[ $path != */* ]]; then
        if (( expand_home )); then
          reply=( "$HOME" '' )
        else
          reply=( "$PWD" "$path" )
        fi
        return 0
      fi

      if (( expand_home )); then
        relative=${path#\~/}
        if [[ $relative == */* ]]; then
          parent=${relative%/*}
          reply=( "$HOME/$parent" "${relative##*/}" )
        else
          reply=( "$HOME" "$relative" )
        fi
      elif [[ $path == /* ]]; then
        parent=${path%/*}
        reply=( "${parent:-/}" "${path##*/}" )
      else
        parent=${path%/*}
        reply=( "$PWD/$parent" "${path##*/}" )
      fi
      return 0
    }

    _nbsp_as_rank_directory() {
      local root=$1 prefix=$2
      local -i first=$3 last=$4 caller_posix_cd=$5 low high middle
      local historical candidate
      local -a parsed reply
      local LC_ALL=C
      for historical in "${(@)_nbsp_as_history}"; do
        [[ $historical == "$BUFFER"* ]] || continue
        reply=()
        _nbsp_as_parse_cd "$historical" "$caller_posix_cd" || continue
        parsed=( "${(@)reply}" )
        [[ ${parsed[1]-} == $root && ${parsed[2]-} == "$prefix"* ]] || continue
        candidate=${parsed[2]}
        low=$first
        high=$last
        while (( low <= high )); do
          middle=$(( (low + high) / 2 ))
          if [[ ${_nbsp_as_dirs[middle]} < $candidate ]]; then
            low=$(( middle + 1 ))
          elif [[ ${_nbsp_as_dirs[middle]} > $candidate ]]; then
            high=$(( middle - 1 ))
          else
            REPLY=$candidate
            return 0
          fi
        done
      done
      return 1
    }

    _nbsp_as_directory_full() {
      local root=$1 prefix=$2 candidate remainder escaped
      local LC_ALL=C
      local -i caller_posix_cd=$3 low=1 high=$#_nbsp_as_dirs middle first last
      [[ -n $root && -n $prefix ]] || return 1

      if [[ $_nbsp_as_scan_root != $root || $_nbsp_as_scan_pwd != $PWD ||
          $_nbsp_as_scan_state != ready ]]; then
        _nbsp_as_schedule_scan "$root"
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
      [[ ${_nbsp_as_dirs[low]} == "$prefix"* ]] || return 1
      first=$low
      last=$first
      while (( last < $#_nbsp_as_dirs )) &&
          [[ ${_nbsp_as_dirs[last + 1]} == "$prefix"* ]]; do
        (( ++last ))
      done
      if (( first == last )); then
        candidate=${_nbsp_as_dirs[first]}
      else
        _nbsp_as_rank_directory "$root" "$prefix" "$first" "$last" \
          "$caller_posix_cd" || return 1
        candidate=$REPLY
      fi
      remainder=${candidate[$(( $#prefix + 1 )),-1]}
      escaped=${(q)remainder}
      REPLY="$BUFFER$escaped/"
      return 0
    }

    _nbsp_as_pre_redraw() {
      local -i caller_posix_cd=0
      [[ -o posixcd ]] && caller_posix_cd=1
      emulate -L zsh
      setopt EXTENDED_GLOB
      _nbsp_as_clear_display
      [[ -z $POSTDISPLAY ]] || return
      if (( $+functions[_zsh_autosuggest_start] ||
          $+widgets[autosuggest-accept] )); then
        _nbsp_as_disabled=1
        _nbsp_as_cancel_scan
        _nbsp_as_full=
        _nbsp_as_full_kind=
        return
      fi
      (( !_nbsp_as_disabled && $#BUFFER > 0 && $#BUFFER <= 256 &&
          CURSOR == $#BUFFER && !REGION_ACTIVE )) || return
      [[ $BUFFER != *$'\n'* && $BUFFER != [[:space:]]* ]] || return
      (( PENDING == 0 && ${KEYS_QUEUED_COUNT:-0} == 0 )) || return

      local -a parsed reply
      local -i path_mode=0
      reply=()
      if _nbsp_as_parse_cd "$BUFFER" "$caller_posix_cd"; then
        parsed=( "${(@)reply}" )
        path_mode=1
      fi

      if [[ -n $_nbsp_as_full && $_nbsp_as_full == "$BUFFER"* ]]; then
        if [[ $_nbsp_as_full_kind == directory || path_mode -eq 0 ]]; then
          _nbsp_as_offer "$_nbsp_as_full" "$_nbsp_as_full_kind"
          return
        fi
      fi
      _nbsp_as_full=
      _nbsp_as_full_kind=

      if (( path_mode )); then
        if _nbsp_as_directory_full "${parsed[1]}" "${parsed[2]}" \
            "$caller_posix_cd"; then
          _nbsp_as_offer "$REPLY" directory
        fi
        return
      fi

      local pattern="${(b)BUFFER}*" suggestion
      suggestion=${_nbsp_as_history[(r)$pattern]}
      _nbsp_as_offer "$suggestion" history
    }

    _nbsp_as_line_finish() {
      emulate -L zsh
      _nbsp_as_clear_display
      _nbsp_as_cancel_scan
      _nbsp_as_full=
      _nbsp_as_full_kind=
    }

    _nbsp_as_precmd() {
      emulate -L zsh
      local latest=${history[$((HISTCMD - 1))]-}
      if (( $+functions[_zsh_autosuggest_start] ||
          $+widgets[autosuggest-accept] )); then
        _nbsp_as_disabled=1
        _nbsp_as_invalidate_dirs
        if (( !_nbsp_as_conflict_warned )); then
          print -ru2 -- 'nbsp: --autosuggest disabled because another autosuggestion plugin is active; use only one engine or remove --autosuggest'
          _nbsp_as_conflict_warned=1
        fi
        return
      fi
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
        _nbsp_as_full_kind=
        zle -R
      elif [[ $WIDGET == _nbsp-as-v ]]; then
        zle .vi-forward-char
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
        _nbsp_as_full_kind=
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
    zle -N _nbsp-as-v _nbsp_as_accept
    zle -N nbsp-autosuggest-toggle _nbsp_as_toggle

    for _nbsp_as_keymap _nbsp_as_fallback _nbsp_as_accept_widget in \
        emacs forward-char nbsp-autosuggest-accept \
        viins vi-forward-char _nbsp-as-v; do
      for _nbsp_as_right_key in "${terminfo[kcuf1]-}" $'\e[C' $'\eOC'; do
        if [[ $widgets[$_nbsp_as_fallback] == builtin && -n $_nbsp_as_right_key &&
            $(bindkey -M "$_nbsp_as_keymap" "$_nbsp_as_right_key" 2>/dev/null) == *" $_nbsp_as_fallback" ]]; then
          bindkey -M "$_nbsp_as_keymap" "$_nbsp_as_right_key" "$_nbsp_as_accept_widget"
        fi
      done
    done
    unset _nbsp_as_accept_widget _nbsp_as_fallback _nbsp_as_keymap _nbsp_as_right_key
  fi
fi
