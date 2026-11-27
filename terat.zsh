
typeset -g TERAT_MODE=0
typeset -g TERAT_SYMBOL=${TERAT_SYMBOL:-🟅}
typeset -g TERAT_GLYPH=${TERAT_GLYPH:-❯}

_terat_env=${${(%):-%x}:A:h}/.env
if [[ -r $_terat_env ]]; then
	while IFS='=' read -r _terat_k _terat_v; do
		case $_terat_k in
		TERAT_OTLP | TERAT_OTLP_KEY) ;;
		*) continue ;;
		esac
		_terat_v=${_terat_v%$'\r'}
		_terat_v=${_terat_v#[\"\']}
		_terat_v=${_terat_v%[\"\']}
		[[ -n $_terat_v ]] || continue
		export "$_terat_k=$_terat_v"
	done <"$_terat_env"
	unset _terat_k _terat_v
fi
unset _terat_env

typeset -g _terat_ask_bin=${_terat_ask_bin:-${${(%):-%x}:A:h}/terat}
[[ -x $_terat_ask_bin ]] || _terat_ask_bin=terat

typeset -g TERAT_THREAD=${TERAT_THREAD:-$HOME/.terat/thread.$$}
export TERAT_THREAD
mkdir -p "${TERAT_THREAD:h}" 2>/dev/null
find "${TERAT_THREAD:h}" -name 'thread.[0-9]*' -mtime +1 -delete 2>/dev/null


_terat_cmd() {
	_terat_off=''
	[[ -n $TERAT_RAW && ! -e $TERAT_RAW ]] && _terat_raw
	_terat_off=$(_terat_bytes)
	[[ $1 == terat* || $1 == _terat* ]] && return
	print -r -- "cmd: $1" >>"$TERAT_THREAD"
	_terat_pending=1
	_terat_last=$1
	if _terat_tui "$1"; then
		_terat_off=''
		_terat_pending=0
		return 0
	fi
	_terat_capture_on
}

_terat_tui() {
	local -a words=(${(z)1})
	local c=${words[1]:t} # basename, so /usr/bin/vim is still vim
	[[ $c == [a-z]* ]] || return 1
	local -a tuis=(
		pi vim vi nvim view less more most man top htop btop bt nano emacs
		fzf tmux screen zellij ssh mosh tig lazygit k9s watch dialog dialog1
		ncdu powertop glances irssi weechat mutt neomutt ranger nnn lf broot
	)
	(( $tuis[(Ie)$c] ))
}

_terat_pty() {
	setopt localoptions
	[[ -n ${commands[script]-} ]] || return 1
	local slv=$TERAT_RAW.slv pidf=$TERAT_RAW.pid
	rm -f "$slv" "$pidf"
	local body="echo \$PPID >$pidf; tty >$slv; stty -echo; exec sleep 2147483647"
	local -a cmd=(script -q /dev/null /bin/sh -c "$body")
	local i
	for i in 1 2; do
		{ "${cmd[@]}" </dev/null 2>/dev/null } | tee -a "$TERAT_RAW" >&$_terat_out_fd &!
		local job=$!
		for i in {1..50}; do [[ -s $slv && -s $pidf ]] && break; sleep 0.02; done
		[[ -s $slv && -s $pidf ]] && break
		kill $job 2>/dev/null # the other flavour of `script`
		cmd=(script -q -c "$body" /dev/null)
	done
	if [[ -s $slv && -s $pidf ]] && exec {_terat_tee_fd}<>"$(<$slv)"; then
		_terat_relay=$(<$pidf)
		_terat_slv=$(<$slv)
		_terat_size=''
		_terat_resize
		return 0
	fi
	[[ -s $pidf ]] && _terat_relay=$(<$pidf) # started anyway: still reap it
	kill ${_terat_relay:-$job} 2>/dev/null
	_terat_relay=0
	rm -f "$slv" "$pidf"
	return 1
}

_terat_resize() {
	local s=$COLUMNS/$LINES
	[[ $s == $_terat_size || -z $_terat_slv ]] && return 0
	stty -f "$_terat_slv" rows $LINES cols $COLUMNS 2>/dev/null
	_terat_size=$s
}

_terat_raw() {
	TERAT_RAW=${TERAT_RAW-${TMPDIR:-/tmp}/terat.$$.raw}
	[[ -n $TERAT_RAW ]] || return 0
	export TERAT_RAW
	if (( _terat_tee_fd )); then
		[[ -e $TERAT_RAW ]] && return 0
		_terat_shutdown
	fi
	: >"$TERAT_RAW"
	exec {_terat_out_fd}>&1 {_terat_err_fd}>&2 # the real tty, kept aside
	_terat_pty || exec {_terat_tee_fd}>> >(tee -a "$TERAT_RAW")
}

_terat_capture_on() {
	(( _terat_tee_fd )) || return 0
	_terat_resize
	exec 1>&$_terat_tee_fd 2>&$_terat_tee_fd
}
_terat_capture_off() { (( _terat_out_fd )) && exec 1>&$_terat_out_fd 2>&$_terat_err_fd }

_terat_bytes() {
	[[ -n $TERAT_RAW && -e $TERAT_RAW ]] && wc -c <"$TERAT_RAW" 2>/dev/null | tr -d ' '
}

_terat_rc() {
	local rc=$?
	_terat_capture_off # the tty first: the prompt is drawn straight after this
	(( _terat_pending && rc )) && print -r -- "exit: $rc" >>"$TERAT_THREAD"
	(( _terat_pending )) && _terat_grab
	_terat_pending=0
}

_terat_strip() {
	setopt localoptions extendedglob
	REPLY=${1//$'\e'\[[0-9;?]#[a-zA-Z]/}
	REPLY=${REPLY//$'\e'\][^$'\a']#$'\a'/}
	REPLY=${REPLY//$'\x04'$'\b'$'\b'/}
	REPLY=${REPLY//$'\r'/}
}

_terat_grab() {
	[[ -s $TERAT_RAW && -n $_terat_off ]] || return 0
	local now=$(_terat_bytes)
	(( now > _terat_off )) || return 0
	local out=$(
		tail -c +$((_terat_off + 1)) "$TERAT_RAW" 2>/dev/null |
			grep -avxF -- "$_terat_last" | sed '/^[[:space:]]*$/d'
	)
	_terat_strip "$out"
	out=$REPLY
	[[ -n $out ]] || return 0
	local cap=${TERAT_OUT:-40} n=$(print -r -- "$out" | wc -l | tr -d ' ')
	print -r -- "out:" >>"$TERAT_THREAD"
	(( n > cap )) && print -r -- "  (last $cap of $n lines)" >>"$TERAT_THREAD"
	print -r -- "$out" | tail -n "$cap" | sed 's/^/  /' >>"$TERAT_THREAD"
}
typeset -g _terat_pending=0 _terat_off='' _terat_last=''
typeset -g _terat_out_fd=${_terat_out_fd:-0} _terat_err_fd=${_terat_err_fd:-0} _terat_tee_fd=${_terat_tee_fd:-0}
typeset -g _terat_relay=${_terat_relay:-0} _terat_slv=${_terat_slv:-} _terat_size=${_terat_size:-}


if (( ! ${+_terat_wrapped} )); then
	typeset -g _terat_wrapped=1
	if [[ -n ${commands[starship]-} && $PROMPT == *${commands[starship]}* ]]; then
		typeset -g _terat_bin=${commands[starship]}
		PROMPT=${PROMPT//${_terat_bin}/_terat_render}
		_terat_render() {
			local p
			p=$("$_terat_bin" "$@" 2>/dev/null) || p='%~ '
			(( TERAT_MODE )) && p=${p//$TERAT_GLYPH/$TERAT_SYMBOL}
			print -rn -- "$p"
		}
		_terat_prompt_text() { _terat_render prompt --terminal-width=${COLUMNS:-80} }
		_terat_glyph() { : }
	else
		typeset -g _terat_plain=$PROMPT
		_terat_prompt_text() { print -rnP -- "$PROMPT" }
		_terat_glyph() {
			PROMPT=$_terat_plain
			(( TERAT_MODE )) || return 0
			if [[ $PROMPT == *$TERAT_GLYPH* ]]; then
				PROMPT=${PROMPT//$TERAT_GLYPH/$TERAT_SYMBOL}
			else
				PROMPT="$TERAT_SYMBOL "
			fi
		}
	fi
fi

_terat_plugins() {
	if (( TERAT_MODE )); then
		_terat_hl=${(j: :)ZSH_HIGHLIGHT_HIGHLIGHTERS-}
		_terat_as=${(j: :)ZSH_AUTOSUGGEST_STRATEGY-}
		ZSH_HIGHLIGHT_HIGHLIGHTERS=()
		ZSH_AUTOSUGGEST_STRATEGY=()
		POSTDISPLAY=
		region_highlight=()
		unsetopt histexpand
	else
		[[ -n $_terat_hl ]] && ZSH_HIGHLIGHT_HIGHLIGHTERS=(${=_terat_hl})
		[[ -n $_terat_as ]] && ZSH_AUTOSUGGEST_STRATEGY=(${=_terat_as})
		(( _terat_expand )) && setopt histexpand
	fi
}
typeset -g _terat_q=() _terat_busy=0 _terat_fd=0
typeset -g _terat_hl _terat_as
typeset -g _terat_expand=$([[ -o histexpand ]] && print 1)

_terat_apply() {
	_terat_glyph
	_terat_plugins
}

_terat_key() {
	TERAT_MODE=$(( ! TERAT_MODE ))
	_terat_apply
	zle reset-prompt
}

_terat_trace() {
	case ${TERAT_TRACE:-} in
	1) TERAT_TRACE=; print -r -- 'trace: off' ;;
	*) TERAT_TRACE=1; print -r -- 'trace: on' ;;
	esac
	export TERAT_TRACE
	zle reset-prompt
}
zle -N _terat_key

_terat_newline() {
	(( TERAT_MODE )) && LBUFFER+=$'\n' || zle .accept-line
}
zle -N _terat_newline
bindkey '\e[13;2u' _terat_newline    # kitty: shift+enter
bindkey '\e[27;2;13~' _terat_newline # xterm modifyOtherKeys: shift+enter
bindkey '\e\r' _terat_newline        # option/alt+enter
bindkey '^Xi' _terat_key             # Ctrl+X i
bindkey '^[i' _terat_key             # Option+i, if the terminal sends meta
bindkey '\e[105;6u' _terat_key        # ctrl+shift+i (kitty keyboard protocol)
zle -N _terat_trace
bindkey '^Xt' _terat_trace            # Ctrl+X t: trace this session

_terat_line() {
	zle -I
	local ptxt=$(_terat_prompt_text)
	print -n "\033[1A\r\033[K"
	print -rnP -- "${ptxt#$'\n'}"
	print -r -- "$1"
}


_terat_accept() {
	emulate -L zsh
	local q=$BUFFER

	if [[ ${q//[[:space:]]/} == terat ]]; then
		unsetopt localoptions # the mode's option changes must outlive the widget
		TERAT_MODE=$(( ! TERAT_MODE ))
		_terat_apply
		BUFFER=
		zle reset-prompt
		return
	fi

	if (( ! TERAT_MODE )) && [[ $q == '@'* ]]; then
		unsetopt localoptions
		TERAT_MODE=1
		_terat_apply
		BUFFER=
		if [[ -z ${${q#@}//[[:space:]]/} ]]; then # just `@`: only switch
			zle reset-prompt
			return
		fi
		_terat_words "$q"
		if _terat_named "$_terat_out[1]"; then # keep the @word, it is a path
			_terat_ask "$q"
		else
			_terat_ask "${${q#@}# }"
		fi
		return
	fi

	if (( ! TERAT_MODE )); then
		zle .accept-line
		return
	fi

	if [[ $q == '@'* && -z ${${q#@}//[[:space:]]/} ]]; then
		BUFFER=
		zle reset-prompt
		return
	fi
	BUFFER=
	if [[ -z ${q//[[:space:]]/} ]]; then
		unsetopt localoptions
		TERAT_MODE=0 # empty line leaves the mode
		_terat_apply
		zle .accept-line
		return
	fi

	if [[ $q == '!'* ]]; then
		local cmd=${q#!}
		if [[ -n ${cmd//[[:space:]]/} ]]; then
			print -s -- "$cmd" # keep it in history
			_terat_line "$q"
			print -r -- "cmd: $cmd" >>"$TERAT_THREAD"
			local out=$TERAT_THREAD.out
			: >"$out"
			if _terat_tui "$cmd"; then
				local tio=$(stty -g </dev/tty 2>/dev/null)
				eval -- "$cmd"
				local rc=$?
				[ -n "$tio" ] && stty "$tio" </dev/tty 2>/dev/null
				rm -f "$out"
				_terat_pending=0 _terat_off=''
				_terat_apply # the prompt is drawn by us now, not by zle
				zle reset-prompt 2>/dev/null
				return
			fi
			local off=$(_terat_bytes)
			_terat_capture_on
			eval -- "$cmd"
			local rc=$?
			_terat_capture_off
			off=${off:-0}
			local i prev=-1 now
			for i in {1..40}; do
				now=$(_terat_bytes)
				[[ $now == $prev ]] && break
				prev=$now
				sleep 0.02
			done
			if [[ -n $TERAT_RAW && -s $TERAT_RAW && $now -gt $off ]]; then
				tail -c +$((off + 1)) "$TERAT_RAW" >"$out" 2>/dev/null
				_terat_strip "$(<$out)"
				print -r -- "$REPLY" >"$out"
			fi
			if [[ -s $out ]]; then
				local cap=${TERAT_OUT:-40} n=$(wc -l <"$out" | tr -d ' ')
				(( n > cap )) && print -r -- "out: (last $cap of $n lines)" \
					>>"$TERAT_THREAD" || print -r -- "out:" >>"$TERAT_THREAD"
				tail -n "$cap" "$out" | sed 's/^/  /' >>"$TERAT_THREAD"
			fi
			rm -f "$out"
			(( rc )) && print -r -- "exit: $rc" >>"$TERAT_THREAD"
			_terat_pending=0 _terat_off=''
		else
			zle reset-prompt
		fi
		return
	fi

	_terat_ask "$q"
}


_terat_words() {
	local -a words parts
	local w i n
	_terat_out=()
	words=( ${(Q)${(z)1}} )
	n=$#words
	i=1
	while (( i <= n )); do
		w=$words[i]
		(( i++ ))
		if [[ $w == [@#]?* ]]; then
			parts=( $w )
			while (( i <= n )) && ! _terat_named "${(j: :)parts}"; do
				parts+=( $words[i] )
				(( i++ ))
			done
			if (( $#parts > 1 )) && ! _terat_named "${(j: :)parts}"; then
				(( i -= $#parts - 1 )) # no such path: give the words back
				parts=( $w )
			fi
			w=${(j: :)parts}
		fi
		_terat_out+=( $w )
	done
}

_terat_named() {
	[[ $1 == [@#]?* ]] || return 1
	local p=${1#[@#]}
	case $p in "~") p=$HOME ;; "~"/*) p=$HOME${p#\~} ;; esac
	[[ -e $p ]]
}

_terat_answer() {
	local out=$(cat <&$_terat_fd 2>/dev/null)
	zle -F $_terat_fd
	exec {_terat_fd}<&-
	_terat_fd=0
	_terat_busy=0
	zle -I
	# The prompt zle drew when the widget returned is already on the screen:
	# step onto it, erase it and print the answer there. Redrawing instead
	# leaves that glyph stranded above the answer, looking like a prompt that
	# was never asked.
	# The prompt zle has just drawn may be taller than one line: starship begins
	# its output with a newline, so it takes two. Stepping up once would land on
	# its blank half and leave a gap between the question and the answer.
	local _p=$(_terat_prompt_text) _up=1 _esc=''
	while [[ $_p == $'\n'* ]]; do
		_up=$(( _up + 1 ))
		_p=${_p#$'\n'}
	done
	while (( _up-- )); do _esc+=$'\033[1A'; done
	printf '%s\r\033[K%s\n' "$_esc" "$out"
	_terat_pump
}

# The run is watched by zle, not waited on, so the line stays typable while it
# is out and the answer is printed the moment it lands.
_terat_run() {
	_terat_words "$1"
	_terat_busy=1
	exec {_terat_fd}< <(TERAT_TTY=1 command ${_terat_ask_bin:-terat} -- "${_terat_out[@]}" 2>&1 </dev/null)
	zle -F $_terat_fd _terat_answer
}

_terat_pump() {
	(( $#_terat_q )) || return 0
	local q=$_terat_q[1]
	_terat_q=( "${(@)_terat_q[2,-1]}" )
	_terat_run "$q"
}

_terat_ask() {
	_terat_line "$1"
	if (( _terat_busy )); then
		_terat_q+=( "$1" )
		print -r -- "  queued ($#_terat_q)"
		return 0
	fi
	_terat_run "$1"
	return 0
}

zle -N accept-line _terat_accept

autoload -Uz add-zsh-hook
add-zsh-hook preexec _terat_cmd
precmd_functions=(_terat_rc $precmd_functions)
[[ -o interactive ]] && _terat_raw


_terat_shutdown() {
	(( _terat_tee_fd )) && exec {_terat_tee_fd}>&- 2>/dev/null
	_terat_tee_fd=0
	(( _terat_relay )) && kill $_terat_relay 2>/dev/null
	_terat_relay=0
	_terat_slv=''
}

_terat_owner=${_terat_owner:-$$}
_terat_clean() {
	(( $$ == _terat_owner )) || return 0
	_terat_shutdown
	[[ -n $TERAT_RAW ]] && rm -f "$TERAT_RAW" "$TERAT_RAW.slv" "$TERAT_RAW.pid"
}
add-zsh-hook zshexit _terat_clean

TRAPINT() {
	# An interrupt drops what was waiting, or the queue keeps running after the
	# user has said stop.
	_terat_q=()
	_terat_busy=0
	(( TERAT_MODE )) && { TERAT_MODE=0; _terat_apply }
	return 130
}
