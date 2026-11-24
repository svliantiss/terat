# terat.zsh — ask mode for zsh. Source this from ~/.zshrc.
#
# The prompt is not redrawn or mimicked: starship (or whatever PROMPT holds)
# keeps producing it, and one character is swapped on the way out. A typed line
# is a question for `terat` instead of a command.

typeset -g TERAT_MODE=0
typeset -g TERAT_SYMBOL=${TERAT_SYMBOL:-🟅}
typeset -g TERAT_GLYPH=${TERAT_GLYPH:-❯}

# Secrets live in a .env beside this file, read as KEY=VALUE and never sourced:
# a stray line there must not be able to run commands in every shell.
_terat_env=${${(%):-%x}:A:h}/.env
if [[ -r $_terat_env ]]; then
	while IFS='=' read -r _terat_k _terat_v; do
		case $_terat_k in
		TERAT_OTLP | TERAT_OTLP_KEY) ;;
		*) continue ;;
		esac
		# Hand-quoted or CRLF-edited values still have to be usable.
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

# One thread per shell, keyed by pid: two tabs must not share a conversation.
typeset -g TERAT_THREAD=${TERAT_THREAD:-$HOME/.terat/thread.$$}
export TERAT_THREAD
mkdir -p "${TERAT_THREAD:h}" 2>/dev/null
find "${TERAT_THREAD:h}" -name 'thread.[0-9]*' -mtime +1 -delete 2>/dev/null

# --- recording what the shell does ------------------------------------------

# preexec: remember the command, and start copying its output.
_terat_cmd() {
	_terat_off=''
	[[ -n $TERAT_RAW && ! -e $TERAT_RAW ]] && _terat_raw
	_terat_off=$(_terat_bytes)
	[[ $1 == terat* || $1 == _terat* ]] && return
	print -r -- "cmd: $1" >>"$TERAT_THREAD"
	_terat_pending=1
	_terat_last=$1
	# Full-screen programs keep the terminal; nothing is copied for them.
	if _terat_tui "$1"; then
		_terat_off=''
		_terat_pending=0
		return 0
	fi
	_terat_capture_on
}

# Full-screen programs need a real tty to write to and are left alone.
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

