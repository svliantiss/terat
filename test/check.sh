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
	# Sourced twice on purpose. The prompt branch rewrites PROMPT on the first
	# pass, so a second pass cannot find the binary it looked for and used to
	# fall back to treating the prompt as a literal string — which printed the
	# `$(...)` source instead of a prompt, losing the glyph, the colours and the
	# ~, and landing the cursor a row off. A single source in the test could
	# never catch that.
	printf 'export PATH="$HOME/.local/bin:$PATH"\nsource ~/Projects/terat/terat.zsh\nsource ~/Projects/terat/terat.zsh\n' >>~/.zshrc
	tmux new-session -d -s T -x 100 -y 30 "zsh -i"
	# Wait for the prompt to be ready rather than guessing: under qemu a
	# `zsh -i` start-up and a fork can both take seconds, and a fixed sleep
	# then reads a half-drawn screen and calls it a fault.
	i=0
	while [ $i -lt 40 ]; do
		sleep 1
		tmux capture-pane -pt T 2>/dev/null | grep -q '%' && break
		i=$((i + 1))
	done
	tmux send-keys -t T '@hello' Enter
	# Same here: poll for the label instead of assuming a fixed latency.
	i=0
	while [ $i -lt 60 ]; do
		sleep 1
		tmux capture-pane -pt T >/tmp/scr.txt 2>/dev/null
		grep -q 'Pi:' /tmp/scr.txt && break
		i=$((i + 1))
	done
	tmux kill-server 2>/dev/null
	grep -q '🟅' /tmp/scr.txt || fail "pty: prompt never became the glyph"
	grep -q 'Pi:' /tmp/scr.txt || fail "pty: answer had no label"
	# The prompt must still be a real prompt. Printing the unexpanded `$(...)`
	# left this string on screen, which is how the double-source bug looked.
	grep -q '_terat_render' /tmp/scr.txt && fail "pty: the prompt is printed as source, not run"
	# `%~` unexpanded is the same bug wearing a different hat: -P is what makes
	# the plain branch render like zle would.
	grep -q '%~' /tmp/scr.txt && fail "pty: the prompt shows %~ instead of a path"
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

# 5. a harness that fails must not have its complaint served as the answer.
#    A CLI run by hand says why on stdout and exits 1; that text is an error,
#    not a reply, and printing it reads like the model answered.
cat > ~/.local/bin/angry <<'SH'
#!/bin/sh
cat >/dev/null
printf 'rate limited, retry later\n'
exit 1
SH
chmod +x ~/.local/bin/angry
out=$(cd /tmp && TERAT_CMD=angry tert 'q' </dev/null 2>&1)
case $out in
*"exited 1"*) ;;
*) fail "a failing harness was served as the answer: [$out]" ;;
esac

# 8. a harness that answers and then refuses to exit must not be reported as a
#    failure. pi stays alive after agent_end, so tert stops it and `wait` comes
#    back with 143. Reading that as "the harness failed" hides a good answer
#    behind an error, which is worse than either on its own.
cat > ~/.local/bin/stubborn <<'SH'
#!/bin/sh
cat >/dev/null
printf '{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"STUBBORN_OK"}]}}\n'
printf '{"type":"agent_end"}\n'
sleep 600
SH
chmod +x ~/.local/bin/stubborn
out=$(cd /tmp && TERAT_CMD=stubborn tert 'q' </dev/null 2>&1)
case $out in
*STUBBORN_OK*) ;;
*) fail "a harness that answered was rejected as failed: [$out]" ;;
esac

# 9. an attachment is inlined, so a harness with no @file support still sees the
#    file. Only some harnesses understand @path; a path handed to one that does
#    not is silently useless, and the model answers about the path.
printf 'the code is TANGERINE\n' >/tmp/attach.txt
cat > ~/.local/bin/echoall <<'SH'
#!/bin/sh
cat
SH
chmod +x ~/.local/bin/echoall
out=$(cd /tmp && TERAT_CMD=echoall tert 'what is the code?' @attach.txt </dev/null 2>&1)
case $out in
*TANGERINE*) ;;
*) fail "an @file was not inlined for the harness: [$out]" ;;
esac

# 10. a task-style harness (grok -p, dsh --profile headless) refuses stdin, so
#     `{}` puts the question on the command line instead. It must arrive as one
#     argument, with spaces and shell syntax intact and not executed.
cat > ~/.local/bin/taskcli <<'SH'
#!/bin/sh
printf 'argc=%s\n' "$#"
for a in "$@"; do printf 'ARG[%s]\n' "$a"; done
SH
chmod +x ~/.local/bin/taskcli
out=$(cd /tmp && TERAT_CMD='taskcli --flag {} --tail' tert 'say "hi" && echo $HOME' </dev/null 2>&1)
case $out in
*'ARG[--flag]'*'Question: say "hi" && echo $HOME'*'ARG[--tail]'*) ;;
*) fail "the {} placeholder did not pass the question as one argument: [$out]" ;;
esac

# 11. two placeholders each get the question. Adjacent ones used to overwrite
#     each other, which silently dropped an argument rather than failing.
out=$(cd /tmp && TERAT_CMD='taskcli {} {}' tert 'Q' </dev/null 2>&1 | sed -n 's/^argc=//p')
case $out in
2) ;;
*) fail "two {} placeholders did not each insert the question (argc=$out)" ;;
esac

# 6. with no pi installed the failure is explained, not a shell error
err=$(cd /tmp && PATH=/usr/bin:/bin TERAT_CMD= ~/Projects/terat/tert q </dev/null 2>&1)
case $err in
*"pi is not installed"*) ;;
*) fail "missing-pi message was [$err]" ;;
esac

# 7. the transcript actually reaches the question: a question can only be
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
	# Poll for the label rather than assuming a latency: under qemu an answer
	# can take longer than any fixed sleep, and reading the screen too early
	# reports "typing moved the transcript" for a run that never got there.
	i=0
	while [ $i -lt 60 ]; do
		sleep 1
		tmux capture-pane -pt C >/tmp/scr2.txt 2>/dev/null
		grep -q 'Pi:' /tmp/scr2.txt && break
		i=$((i + 1))
	done
	# typing must not disturb what is already on screen
	before=$(grep -c 'Pi:' /tmp/scr2.txt 2>/dev/null)
	before=${before:-0}
	tmux send-keys -t C 'typing'
	sleep 1
	tmux capture-pane -pt C >/tmp/scr3.txt 2>/dev/null
	after=$(grep -c 'Pi:' /tmp/scr3.txt 2>/dev/null)
	after=${after:-0}
	tmux kill-server 2>/dev/null
	grep -q 'CAPTURE_MARKER_XYZ' /tmp/q.txt 2>/dev/null ||
		fail "transcript did not reach the question"
	[ "$before" = "$after" ] ||
		fail "typing moved the transcript ($before -> $after)"
	note="$note+capture+stable"
fi

echo "  note=$note"
echo RESULT=PASS
