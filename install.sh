#!/bin/sh
# terat installer.
#   sh -c "$(curl -fsSL https://raw.githubusercontent.com/svliantiss/terat/main/install.sh)"
#   sh install.sh --uninstall
#
# Env: TERAT_BIN (where, default ~/.local/bin)  TERAT_BASE_URL (fetch from)
set -eu

base=${TERAT_BASE_URL:-https://raw.githubusercontent.com/svliantiss/terat/main}
bindir=${TERAT_BIN:-$HOME/.local/bin}
zshrc=${ZDOTDIR:-$HOME}/.zshrc

say() { printf '%s\n' "$*"; }
die() { printf 'terat: %s\n' "$*" >&2; exit 1; }

get() {
	if [ -n "${TERAT_SRC_DIR:-}" ]; then
		cat "$TERAT_SRC_DIR/$2" 2>/dev/null || die "no $2 in $TERAT_SRC_DIR"
	elif command -v curl >/dev/null 2>&1; then
		curl -fsSL "$1/$2" || die "could not download $2"
	elif command -v wget >/dev/null 2>&1; then
		wget -qO- "$1/$2" || die "could not download $2"
	else
		die "needs curl or wget"
	fi
}

# Drop the line that sources ask mode, without disturbing anything else.
# grep -v exits 1 when it prints nothing, which is exactly the success case
# here, so its status cannot be part of an && chain.
drop_rc() {
	[ -f "$zshrc" ] || return 0
	if grep -qF "source $bindir/terat.zsh" "$zshrc"; then
		grep -vF "source $bindir/terat.zsh" "$zshrc" >"$zshrc.terat.tmp" || :
		mv "$zshrc.terat.tmp" "$zshrc"
	fi
}

# A keyboard shortcut has to be given to the shell by the terminal, because a
# legacy terminal cannot report Ctrl+Shift at all: Ctrl+I is the TAB byte, so the
# modifier is gone before zsh ever sees it. Ghostty can be told to send a
# distinct sequence, and terat.zsh already binds that sequence. Only Ghostty is
# touched, and only when its config exists.
ghostty_conf=${XDG_CONFIG_HOME:-$HOME/.config}/ghostty/config
ghostty_key='keybind = ctrl+shift+i=text:\x1b[105;6u'

add_keybind() {
	[ -f "$ghostty_conf" ] || return 0
	grep -qF "$ghostty_key" "$ghostty_conf" && return 0
	{
		printf '\n# terat: ctrl+shift+i asks in this terminal. Ghostty does not send it\n'
		printf '# by default: Ctrl+I is the TAB byte, so the modifier is lost first.\n'
		printf '%s\n' "$ghostty_key"
	} >>"$ghostty_conf"
	say "ctrl+shift+i added to $ghostty_conf"
}

drop_keybind() {
	[ -f "$ghostty_conf" ] || return 0
	grep -qF "$ghostty_key" "$ghostty_conf" || return 0
	grep -vF "$ghostty_key" "$ghostty_conf" |
		grep -vF '# terat: ctrl+shift+i asks in this terminal' |
		grep -vF '# by default: Ctrl+I is the TAB byte' >"$ghostty_conf.terat.tmp" || :
	mv "$ghostty_conf.terat.tmp" "$ghostty_conf"
}

for arg in "${1:-}" "${0:-}"; do
	if [ "$arg" = "--uninstall" ]; then
		drop_rc
		drop_keybind
		rm -f "$bindir/terat" "$bindir/terat.zsh" "$bindir/terat.lua"
		say "removed terat from $bindir"
		exit 0
	fi
done

tmp=$(mktemp -d 2>/dev/null || mktemp -d -t terat)
trap 'rm -rf "$tmp"' EXIT INT TERM

get "$base" terat >"$tmp/terat" || exit 1
get "$base" terat.zsh >"$tmp/terat.zsh" || exit 1
get "$base" terat.lua >"$tmp/terat.lua" || exit 1

# A 404 page or a captive-portal apology must not become an executable.
head -n 1 "$tmp/terat" | grep -q '^#!/bin/sh' ||
	die "the download is not terat; check $base"
# terat.zsh is sourced, not executed: it has no shebang to check.
grep -q '_terat_accept' "$tmp/terat.zsh" ||
	die "the download is not terat.zsh; check $base"
grep -q 'rex.action' "$tmp/terat.lua" ||
	die "the download is not terat.lua; check $base"

mkdir -p "$bindir" || die "cannot create $bindir"
chmod 755 "$tmp/terat" "$tmp/terat.zsh"
mv "$tmp/terat" "$bindir/terat"
mv "$tmp/terat.zsh" "$bindir/terat.zsh"
mv "$tmp/terat.lua" "$bindir/terat.lua"

# Verify the thing that was just moved, not the thing that was downloaded.
"$bindir/terat" --version >/dev/null 2>&1 ||
	die "$bindir/terat will not run"

if command -v zsh >/dev/null 2>&1; then
	if [ -f "$zshrc" ] && grep -qF "source $bindir/terat.zsh" "$zshrc"; then
		:
	else
		printf 'source %s\n' "$bindir/terat.zsh" >>"$zshrc"
		say "ask mode added to $zshrc"
	fi
else
	say "zsh is not installed: terat works, but ask mode needs it"
fi

add_keybind

"$bindir/terat" --version
case ":${PATH}:" in
*":$bindir:"*) ;;
*) say "note: $bindir is not on PATH; add it with"
   say "  echo 'export PATH=\"$HOME/.local/bin:\$PATH\"' >> ~/.zshrc" ;;
esac

# Rex owns its config: say the one line rather than edit a file we do not ship.
if [ -d "${XDG_CONFIG_HOME:-$HOME/.config}/rex" ]; then
	say "Rex is installed. For Cmd+Shift+I there, add to its init.lua:"
	say "  dofile(\"$bindir/terat.lua\")"
fi