# Run `script` on a pty so the copied output keeps its colour and columns: a
# pipe is not a tty and every isatty(1) check would behave differently.
_terat_pty() {
	setopt localoptions
	[[ -n ${commands[script]-} ]] || return 1
	local slv=$TERAT_RAW.slv pidf=$TERAT_RAW.pid
	rm -f "$slv" "$pidf"
	# The child holds the pty open, never reads it, and reports the pid of
	# `script` itself, which is the one worth killing. Echo off or every line
	# is copied twice.
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

# The pty has its own size; `ls` only wraps where the terminal wraps if it
# matches. Called as a process, so only when the size actually changed.
_terat_resize() {
	local s=$COLUMNS/$LINES
	[[ $s == $_terat_size || -z $_terat_slv ]] && return 0
	stty -f "$_terat_slv" rows $LINES cols $COLUMNS 2>/dev/null
	_terat_size=$s
}

_terat_raw() {
	# `-` not `:-`: an empty TERAT_RAW means "do not capture", not "use default"
	TERAT_RAW=${TERAT_RAW-${TMPDIR:-/tmp}/terat.$$.raw}
	[[ -n $TERAT_RAW ]] || return 0
	export TERAT_RAW
	# Sourcing this file again must not strand the relay that is already running.
	if (( _terat_tee_fd )); then
		[[ -e $TERAT_RAW ]] && return 0
		_terat_shutdown
	fi
	: >"$TERAT_RAW"
	# Ask the shell for fds: fd 3 is often already taken by a .zshrc plugin.
	exec {_terat_out_fd}>&1 {_terat_err_fd}>&2 # the real tty, kept aside
	# No pty to be had (no `script`): a pipe still captures, minus the styling.
	_terat_pty || exec {_terat_tee_fd}>> >(tee -a "$TERAT_RAW")
}

# Swap fd 1/2 onto the capture for the duration of a command, and back.
_terat_capture_on() {
	(( _terat_tee_fd )) || return 0
	_terat_resize
	exec 1>&$_terat_tee_fd 2>&$_terat_tee_fd
}
_terat_capture_off() { (( _terat_out_fd )) && exec 1>&$_terat_out_fd 2>&$_terat_err_fd }

# Read with the redirect: `wc -c <missing` fails in the shell itself.
_terat_bytes() {
	[[ -n $TERAT_RAW && -e $TERAT_RAW ]] && wc -c <"$TERAT_RAW" 2>/dev/null | tr -d ' '
}

# precmd: failures are worth recording, and $? is only intact before other
# precmd hooks run.
_terat_rc() {
	local rc=$?
	_terat_capture_off # the tty first: the prompt is drawn straight after this
	(( _terat_pending && rc )) && print -r -- "exit: $rc" >>"$TERAT_THREAD"
	(( _terat_pending )) && _terat_grab
	_terat_pending=0
}

# Drop the terminal's own noise: escapes for colour and window titles, the
# ^D^H^H `script` emits at start, and CR. Not sed: BSD sed has no \x1b.
_terat_strip() {
	setopt localoptions extendedglob
	REPLY=${1//$'\e'\[[0-9;?]#[a-zA-Z]/}
	REPLY=${REPLY//$'\e'\][^$'\a']#$'\a'/}
	REPLY=${REPLY//$'\x04'$'\b'$'\b'/}
	REPLY=${REPLY//$'\r'/}
}

# Keep this command's output, without the echoed command line, capped so the
# thread stays small.
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
# `:-`, not `=0`: sourcing again must not zero fds that are already capturing.
typeset -g _terat_out_fd=${_terat_out_fd:-0} _terat_err_fd=${_terat_err_fd:-0} _terat_tee_fd=${_terat_tee_fd:-0}
typeset -g _terat_relay=${_terat_relay:-0} _terat_slv=${_terat_slv:-} _terat_size=${_terat_size:-}

# --- the prompt -------------------------------------------------------------

# starship's PROMPT is a command substitution zsh runs on every draw, so wrap
# the binary and swap the glyph inside it. A plain PROMPT is edited in the
# string instead. Neither branch eval's anything.
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
		# -P expands the prompt escapes (%~, %m, %#) the way zle would.
		_terat_prompt_text() { print -rnP -- "$PROMPT" }
		_terat_glyph() {
			PROMPT=$_terat_plain
			(( TERAT_MODE )) || return 0
			# The swap needs the glyph to already be there, which a stock
			# `%m%# ` prompt has not; fall back to the symbol alone, or AI mode
			# would look exactly like a normal prompt on a bare VPS.
			if [[ $PROMPT == *$TERAT_GLYPH* ]]; then
				PROMPT=${PROMPT//$TERAT_GLYPH/$TERAT_SYMBOL}
			else
				PROMPT="$TERAT_SYMBOL "
			fi
		}
	fi
fi

# Command colouring and history suggestions are wrong here: the line is a
# question. Turned off on entry, put back on the way out.
_terat_plugins() {
	if (( TERAT_MODE )); then
		_terat_hl=${(j: :)ZSH_HIGHLIGHT_HIGHLIGHTERS-}
		_terat_as=${(j: :)ZSH_AUTOSUGGEST_STRATEGY-}
		ZSH_HIGHLIGHT_HIGHLIGHTERS=()
		ZSH_AUTOSUGGEST_STRATEGY=()
		POSTDISPLAY=
		region_highlight=()
		# Or `!cmd` is rewritten by history expansion before the widget sees it.
		unsetopt histexpand
	else
		[[ -n $_terat_hl ]] && ZSH_HIGHLIGHT_HIGHLIGHTERS=(${=_terat_hl})
		[[ -n $_terat_as ]] && ZSH_AUTOSUGGEST_STRATEGY=(${=_terat_as})
		(( _terat_expand )) && setopt histexpand
	fi
}
# Remembered at load: inside the widget, emulate -L would report zsh's default.
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

# Tracing toggled per session: one shell with one thread of questions is the
# unit worth tracing as one trace.
_terat_trace() {
	case ${TERAT_TRACE:-} in
	1) TERAT_TRACE=; print -r -- 'trace: off' ;;
	*) TERAT_TRACE=1; print -r -- 'trace: on' ;;
	esac
	export TERAT_TRACE
	zle reset-prompt
}
zle -N _terat_key

# Shift+Enter starts a new line, so a question can span several lines. Two
# bindings because terminals disagree on the sequence; outside the mode it
# submits like Enter, so no terminal is left with a dead key.
_terat_newline() {
	(( TERAT_MODE )) && LBUFFER+=$'\n' || zle .accept-line
}
zle -N _terat_newline
bindkey '\e[13;2u' _terat_newline    # kitty: shift+enter
bindkey '\e[27;2;13~' _terat_newline # xterm modifyOtherKeys: shift+enter
bindkey '\e\r' _terat_newline        # option/alt+enter
bindkey '^Xi' _terat_key             # Ctrl+X i
bindkey '^[i' _terat_key             # Option+i, if the terminal sends meta
zle -N _terat_trace
bindkey '^Xt' _terat_trace            # Ctrl+X t: trace this session

# Put the prompt and a line of text where the prompt currently is. zle has
# just cleared the typed text and opened a new line, so step back onto it.
_terat_line() {
	zle -I
	local ptxt=$(_terat_prompt_text)
	print -n "\033[1A\r\033[K"
	print -rnP -- "${ptxt#$'\n'}"
	print -r -- "$1"
}

# --- Enter, in ask mode -----------------------------------------------------

_terat_accept() {
	emulate -L zsh
	local q=$BUFFER

	# `terat` alone flips the mode in place: nothing is printed.
	if [[ ${q//[[:space:]]/} == terat ]]; then
		unsetopt localoptions # the mode's option changes must outlive the widget
		TERAT_MODE=$(( ! TERAT_MODE ))
		_terat_apply
		BUFFER=
		zle reset-prompt
		return
	fi

	# `@` opens the mode from a normal prompt, so no key binding is needed.
	# `@what is this` asks immediately and stays; `@shot.png what is this`
	# keeps the first word as an attachment when it names a real path.
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

	# A bare `@` inside the mode means nothing and must not be sent as a
	# question. An empty line is how the mode is left.
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

	# `!cmd` runs a shell command here and stays in the mode, so cd, exports
	# and aliases behave as usual.
	if [[ $q == '!'* ]]; then
		local cmd=${q#!}
		if [[ -n ${cmd//[[:space:]]/} ]]; then
			print -s -- "$cmd" # keep it in history
			_terat_line "$q"
			print -r -- "cmd: $cmd" >>"$TERAT_THREAD"
			local out=$TERAT_THREAD.out
			: >"$out"
			# A full-screen program must be left alone: pointed at the relay's
			# pty it draws into a terminal nobody drives, and its keys never
			# arrive. Save termios, it does not always put it back.
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
			# preexec does not fire for `eval` inside a widget, so point fd 1
			# at the pty by hand to keep colour and columns.
			local off=$(_terat_bytes)
			_terat_capture_on
			eval -- "$cmd"
			local rc=$?
			_terat_capture_off
			off=${off:-0}
			# The relay writes from another process: wait for the tail to
			# settle instead of guessing.
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
				# Keep only the tail: one long command would otherwise push
				# the whole conversation out of the thread.
				local cap=${TERAT_OUT:-40} n=$(wc -l <"$out" | tr -d ' ')
				(( n > cap )) && print -r -- "out: (last $cap of $n lines)" \
					>>"$TERAT_THREAD" || print -r -- "out:" >>"$TERAT_THREAD"
				tail -n "$cap" "$out" | sed 's/^/  /' >>"$TERAT_THREAD"
			fi
			rm -f "$out"
			(( rc )) && print -r -- "exit: $rc" >>"$TERAT_THREAD"
			# eval fired preexec, so the shell-wide capture saw this too: one
			# record per command, not two.
			_terat_pending=0 _terat_off=''
		else
			zle reset-prompt
		fi
		return
	fi

	_terat_ask "$q"
}

# --- the question -----------------------------------------------------------

# Split a line into words, rejoining a path typed without quotes: a word
# starting with @ or # grows across the following words until it names
# something. Quoted paths are already handled by (z), which respects quotes.
_terat_words() {
	local -a words parts
	local w i n
	_terat_out=()
	# (Q) right after (z), so a ? or * in the question is never globbed
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

# Does this @word or #word name something on disk? The prefix is stripped
# first and ~ is expanded, because a lone -e test does neither.
_terat_named() {
	[[ $1 == [@#]?* ]] || return 1
	local p=${1#[@#]}
	case $p in "~") p=$HOME ;; "~"/*) p=$HOME${p#\~} ;; esac
	[[ -e $p ]]
}

# Print prompt + question, then let terat answer below it. zle redraws the
# prompt itself when the widget returns: a reset-prompt here would eat the
# answer line.
_terat_ask() {
	_terat_line "$1"
	_terat_words "$1"
	# terat sits next to this file, so sourcing it is enough: no PATH change.
	# `--` first: everything after it is the question, so one that begins with
	# an agent name ("claude wrote this") is not taken as `terat claude`.
	command ${_terat_ask_bin:-terat} -- "${_terat_out[@]}"
	local rc=$?
	# Ctrl-C while the answer is still arriving leaves the mode here rather
	# than trusting the trap, which can run after zle has redrawn the prompt.
	(( rc == 130 && TERAT_MODE )) && { TERAT_MODE=0; _terat_apply }
	return 0
}

zle -N accept-line _terat_accept

autoload -Uz add-zsh-hook
add-zsh-hook preexec _terat_cmd
precmd_functions=(_terat_rc $precmd_functions)
# Every interactive shell copies its output, so there is nothing to opt into.
[[ -o interactive ]] && _terat_raw

# --- shutting down ----------------------------------------------------------

_terat_shutdown() {
	# Drop our write end first, or the tee waits on a pipe with no writer.
	(( _terat_tee_fd )) && exec {_terat_tee_fd}>&- 2>/dev/null
	_terat_tee_fd=0
	(( _terat_relay )) && kill $_terat_relay 2>/dev/null
	_terat_relay=0
	_terat_slv=''
}

# A subshell runs this too, inheriting the parent's TERAT_RAW; removing it
# would pull the file out from under a tee that is still writing.
_terat_owner=${_terat_owner:-$$}
_terat_clean() {
	(( $$ == _terat_owner )) || return 0
	_terat_shutdown
	[[ -n $TERAT_RAW ]] && rm -f "$TERAT_RAW" "$TERAT_RAW.slv" "$TERAT_RAW.pid"
}
add-zsh-hook zshexit _terat_clean

TRAPINT() {
	(( TERAT_MODE )) && { TERAT_MODE=0; _terat_apply } # Ctrl-C leaves the mode
	return 130
}
