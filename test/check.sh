#!/bin/sh
# The claims, run inside each distro's container. Prints RESULT=PASS or
# RESULT=FAIL plus one line per fact, so run.sh can show a table.
#
# Nothing here is distro-specific: the same four claims matter everywhere, and
# a difference between distros is the finding.
set -u
fail() { echo "  FAIL $*"; echo RESULT=FAIL; exit 0; }

echo "  zsh=$(zsh --version 2>/dev/null | cut -d' ' -f1-2)"
echo "  sh=$(readlink -f /bin/sh 2>/dev/null | sed 's|.*/||')"

# Install the way the README says, from an empty home.
mkdir -p ~/Projects/terat ~/.local/bin
cp -R /src/. ~/Projects/terat/ 2>/dev/null || fail "copy source"
chmod +x ~/Projects/terat/tert

# 1. parses under this distro's sh, zsh and awk
sh -n ~/Projects/terat/tert || fail "sh -n tert"
zsh -n ~/Projects/terat/terat.zsh || fail "zsh -n terat.zsh"
awk -f ~/Projects/terat/terat-trace.awk /dev/null || fail "awk parse"

# A stand-in for pi: this suite is about terat, and no container has credentials.
# Real pi is covered separately in test/real-pi.md.
cat > ~/.local/bin/pi <<'SH'
#!/bin/sh
cat >/dev/null
printf '{"type":"session","cwd":"/t"}\n'
printf '{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"ANSWER_OK"}]}}\n'
printf '{"type":"agent_end"}\n'
SH
chmod +x ~/.local/bin/pi
ln -sf ~/Projects/terat/tert ~/.local/bin/tert
export PATH="$HOME/.local/bin:$PATH"

# 2. a question gets an answer; piped output is raw, with no label
ans=$(cd /tmp && tert 'q' </dev/null 2>&1)
[ "$ans" = "ANSWER_OK" ] || fail "piped answer was [$ans]"

# 3. through a real pty the prompt becomes the glyph and the answer is labelled
if command -v tmux >/dev/null 2>&1; then
	touch ~/.zshrc
	printf 'export PATH="$HOME/.local/bin:$PATH"\nsource ~/Projects/terat/terat.zsh\n' >>~/.zshrc
	tmux new-session -d -s T -x 100 -y 30 "zsh -i"
	sleep 2
	tmux send-keys -t T '@hello' Enter
	sleep 2
	tmux capture-pane -pt T >/tmp/scr.txt 2>/dev/null
	tmux kill-server 2>/dev/null
	grep -q '🟅' /tmp/scr.txt || fail "pty: prompt never became the glyph"
	grep -q 'Pi:' /tmp/scr.txt || fail "pty: answer had no label"
	note=pty+glyph+label
else
	note=no-tmux
fi

# 4. a plain-text harness works too: no json events, no agent_end, answer on
#    stdout. This is the claude/cursor/dsh shape, and it must not need pi.
cat > ~/.local/bin/plainh <<'SH'
#!/bin/sh
cat >/dev/null
printf '   PLAIN_TEXT_ANSWER\n'
SH
chmod +x ~/.local/bin/plainh
ans=$(cd /tmp && TERAT_CMD=plainh tert 'q' </dev/null 2>&1)
[ "$ans" = "   PLAIN_TEXT_ANSWER" ] ||
	fail "plain-text harness answered [$ans]"

# 5. with no pi installed the failure is explained, not a shell error
err=$(cd /tmp && PATH=/usr/bin:/bin TERAT_CMD= ~/Projects/terat/tert q </dev/null 2>&1)
case $err in
*"pi is not installed"*) ;;
*) fail "missing-pi message was [$err]" ;;
esac

# 6. the transcript actually reaches the question: a question can only be
#    answered from the shell's own history if the history is sent.
if command -v tmux >/dev/null 2>&1; then
	cat > ~/.local/bin/pi <<'SH'
#!/bin/sh
cat >/tmp/q.txt
printf '{"type":"session","cwd":"/t"}\n'
printf '{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"ANSWER_OK"}]}}\n'
printf '{"type":"agent_end"}\n'
SH
	chmod +x ~/.local/bin/pi
	tmux new-session -d -s C -x 110 -y 30 "zsh -i"
	sleep 2
	tmux send-keys -t C 'echo CAPTURE_MARKER_XYZ' Enter
	sleep 1.2
	tmux send-keys -t C '@what did I run' Enter
	sleep 2.5
	tmux capture-pane -pt C >/tmp/scr2.txt 2>/dev/null
	# typing must not disturb what is already on screen
	before=$(grep -c 'Pi:' /tmp/scr2.txt 2>/dev/null || echo 0)
	tmux send-keys -t C 'typing'
	sleep 1
	tmux capture-pane -pt C >/tmp/scr3.txt 2>/dev/null
	after=$(grep -c 'Pi:' /tmp/scr3.txt 2>/dev/null || echo 0)
	tmux kill-server 2>/dev/null
	grep -q 'CAPTURE_MARKER_XYZ' /tmp/q.txt 2>/dev/null ||
		fail "transcript did not reach the question"
	[ "$before" = "$after" ] ||
		fail "typing moved the transcript ($before -> $after)"
	note="$note+capture+stable"
fi

echo "  note=$note"
echo RESULT=PASS
