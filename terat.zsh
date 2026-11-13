# terat.zsh - ask mode for zsh.
#
# The prompt is never redrawn or mimicked: it is still produced by starship (or
# by whatever PROMPT holds), and one character is substituted on the way out.
# Typing a line sends it to pi as a question.

typeset -g TERAT_MODE=0
typeset -g TERAT_SYMBOL=${TERAT_SYMBOL:-🟅}
typeset -g TERAT_GLYPH=${TERAT_GLYPH:-❯}

# Tracing settings live in a dotenv beside this file rather than in ~/.zshrc, so
# the key sits in one place with one file to protect and one to gitignore.
#
# Read as KEY=VALUE, not sourced. Sourcing would let a stray line in that file
# run commands and change unrelated variables in every shell; this file exists to
# hold a secret, so the least it can do is the least it can do. Only the two
# names terat knows are read, and only if not already set in the environment.
_terat_env=${${(%):-%x}:A:h}/.env
if [[ -r $_terat_env ]]; then
	while IFS='=' read -r _terat_k _terat_v; do
		case $_terat_k in
		TERAT_OTLP | TERAT_OTLP_KEY) ;;
		*) continue ;;
		esac
		# Strip surrounding quotes and a trailing CR, so a file edited on
		# Windows or hand-quoted still yields a usable value.
		_terat_v=${_terat_v%$'\r'}
		_terat_v=${_terat_v#[\"\']}
		_terat_v=${_terat_v%[\"\']}
		[[ -n $_terat_v ]] || continue
		export "$_terat_k=$_terat_v"
	done <"$_terat_env"
	unset _terat_k _terat_v
fi
unset _terat_env

# If the key is absent, or the file is not there, nothing below asks for a trace:
# tracing is off and the prompt is unaffected, which is the documented default.

# Where `tert` is: next to this file, so `source ~/Projects/terat/terat.zsh` is
# the whole install and tert never has to be on PATH.
typeset -g _terat_tert=${_terat_tert:-${${(%):-%x}:A:h}/tert}
[[ -x $_terat_tert ]] || _terat_tert=tert

# --- the transcript --------------------------------------------------------
# One thread per shell, keyed by pid: two tabs in the same folder must not share
# a conversation, and tmux reuses tty numbers so the tty cannot identify one.
# Nothing is copied between threads — a file that other shells also wrote to is
# what mixed two terminals into one conversation in the first place.
typeset -g TERAT_THREAD=${TERAT_THREAD:-$HOME/.terat/thread.$$}
export TERAT_THREAD
mkdir -p "${TERAT_THREAD:h}" 2>/dev/null
find "${TERAT_THREAD:h}" -name 'thread.[0-9]*' -mtime +1 -delete 2>/dev/null

# Commands run here belong to the transcript, so a question can refer to them.
_terat_cmd() {
	# Where this command's output starts. Without a capture file there is
	# nothing to measure - and an empty name is not an empty file, it is an
	# error, so check it before measuring.
	_terat_off=''
	# The capture file can vanish under a running shell: a /tmp cleaner takes
	# it, or the same name is removed by hand. The relay is then still writing
	# to a file that no longer has a name, so nothing it copies can ever be
	# read again. Restart it instead of failing on every single command.
	[[ -n $TERAT_RAW && ! -e $TERAT_RAW ]] && _terat_raw
	# Only measure a file that is there: `wc -c <missing` fails in the shell
	# itself, before wc runs, so 2>/dev/null on wc cannot hide the message.
	[[ -e $TERAT_RAW ]] && _terat_off=$(wc -c <"$TERAT_RAW" 2>/dev/null | tr -d ' ')
	[[ $1 == tert* || $1 == _terat* ]] && return
	print -r -- "cmd: $1" >>"$TERAT_THREAD"
	_terat_pending=1
	_terat_last=$1             # the line the shell echoes back
	# Interactive programs keep the terminal: no swap, so they see a real tty.
	# Nothing is copied for them, and precmd must not try to read one either.
	if _terat_tui "$1"; then
		_terat_off=''
		_terat_pending=0
		return 0
	fi
	_terat_capture_on          # from here until precmd, output is copied
}

# Full-screen programs draw with cursor movement and need a tty to write to;
# given a pipe they either refuse to start (`pi`) or quietly fall back (`vim`).
# A pipe and a tty cannot be one fd, so these run straight to the terminal and
# are deliberately not copied - their transcript line is the command itself,
# which is the part a later question can usefully refer to.
_terat_tui() {
	local -a words=(${(z)1})
	local c=${words[1]:t}   # basename, so /usr/bin/vim is still vim
	[[ $c == [a-z]* ]] || return 1
	local -a tuis=(
		pi vim vi nvim view less more most man top htop btop bt nano emacs
		fzf tmux screen zellij ssh mosh tig lazygit k9s watch dialog dialog1
		ncdu powertop glances irssi weechat mutt neomutt ranger nnn lf broot
	)
	(( $tuis[(Ie)$c] ))
}

# A shell cannot read what a command printed, so the copy comes from the shell's
# own output. The obvious way - fd 1 on a pipe - is wrong: a pipe is not a
# terminal, so every program that asks isatty(1) behaves differently. `ls`
# drops colour *and* columns, `git` stops colouring, `test -t 1` turns false,
# and no environment variable brings it back (BSD ls has no CLICOLOR_FORCE).
#
# So the copy is taken from a pty instead: the command writes to the slave of a
# pty whose master is copied to the screen and to the log. Every isatty check
# still says yes, and nothing about the output changes.
#
# Redirecting must also not *stay* on: with fd 1 on a pipe zsh block-buffers the
# line editor's own writes and keystrokes stop appearing until Return. So the
# swap happens only around a command:
#
#   preexec -> fd 1/2 become the pty   (the command's output is copied)
#   precmd  -> fd 1/2 become the tty   (the prompt and typing are live)
_terat_pty() {
	setopt localoptions
	local slv=$TERAT_RAW.slv pidf=$TERAT_RAW.pid
	rm -f "$slv" "$pidf"
	# `script` owns the pty: it ships with macOS, util-linux and busybox. Its
	# stdin must not be our terminal, or `script` calls tcsetattr on it and a
	# start from the background stops it with SIGTTOU. Echo is off or every
	# line is copied twice. The child must only *hold* the pty open, never read
	# from it: a reader on the slave makes macOS refuse the shell's own open
	# with EPERM. It reports $PPID - the pid of `script` itself - which is the
	# one worth killing; the pid of a pipeline is its last element (tee).
	local body="echo \$PPID >$pidf; tty >$slv; stty -echo; exec sleep 2147483647"
	local -a cmd=(script -q /dev/null /bin/sh -c "$body")
	local i
	for i in 1 2; do
		{ "${cmd[@]}" </dev/null 2>/dev/null } | tee -a "$TERAT_RAW" >&$_terat_out_fd &!
		local job=$!
		for i in {1..50}; do [[ -s $slv && -s $pidf ]] && break; sleep 0.02; done
		[[ -s $slv && -s $pidf ]] && break
		kill $job 2>/dev/null            # wrong flavour of `script`: try GNU
		cmd=(script -q -c "$body" /dev/null)
	done
	if [[ -s $slv && -s $pidf ]] && exec {_terat_tee_fd}<>"$(<$slv)"; then
		_terat_relay=$(<$pidf)
		_terat_slv=$(<$slv)
		_terat_size=''
		_terat_resize
		return 0
	fi
	_terat_relay=$(<$pidf 2>/dev/null)   # the child started: still reap it
	kill ${_terat_relay:-$job} 2>/dev/null
	_terat_relay=0
	rm -f "$slv" "$pidf"
	return 1
}

# The pty has its own window size; for `ls` to wrap where the terminal wraps it
# must match. Only call stty when the size actually changed - it is a process.
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
	# Sourcing this file again (a common reflex after editing a .zshrc) must not
	# start a second relay and strand the first one. A missing capture file is
	# the other case: what is running now writes to a deleted file, so it has
	# to be replaced rather than reused.
	if (( _terat_tee_fd )); then
		[[ -e $TERAT_RAW ]] && return 0
		_terat_shutdown
	fi
	: >"$TERAT_RAW"
	# Ask the shell for fds instead of assuming numbers: fd 3 is already taken
	# by things a .zshrc may load, and a clash closes the tee silently.
	exec {_terat_out_fd}>&1 {_terat_err_fd}>&2 # the real tty, kept aside
	# No pty to be had (no `script`, or no /dev/ptmx): a pipe still captures,
	# it just costs the styling. Better a plain copy than no copy.
	_terat_pty || exec {_terat_tee_fd}>> >(tee -a "$TERAT_RAW")
}

# Swap fd 1/2 onto the pty for the duration of a command, and back afterwards.
_terat_capture_on() {
	(( _terat_tee_fd )) || return 0
	_terat_resize
	exec 1>&$_terat_tee_fd 2>&$_terat_tee_fd
}
_terat_capture_off() { (( _terat_out_fd )) && exec 1>&$_terat_out_fd 2>&$_terat_err_fd }

# Failures are worth recording: "did that work?" is the usual next question.
# $? is only intact before other precmd hooks run, hence the prepend below.
_terat_rc() {
	local rc=$?
	_terat_capture_off   # the tty first: the prompt is drawn straight after this
	(( _terat_pending && rc )) && print -r -- "exit: $rc" >>"$TERAT_THREAD"
	(( _terat_pending )) && _terat_grab
	_terat_pending=0
}

# Keep this command's output: everything the shell wrote since preexec, minus
# escapes and the echoed command line, capped so the thread stays small. The
# rewrite is skipped when the line was already recorded by `!` in ask mode.
_terat_grab() {
	[[ -s $TERAT_RAW && -n $_terat_off ]] || return 0
	setopt localoptions extendedglob      # for the `#` in the patterns below
	local now=$(wc -c <"$TERAT_RAW" | tr -d ' ')
	(( now > _terat_off )) || return 0
	local out=$(
		tail -c +$((_terat_off + 1)) "$TERAT_RAW" 2>/dev/null |
			grep -avxF -- "$_terat_last" | sed '/^[[:space:]]*$/d'
	)
	# Strip escapes here, not with sed: BSD sed has no \x1b, so the window
	# titles zsh writes would otherwise land in the transcript.
	out=${out//$'\e'\[[0-9;?]#[a-zA-Z]/}
	out=${out//$'\e'\][^$'\a']#$'\a'/}
	out=${out//$'\x04'$'\b'$'\b'/}   # the bytes `script` writes when it starts
	out=${out//$'\r'/}
	[[ -n $out ]] || return 0
	local cap=${TERAT_OUT:-40} n=$(print -r -- "$out" | wc -l | tr -d ' ')
	print -r -- "out:" >>"$TERAT_THREAD"
	(( n > cap )) && print -r -- "  (last $cap of $n lines)" >>"$TERAT_THREAD"
	print -r -- "$out" | tail -n "$cap" | sed 's/^/  /' >>"$TERAT_THREAD"
}
typeset -g _terat_pending=0 _terat_off='' _terat_last=''
# `:-` here, not `=0`: sourcing this file again must not zero the fds that are
# already carrying the capture, or the guard in _terat_raw would miss.
typeset -g _terat_out_fd=${_terat_out_fd:-0} _terat_err_fd=${_terat_err_fd:-0} _terat_tee_fd=${_terat_tee_fd:-0}
typeset -g _terat_relay=${_terat_relay:-0} _terat_slv=${_terat_slv:-} _terat_size=${_terat_size:-}

# --- how the prompt is produced --------------------------------------------
# starship's PROMPT is a command substitution that zsh runs on every draw, so
# wrap the binary and swap the glyph inside it. A plain PROMPT is edited in the
# string instead. Neither branch eval's anything: with a broken PATH (no
# starship, no fzf) prompt text must never be executed as a command.
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
	_terat_prompt_text() { print -rn -- "$PROMPT" }
	_terat_glyph() {
		PROMPT=$_terat_plain
		(( TERAT_MODE )) && PROMPT=${PROMPT//$TERAT_GLYPH/$TERAT_SYMBOL}
	}
fi

# --- the line editor -------------------------------------------------------
# Command colouring and history suggestions are wrong here: the line is a
# question, not a command. Emptying both settings turns them off; the saved
# values turn them back on when the mode ends.
_terat_plugins() {
	if (( TERAT_MODE )); then
		_terat_hl=${(j: :)ZSH_HIGHLIGHT_HIGHLIGHTERS-}
		_terat_as=${(j: :)ZSH_AUTOSUGGEST_STRATEGY-}
		ZSH_HIGHLIGHT_HIGHLIGHTERS=()
		ZSH_AUTOSUGGEST_STRATEGY=()
		POSTDISPLAY=
		region_highlight=()
		# Without this, `!cmd` is rewritten by history expansion before the
		# widget sees it, turning the shell escape into an old command line.
		unsetopt histexpand
	else
		[[ -n $_terat_hl ]] && ZSH_HIGHLIGHT_HIGHLIGHTERS=(${=_terat_hl})
		[[ -n $_terat_as ]] && ZSH_AUTOSUGGEST_STRATEGY=(${=_terat_as})
		(( _terat_expand )) && setopt histexpand
	fi
}
# Remembered at load: inside the widget emulate -L would report zsh's default.
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
zle -N _terat_key

# Shift+Enter starts a new line, so a question can span several lines. It costs
# two bindings because terminals disagree on the sequence: kitty protocol and
# xterm modifyOtherKeys. Outside the mode it submits like Enter, so a terminal
# that sends the sequence is never left with a dead key.
_terat_newline() {
	(( TERAT_MODE )) && LBUFFER+=$'\n' || zle .accept-line
}
zle -N _terat_newline
bindkey '\e[13;2u' _terat_newline     # kitty: shift+enter
bindkey '\e[27;2;13~' _terat_newline  # xterm modifyOtherKeys: shift+enter
bindkey '\e\r' _terat_newline         # option/alt+enter, for terminals that
                                       # send neither protocol
bindkey '^Xi' _terat_key  # Ctrl+X i
bindkey '^[i' _terat_key  # Option+i, if the terminal sends meta

# Put the prompt and a line of text where the prompt currently is. zle has just
# cleared the typed text and opened a new line, so step back onto it first.
_terat_line() {
	zle -I
	local ptxt=$(_terat_prompt_text)
	print -n "\033[1A\r\033[K"
	print -rnP -- "${ptxt#$'\n'}"
	print -r -- "$1"
}

# Enter in ask mode: print the question, answer below it, prompt again.
_terat_accept() {
	emulate -L zsh
	local q=$BUFFER

	# `tert` alone flips the mode in place: the line you typed is erased and the
	# same prompt comes back with the other glyph. Nothing is printed.
	if [[ ${q//[[:space:]]/} == tert ]]; then
		unsetopt localoptions # the mode's option changes must outlive the widget
		TERAT_MODE=$(( ! TERAT_MODE ))
		_terat_apply
		BUFFER=
		zle reset-prompt
		return
	fi

	# `@` opens the mode from a normal prompt, so no key combination is needed.
	# `@what is this` asks that question immediately and stays in the mode, and
	# `@shot.png what is this` is the same as typing it inside the mode: the
	# first word stays an attachment when it names a real file or folder.
	if (( ! TERAT_MODE )) && [[ $q == '@'* ]]; then
		unsetopt localoptions # the mode's option changes must outlive the widget
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
	# A bare `@` is how the mode is entered from a normal prompt; inside the
	# mode it means nothing, so it must not be sent as a question. It has to
	# test for the `@` itself: an empty line also has nothing after it, and an
	# empty line is how the mode is left.
	if [[ $q == '@'* && -z ${${q#@}//[[:space:]]/} ]]; then
		BUFFER=
		zle reset-prompt
		return
	fi
	BUFFER=
	if [[ -z ${q//[[:space:]]/} ]]; then
		unsetopt localoptions
		TERAT_MODE=0          # empty line leaves the mode
		_terat_apply
		zle .accept-line
		return
	fi
	# `!cmd` runs a shell command and stays in the mode. It runs in this shell,
	# so cd, exports and aliases all behave as usual.
	if [[ $q == '!'* ]]; then
		local cmd=${q#!}
		if [[ -n ${cmd//[[:space:]]/} ]]; then
			print -s -- "$cmd"                        # keep it in history
			_terat_line "$q"
			print -r -- "cmd: $cmd" >>"$TERAT_THREAD"
			# A shell cannot see what a command printed, so the only way to keep
			# it is to copy it on the way past. This runs inside a widget, where
			# preexec does not fire for `eval`, so point fd 1 at the pty here:
			# the command writes to a terminal and keeps its colour and columns,
			# and the copy is simply the tail of the session log.
			#
			# A full-screen program must be left alone, exactly as it is when run
			# from a normal prompt. Pointed at the relay's pty it draws into a
			# terminal nobody drives, so its keys (ESC, :q) never arrive and it
			# looks like it is printing escape codes instead of responding.
			local out=$TERAT_THREAD.out
			: >"$out"
			if _terat_tui "$cmd"; then
				# Save the terminal before handing it over. A full-screen program
				# puts it in raw mode itself and is supposed to put it back on
				# exit, but run from inside a widget it leaves termios as it found
				# it mid-run: output post-processing and CR/NL translation off.
				# A line then starts where the last one ended, so every answer
				# afterwards comes out as a staircase. Restore it ourselves.
				local tio=$(stty -g </dev/tty 2>/dev/null)
				eval -- "$cmd"
				local rc=$?
				[ -n "$tio" ] && stty "$tio" </dev/tty 2>/dev/null
				rm -f "$out"
				_terat_pending=0 _terat_off=''
				_terat_apply        # the prompt is drawn by us now, not by zle
				zle reset-prompt 2>/dev/null
				return
			fi
			local off=$(wc -c <"$TERAT_RAW" 2>/dev/null | tr -d ' ')
			_terat_capture_on
			eval -- "$cmd"
			local rc=$?
			# precmd does not run inside a widget, so put fd 1 back by hand or
			# the prompt we draw next would be written into the log.
			_terat_capture_off
			off=${off:-0}
			# The relay writes from another process, so the tail arrives a
			# moment later. Wait for the size to settle instead of guessing.
			local i prev=-1 now
			for i in {1..40}; do
				now=$(wc -c <"$TERAT_RAW" 2>/dev/null | tr -d ' ')
				[[ $now == $prev ]] && break
				prev=$now
				sleep 0.02
			done
			if [[ -n $TERAT_RAW && -s $TERAT_RAW && $now -gt $off ]]; then
				tail -c +$((off + 1)) "$TERAT_RAW" >"$out" 2>/dev/null
				setopt localoptions extendedglob
				local body=$(<$out)
				body=${body//$'\e'\[[0-9;?]#[a-zA-Z]/}
				body=${body//$'\e'\][^$'\a']#$'\a'/}
				# `script` writes ^D^H^H once, when it starts.
				body=${body//$'\x04'$'\b'$'\b'/}
				body=${body//$'\r'/}
				print -r -- "$body" >"$out"
			fi
			if [[ -s $out ]]; then
				# Keep only the tail: the thread is what tert sends, and one long
				# command would otherwise push the whole conversation out of it.
				local cap=${TERAT_OUT:-40} n=$(wc -l <"$out" | tr -d ' ')
				(( n > cap )) && print -r -- "out: (last $cap of $n lines)" \
					>>"$TERAT_THREAD" || print -r -- "out:" >>"$TERAT_THREAD"
				tail -n "$cap" "$out" | sed 's/^/  /' >>"$TERAT_THREAD"
			fi
			rm -f "$out"
			(( rc )) && print -r -- "exit: $rc" >>"$TERAT_THREAD"
			# eval fires preexec, so the shell-wide capture saw this run too.
			# Drop the offset and the flag: one record per command, not two.
			_terat_pending=0 _terat_off=''
		else
			zle reset-prompt
		fi
		return
	fi

	_terat_ask "$q"
}

# Print prompt + question, then let tert answer below it. zle redraws the prompt
# by itself when the widget returns, so there is no reset-prompt here: doing
# that too would eat the answer line.
# Turn a line into words, rejoining a path typed without quotes: a word starting
# with @ or # grows across the following words until it names something. Quoted
# paths are already handled by (z), which respects the quotes.
_terat_words() {
	# not named `path`: that is tied to $PATH in zsh and would break command lookup
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

# Does this @word or #word name something on disk? The prefix is stripped first,
# and ~ is expanded, because the shell will not do either for a lone -e test.
_terat_named() {
	[[ $1 == [@#]?* ]] || return 1
	local p=${1#[@#]}
	case $p in "~") p=$HOME ;; "~"/*) p=$HOME${p#\~} ;; esac
	[[ -e $p ]]
}

_terat_ask() {
	_terat_line "$1"
	_terat_words "$1"
	# tert sits next to this file, so sourcing it is enough: no PATH change.
	command ${_terat_tert:-tert} "${_terat_out[@]}"
	local rc=$?
	# Ctrl-C while the answer is still arriving: leave the mode here rather
	# than trusting the trap, which can run after zle has already drawn the
	# prompt and leave the old glyph on screen.
	(( rc == 130 && TERAT_MODE )) && { TERAT_MODE=0; _terat_apply }
	return 0
}

zle -N accept-line _terat_accept

autoload -Uz add-zsh-hook
add-zsh-hook preexec _terat_cmd
precmd_functions=(_terat_rc $precmd_functions)
# Every interactive shell that loads this file copies its output, so there is
# nothing to opt into: open a terminal however you like and normal commands are
# already recorded. Scripts are left alone - they neither ask questions nor
# want their stdout turned into a pipe.
[[ -o interactive ]] && _terat_raw

# The capture file is one per shell; a closed shell takes it with it. A subshell
# runs this hook too, inheriting the parent's TERAT_RAW - deleting on that would
# pull the file out from under the tee that is still writing to it, and every
# later command would look empty. Only the shell that made the file removes it.
# Stop the relay and close our end of it. Used when the shell exits, and when
# the capture file has disappeared and the relay has to be built again.
_terat_shutdown() {
	# Drop our write end first, or the tee keeps waiting on a pipe that no
	# longer has a writer and outlives the shell it was copying.
	(( _terat_tee_fd )) && exec {_terat_tee_fd}>&- 2>/dev/null
	_terat_tee_fd=0
	# The relay is a background job of this shell; it does not die with it.
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
	(( TERAT_MODE )) && { TERAT_MODE=0; _terat_apply } # Ctrl-C leaves the mode
	return 130
}
