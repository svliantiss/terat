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

# This script installs into $HOME and appends to $HOME/.zshrc, which is correct
# inside a throwaway container and destructive anywhere else: run on a laptop it
# adds its source lines to the real zshrc on every run, and the copies under /tmp
# then shadow the real install in every new shell. A container has no marker, so
# the marker is the reverse test — if this home already holds a zshrc this script
# did not write, stop rather than edit it. TERAT_TEST_HOME overrides both, so a
# host run can point at a scratch directory and mean it.
if [ "${TERAT_TEST_HOME:-}" != '' ]; then
	HOME=$TERAT_TEST_HOME
	export HOME
	mkdir -p "$HOME"
elif [ -e ~/.zshrc ] && ! grep -q 'TERAT-TEST-HOME' ~/.zshrc 2>/dev/null; then
	printf '  SKIP installed-home zshrc exists and is not ours: %s\n' ~/.zshrc
	printf 'RESULT=SKIP\n'
	exit 0
fi
: >>~/.zshrc
printf '# TERAT-TEST-HOME\n' >>~/.zshrc

# Install the way the README says, from an empty home. Everything the suite
# needs to fake goes in $D, beside terat, and never in ~/.local/bin: on a real
# machine `~/.local/bin/pi` can be a symlink to a managed install, and a `>`
# through it overwrites the agent instead of testing ours. That is not
# hypothetical — it happened, and had to be restored by hand.
D=$HOME/Projects/terat
mkdir -p "$D"
cp -R /src/. "$D/" 2>/dev/null || fail "copy source"
chmod +x "$D/terat"

# 1. parses under this distro's sh, zsh and awk
sh -n ~/Projects/terat/terat || fail "sh -n terat"
zsh -n ~/Projects/terat/terat.zsh || fail "zsh -n terat.zsh"
awk -f ~/Projects/terat/terat-trace.awk /dev/null || fail "awk parse"

# A stand-in for pi: this suite is about terat, and no container has credentials.
# Real pi is covered separately in test/real-pi.md.
cat > $D/pi <<'SH'
#!/bin/sh
cat >/dev/null
printf '{"type":"session","cwd":"/t"}\n'
printf '{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"ANSWER_OK"}]}}\n'
printf '{"type":"agent_end"}\n'
SH
chmod +x $D/pi
export PATH="$D:$PATH"

# 2. a question gets an answer; piped output is raw, with no label
ans=$(cd /tmp && terat 'q' </dev/null 2>&1)
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
	printf 'export PATH="$D:$PATH"\nsource ~/Projects/terat/terat.zsh\nsource ~/Projects/terat/terat.zsh\n' >>~/.zshrc
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
	# Ctrl+X t toggles tracing for the session and says which way it went. Sent at
	# the first prompt, before any answer is being drawn: pressing it right after
	# an answer raced the redraw, and a key read by the tty inside that window is
	# simply lost — which looked exactly like a binding that does not work and
	# passed only when the machine happened to be slow. The key is still sent
	# through tmux to a real zle, which is what catches a binding that is present
	# but swallowed by another widget.
	_terat_trace_key() {
		want=$1
		tmux send-keys -t T C-x t
		i=0
		while [ $i -lt 10 ]; do
			sleep 1
			tmux capture-pane -pt T >/tmp/scrtrace.txt 2>/dev/null
			grep -q "trace: $want" /tmp/scrtrace.txt && return 0
			i=$((i + 1))
		done
		return 1
	}
	sleep 2
	_terat_trace_key on || fail "pty: Ctrl+X t did not turn tracing on; screen was [$(grep -v '^[[:space:]]*$' /tmp/scrtrace.txt | tail -4 | tr '\n' '|')]"
	_terat_trace_key off || fail "pty: Ctrl+X t did not turn tracing off again; screen was [$(grep -v '^[[:space:]]*$' /tmp/scrtrace.txt | tail -4 | tr '\n' '|')]"
	# The `%` above matches the *default* zsh prompt too, so it says the shell is
	# up, not that terat.zsh has loaded. Everything below needs the widget to
	# exist: sent before it does, `@hello` runs as a command and the keypress is
	# read by nothing. Ask the shell directly instead of inferring from the
	# screen, which is the only signal that is actually about readiness.
	tmux send-keys -t T 'whence -w _terat_accept >/dev/null && echo TERAT_READY' Enter
	i=0
	while [ $i -lt 40 ]; do
		sleep 1
		tmux capture-pane -pt T >/tmp/scrready.txt 2>/dev/null
		grep -q 'TERAT_READY' /tmp/scrready.txt && break
		i=$((i + 1))
	done
	grep -q 'TERAT_READY' /tmp/scrready.txt || fail "pty: terat.zsh never loaded in the shell"
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
	# The program's own name alone flips the mode, and the name is not the one
	# it used to be: a rename that misses this line leaves `terat` typed at the
	# prompt being sent to the model as a question. It is its own claim because
	# nothing else in the suite types a bare word.
	tmux new-session -d -s W -x 100 -y 30 "zsh -i"
	i=0
	while [ $i -lt 40 ]; do
		sleep 1
		tmux capture-pane -pt W 2>/dev/null | grep -q '%' && break
		i=$((i + 1))
	done
	tmux send-keys -t W 'terat' Enter
	i=0
	while [ $i -lt 20 ]; do
		sleep 1
		tmux capture-pane -pt W >/tmp/word.txt 2>/dev/null
		grep -q '🟅' /tmp/word.txt && break
		i=$((i + 1))
	done
	tmux kill-server 2>/dev/null
	grep -q '🟅' /tmp/word.txt || fail "a bare terat did not flip the prompt to the glyph"
	grep -q 'Pi:' /tmp/word.txt && fail "a bare terat was asked of the model instead of flipping"
	note=$note+word
else
	note=no-tmux
fi

# 4. a plain-text harness works too: no json events, no agent_end, answer on
#    stdout. This is the claude/cursor/dsh shape, and it must not need pi.
cat > $D/plainh <<'SH'
#!/bin/sh
cat >/dev/null
printf '   PLAIN_TEXT_ANSWER\n'
SH
chmod +x $D/plainh
ans=$(cd /tmp && TERAT_CMD=plainh terat 'q' </dev/null 2>&1)
[ "$ans" = "   PLAIN_TEXT_ANSWER" ] ||
	fail "plain-text harness answered [$ans]"

# 5. a harness that fails must not have its complaint served as the answer.
#    A CLI run by hand says why on stdout and exits 1; that text is an error,
#    not a reply, and printing it reads like the model answered.
cat > $D/angry <<'SH'
#!/bin/sh
cat >/dev/null
printf 'rate limited, retry later\n'
exit 1
SH
chmod +x $D/angry
out=$(cd /tmp && TERAT_CMD=angry terat 'q' </dev/null 2>&1)
case $out in
*"exited 1"*) ;;
*) fail "a failing harness was served as the answer: [$out]" ;;
esac

# 8. a harness that answers and then refuses to exit must not be reported as a
#    failure. pi stays alive after agent_end, so terat stops it and `wait` comes
#    back with 143. Reading that as "the harness failed" hides a good answer
#    behind an error, which is worse than either on its own.
cat > $D/stubborn <<'SH'
#!/bin/sh
cat >/dev/null
printf '{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"STUBBORN_OK"}]}}\n'
printf '{"type":"agent_end"}\n'
sleep 600
SH
chmod +x $D/stubborn
out=$(cd /tmp && TERAT_CMD=stubborn terat 'q' </dev/null 2>&1)
case $out in
*STUBBORN_OK*) ;;
*) fail "a harness that answered was rejected as failed: [$out]" ;;
esac

# 9. an attachment is inlined, so a harness with no @file support still sees the
#    file. Only some harnesses understand @path; a path handed to one that does
#    not is silently useless, and the model answers about the path.
printf 'the code is TANGERINE\n' >/tmp/attach.txt
cat > $D/echoall <<'SH'
#!/bin/sh
cat
SH
chmod +x $D/echoall
out=$(cd /tmp && TERAT_CMD=echoall terat 'what is the code?' @attach.txt </dev/null 2>&1)
case $out in
*TANGERINE*) ;;
*) fail "an @file was not inlined for the harness: [$out]" ;;
esac

# 10. a task-style harness (grok -p, dsh --profile headless) refuses stdin, so
#     `{}` puts the question on the command line instead. It must arrive as one
#     argument, with spaces and shell syntax intact and not executed.
cat > $D/taskcli <<'SH'
#!/bin/sh
printf 'argc=%s\n' "$#"
for a in "$@"; do printf 'ARG[%s]\n' "$a"; done
SH
chmod +x $D/taskcli
out=$(cd /tmp && TERAT_CMD='taskcli --flag {} --tail' terat 'say "hi" && echo $HOME' </dev/null 2>&1)
case $out in
*'ARG[--flag]'*'Question: say "hi" && echo $HOME'*'ARG[--tail]'*) ;;
*) fail "the {} placeholder did not pass the question as one argument: [$out]" ;;
esac

# 11. two placeholders each get the question. Adjacent ones used to overwrite
#     each other, which silently dropped an argument rather than failing.
out=$(cd /tmp && TERAT_CMD='taskcli {} {}' terat 'Q' </dev/null 2>&1 | sed -n 's/^argc=//p')
case $out in
2) ;;
*) fail "two {} placeholders did not each insert the question (argc=$out)" ;;
esac

# 12. a past shell command in the transcript must not be run again. The harness
#     is an agent with a shell: shown `cmd: rm -rf ...` and then a question, it
#     read the command as the request and executed it in about one run in three.
#     The question now comes first and the history is labelled as history, which
#     is what this checks — the transcript the harness is handed, not the model.
: >/tmp/th.replay
printf 'cmd: touch /tmp/canary/CANARY\n' >/tmp/th.replay
rm -rf /tmp/canary && mkdir -p /tmp/canary
cat >$D/replaycap <<'SH'
#!/bin/sh
cat >/tmp/replay.sent
echo REPLAYED
SH
chmod +x $D/replaycap
: >/tmp/replay.sent
TERAT_THREAD=/tmp/th.replay TERAT_CMD=replaycap terat 'hello' </dev/null >/dev/null 2>&1
# The question must be the first thing the harness reads.
[ "$(head -1 /tmp/replay.sent)" = "Question: hello" ] ||
	fail "the transcript does not open with the question: [$(head -1 /tmp/replay.sent)]"
# The history must be there, and named as history rather than presented bare.
grep -q 'cmd: touch /tmp/canary/CANARY' /tmp/replay.sent ||
	fail "the shell history never reached the harness"
grep -qi 'already' /tmp/replay.sent ||
	fail "the history is presented without saying it already happened"

# 13. a harness that streams must not be cut off at its first quiet moment. The
#     grace window exists because a model pauses mid-answer; reading a pause as
#     "done" printed the first chunk and dropped the rest, which looked like the
#     prompt eating the answer and sent us hunting through the widget instead.
cat > $D/slowh <<'SH'
#!/bin/sh
cat >/dev/null
printf 'first\n'
sleep 2
printf 'second\n'
SH
chmod +x $D/slowh
out=$(cd /tmp && TERAT_CMD=slowh terat 'q' </dev/null 2>&1)
case $out in
*first*second*) ;;
*) fail "a slow harness was cut off: [$out]" ;;
esac

# 6. with the agent missing the failure is explained, not a shell error
err=$(cd /tmp && PATH=/usr/bin:/bin TERAT_CMD= ~/Projects/terat/terat q </dev/null 2>&1)
case $err in
*"pi is not installed"*) ;;
*) fail "missing-agent message was [$err]" ;;
esac

# 6b. and it names the agent that was actually asked: `terat claude` with no
#     claude must not say pi, or the message sends you to the wrong install.
err=$(cd /tmp && PATH=/usr/bin:/bin TERAT_CMD= ~/Projects/terat/terat claude q </dev/null 2>&1)
case $err in
*"claude is not installed"*) ;;
*) fail "missing-claude message was [$err]" ;;
esac

# 6c. `terat set` writes a setting and reads it back, without asking anything.
#     A config that only looks saved is worse than none, so this checks the file
#     too: the first write used to succeed and store nothing, because awk exits 2
#     on a file it cannot open and never reaches END.
export XDG_CONFIG_HOME=/tmp/teratcfg
rm -rf "$XDG_CONFIG_HOME"
got=$(cd /tmp && terat set agent codex </dev/null 2>&1)
case $got in
agent=codex*) ;;
*) fail "set agent said [$got]" ;;
esac
grep -qx 'agent=codex' "$XDG_CONFIG_HOME/terat/settings" || fail "set agent wrote no file"
got=$(cd /tmp && terat set agent </dev/null 2>&1)
[ "$got" = codex ] || fail "set agent read back [$got]"
# a key is never echoed, only acknowledged
got=$(cd /tmp && terat set key sk-not-a-real-key </dev/null 2>&1)
[ "$got" = 'key=(set)' ] || fail "set key said [$got]"
grep -q 'sk-not-a-real-key' "$XDG_CONFIG_HOME/terat/settings" || fail "set key stored nothing"
got=$(cd /tmp && terat config </dev/null 2>&1)
case $got in
*'key=(set)'*) ;;
*) fail "config did not redact the key: [$got]" ;;
esac
case $got in
*sk-not-a-real-key*) fail "config printed the key" ;;
esac
# an unknown agent is refused rather than saved and failed on later
got=$(cd /tmp && terat set agent nosuchagent </dev/null 2>&1)
case $got in
*"no such agent"*) ;;
*) fail "set agent nosuchagent said [$got]" ;;
esac
grep -qx 'agent=codex' "$XDG_CONFIG_HOME/terat/settings" ||
	fail "a refused agent overwrote the saved one"
rm -rf "$XDG_CONFIG_HOME"
unset XDG_CONFIG_HOME

# 6d. `terat <agent>` picks the agent for one question, and the label follows.
#     Without a real binary the command is still the agent's, so the message has
#     to name that agent.
for pair in 'grok Grok' 'dsh dsh' 'opencode opencode'; do
	set -- $pair
	got=$(cd /tmp && PATH=/usr/bin:/bin TERAT_CMD= ~/Projects/terat/terat "$1" q </dev/null 2>&1)
	case $got in
	*"$1 is not installed"*) ;;
	*) fail "terat $1 did not choose $1: [$got]" ;;
	esac
done

# 6e. `--` keeps a question that begins with an agent name from being taken as
#     a request for that agent, and keeps the marker out of the question. Ask
#     mode passes the question as argv words, so this is the interactive case:
#     asking "claude wrote this" must reach the agent as written.
cat >/tmp/whichagent <<'SH'
#!/bin/sh
printf 'AGENT=%s Q=[%s]\n' "$TERAT_AGENT" "$(sed -n '1s/^Question: //p')"
SH
chmod +x /tmp/whichagent
got=$(cd /tmp && TERAT_CMD=/tmp/whichagent ~/Projects/terat/terat -- claude wrote this </dev/null 2>&1)
case $got in
*'AGENT=pi'*) ;;
*) fail "a question starting with an agent name changed the agent: [$got]" ;;
esac
case $got in
*'Q=[claude wrote this]'*) ;;
*) fail "the -- marker leaked into the question: [$got]" ;;
esac
# and the explicit form still selects, so the escape hatch is not the only way
got=$(cd /tmp && TERAT_CMD=/tmp/whichagent ~/Projects/terat/terat grok what is this </dev/null 2>&1)
case $got in
*'AGENT=grok Q=[what is this]'*) ;;
*) fail "terat grok did not select grok: [$got]" ;;
esac

# 6f. dsh is told where its key is, not handed one inline. `apiKey: <literal>`
#     is not a field dsh reads: it starts and then says "No API key for
#     provider", which looks like a bad key rather than a bad config. Only
#     `apiKeyEnv` plus that variable exported actually authenticates.
cat >/tmp/dshkeyprobe <<'SH'
#!/bin/sh
printf 'KEYVAR=%s EXPORTED=%s\n' \
	"$(sed -n 's/.*apiKeyEnv: //p' "$DSH_HOME/profiles/headless/cordis.patch.yml")" \
	"${TERAT_KEY:+yes}"
SH
chmod +x /tmp/dshkeyprobe
export XDG_CONFIG_HOME=/tmp/teratdsh
rm -rf "$XDG_CONFIG_HOME"
(terat set url http://127.0.0.1:1/v1 && terat set key sk-dsh && terat set model m1) >/dev/null 2>&1
got=$(cd /tmp && TERAT_CMD=/tmp/dshkeyprobe ~/Projects/terat/terat dsh q </dev/null 2>&1)
case $got in
*'KEYVAR=TERAT_KEY EXPORTED=yes'*) ;;
*) fail "dsh config was [$got]" ;;
esac
case $got in
*sk-dsh*) fail "the key was written into dsh's config instead of named" ;;
esac
# The model entry must also claim image input. dsh bundles the same library as pi
# and drops an attached image for a model that does not declare one, so the
# answer blames the model for a property of the config.
cat >/tmp/dshimgprobe <<'SH'
#!/bin/sh
cat >/dev/null
grep -A3 'name: m1' "$DSH_HOME/profiles/headless/cordis.patch.yml" 2>/dev/null
SH
chmod +x /tmp/dshimgprobe
export XDG_CONFIG_HOME=/tmp/teratdsh
rm -rf "$XDG_CONFIG_HOME"
(terat set url http://127.0.0.1:1/v1 && terat set model m1) >/dev/null 2>&1
got=$(cd /tmp && TERAT_CMD=/tmp/dshimgprobe ~/Projects/terat/terat dsh q </dev/null 2>&1)
case $got in
*'input: ["text", "image"]'*) ;;
*) fail "dsh model entry does not declare image input: [$got]" ;;
esac
rm -rf "$XDG_CONFIG_HOME"
unset XDG_CONFIG_HOME

# 6g. pi's generated models.json declares that the model can take images.
#     Without `input`, pi treats the entry as text-only and drops the image
#     before the question is asked, so a vision model answers "I cannot see
#     images" — a config fault that reads like the model's own limitation.
cat > $D/pi <<'SH'
#!/bin/sh
cat >/dev/null
cp "$PI_CODING_AGENT_DIR/models.json" /tmp/mj.txt 2>/dev/null
printf '{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"X"}]}}\n'
printf '{"type":"agent_end"}\n'
SH
chmod +x $D/pi
rm -f /tmp/mj.txt
XDG_CONFIG_HOME=$(mktemp -d)
export XDG_CONFIG_HOME
terat set url http://127.0.0.1:9/v1 >/dev/null 2>&1
terat set model vision-model >/dev/null 2>&1
terat q </dev/null >/dev/null 2>&1
grep -q '"input":\["text","image"\]' /tmp/mj.txt 2>/dev/null ||
	fail "pi models.json does not declare image input: $(head -c 120 /tmp/mj.txt 2>/dev/null)"
rm -rf "$XDG_CONFIG_HOME"
unset XDG_CONFIG_HOME
# put the answering stand-in back for the claims that follow
cat > $D/pi <<'SH'
#!/bin/sh
cat >/dev/null
printf '{"type":"session","cwd":"/t"}\n'
printf '{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"ANSWER_OK"}]}}\n'
printf '{"type":"agent_end"}\n'
SH
chmod +x $D/pi

# 6h. opencode's generated config declares the same thing, spelled `modalities`.
#     It drops the attachment without it, and the answer blames the model.
cat > $D/opencode <<'SH'
#!/bin/sh
cat >/dev/null
cp "$OPENCODE_CONFIG_DIR/opencode.json" /tmp/ocj.txt 2>/dev/null
printf '{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"X"}]}}\n'
printf '{"type":"agent_end"}\n'
SH
chmod +x $D/opencode
rm -f /tmp/ocj.txt
XDG_CONFIG_HOME=$(mktemp -d)
export XDG_CONFIG_HOME
terat set agent opencode >/dev/null 2>&1
terat set url http://127.0.0.1:9/v1 >/dev/null 2>&1
terat q </dev/null >/dev/null 2>&1
# It must parse at all as well as carry image input: a stray brace is worse than
# the original bug, because opencode then rejects its entire config.
python3 -c '
import json
d = json.load(open("/tmp/ocj.txt"))
m = list(d["provider"]["terat"]["models"].values())[0]
assert m["modalities"]["input"] == ["text", "image"], m
' || fail "opencode.json is not valid JSON with image modalities: $(head -c 120 /tmp/ocj.txt 2>/dev/null)"
rm -rf "$XDG_CONFIG_HOME"
unset XDG_CONFIG_HOME
terat set agent pi >/dev/null 2>&1

# 6i. the generated config holds the key, so it must not be readable by other
#     users. `>` takes the umask (normally 022), which left a key-bearing file
#     at 644 next to a 600 settings file — the same secret, two permissions.
cat > $D/pi <<'SH'
#!/bin/sh
cat >/dev/null
# Column 1 only: macOS appends an `@` for extended attributes, which is not
# part of the permission bits and would fail a correct 600/700.
ls -ld "$PI_CODING_AGENT_DIR" "$PI_CODING_AGENT_DIR/models.json" 2>/dev/null |
	awk '{print $1}' | tr -d '@' > /tmp/perm.txt
printf '{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"X"}]}}\n'
printf '{"type":"agent_end"}\n'
SH
chmod +x $D/pi
rm -f /tmp/perm.txt
XDG_CONFIG_HOME=$(mktemp -d)
export XDG_CONFIG_HOME
terat set url http://127.0.0.1:9/v1 >/dev/null 2>&1
terat set key sk-not-a-real-key >/dev/null 2>&1
terat set model mm >/dev/null 2>&1
terat q </dev/null >/dev/null 2>&1
# Accept only 700 on the dir and 600 on the file: any group/other bit on either
# exposes the key to another user on the same machine.
# Cleared first: the writes below are conditional, so a verdict left over from
# an earlier run would otherwise stand in for this one.
rm -f /tmp/permbad.txt
# First line is the directory, second the file it holds.
sed -n 1p /tmp/perm.txt 2>/dev/null | grep -qx 'drwx------' ||
	echo "key dir is $(sed -n 1p /tmp/perm.txt 2>/dev/null)" >/tmp/permbad.txt
sed -n 2p /tmp/perm.txt 2>/dev/null | grep -qx -- '-rw-------' ||
	echo "key file is $(sed -n 2p /tmp/perm.txt 2>/dev/null)" >>/tmp/permbad.txt
[ -s /tmp/permbad.txt ] && fail "generated pi config is not private: $(tr '\n' ' ' </tmp/permbad.txt)"
rm -rf "$XDG_CONFIG_HOME"
unset XDG_CONFIG_HOME
cat > $D/pi <<'SH'
#!/bin/sh
cat >/dev/null
printf '{"type":"session","cwd":"/t"}\n'
printf '{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"ANSWER_OK"}]}}\n'
printf '{"type":"agent_end"}\n'
SH
chmod +x $D/pi
# 6j. `terat models` names what the endpoint serves, and marks the ones that
#     take images. A model can be used without it, but only by already knowing
#     the id — and the image flag is what silently changes an answer, so it has
#     to come from the server rather than from a guess about the name.
#
#     Served from a shell loop rather than python: the containers carry zsh,
#     tmux, curl, gawk and netcat but no interpreter, and a claim that quietly
#     needs one skips itself and still reports PASS.
if command -v nc >/dev/null 2>&1; then
	port=18771
	cat >/tmp/modelsrv.sh <<SH
#!/bin/sh
resp() {
	printf 'HTTP/1.1 200 OK\r\ncontent-type: application/json\r\nconnection: close\r\n\r\n'
	printf '%s' '{"object":"list","data":[{"id":"plain/model","capabilities":{"input_modalities":["text"]}},{"id":"sees/model","capabilities":{"input_modalities":["text","image"]}},{"id":"bare/model"}]}'
}
i=0
while [ \$i -lt 4 ]; do
	resp | nc -l 127.0.0.1 $port >/dev/null 2>&1
	i=\$((i + 1))
done
SH
	chmod +x /tmp/modelsrv.sh
	/tmp/modelsrv.sh >/dev/null 2>&1 &
	srvpid=$!
	sleep 0.5
	XDG_CONFIG_HOME=$(mktemp -d)
	export XDG_CONFIG_HOME
	terat set url "http://127.0.0.1:$port/v1" >/dev/null 2>&1
	terat models >/tmp/mlist.txt 2>&1
	want='text	plain/model
vision	sees/model
text	bare/model'
	got=$(cat /tmp/mlist.txt)
	[ "$got" = "$want" ] || fail "terat models is wrong: [$got]"
	# A filter narrows by name without changing the flag.
	terat models sees >/tmp/mfilt.txt 2>&1
	[ "$(cat /tmp/mfilt.txt)" = "vision	sees/model" ] ||
		fail "terat models filter is wrong: [$(cat /tmp/mfilt.txt)]"
	kill $srvpid 2>/dev/null
	wait $srvpid 2>/dev/null
	# With no endpoint it must say so rather than print nothing and succeed.
	XDG_CONFIG_HOME=$(mktemp -d)
	export XDG_CONFIG_HOME
	if terat models >/tmp/mnone.txt 2>&1; then fail "terat models succeeded with no endpoint"; fi
	grep -q 'no endpoint' /tmp/mnone.txt || fail "terat models did not name the missing endpoint"
	rm -rf "$XDG_CONFIG_HOME"
	unset XDG_CONFIG_HOME
fi


# 6k. `--trace` propagates one id to the model request and the span post, and
#     `set trace on|off` decides whether that happens without the flag.
#     The provider name is the part worth pinning: the extension registers the
#     traceparent against a provider *name*, and a name that does not match
#     models.json is not an error — the header silently never goes out, so the
#     trace posts and the request it came from cannot be found again.
#     Tested through a stand-in pi rather than $TERAT_CMD, because a custom
#     command deliberately bypasses propagation: it is not terat's agent, so
#     there is nothing to load the extension into.
cat >/tmp/fakepi <<'SH'
#!/bin/sh
cat >/dev/null
printf 'EXT=%s\n' "$(printf '%s' "$*" | grep -c 'terat-trace.js')"
printf 'TRACEID=%s\n' "${TERAT_TRACE_ID:-unset}"
printf 'PROV=%s\n' "${TERAT_TRACE_PROVIDER:-unset}"
printf '{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"X"}]}}\n'
printf '{"type":"agent_end"}\n'
SH
chmod +x /tmp/fakepi
# A directory holding only this stand-in, so `command -v pi` finds it and no
# real agent is involved in the claim.
rm -rf /tmp/fakeagent && mkdir -p /tmp/fakeagent
cp /tmp/fakepi /tmp/fakeagent/pi
XDG_CONFIG_HOME=$(mktemp -d)
export XDG_CONFIG_HOME
terat set url http://127.0.0.1:9/v1 >/dev/null 2>&1
terat set model m1 >/dev/null 2>&1
# off: no id, no extension, so nothing can be propagated.
terat set trace off >/dev/null 2>&1
got=$(PATH=/tmp/fakeagent:$PATH TERAT_TRACE_ID= terat q </dev/null 2>&1)
case $got in
*EXT=0*) ;;
*) fail "extension was loaded with tracing off: [$got]" ;;
esac
# on: an id is minted, the extension loads, and it is told the provider name
# terat actually writes into the config it generated.
terat set trace on >/dev/null 2>&1
got=$(PATH=/tmp/fakeagent:$PATH TERAT_TRACE_ID= terat q </dev/null 2>&1)
case $got in
*EXT=1*) ;;
*) fail "set trace on did not load the extension: [$got]" ;;
esac
case $got in
*TRACEID=unset*) fail "set trace on minted no id: [$got]" ;;
esac
case $got in
*PROV=terat*) ;;
*) fail "trace extension was not told the generated provider name: [$got]" ;;
esac
# The flag alone works with tracing off, because asking for one question is
# exactly what it is for.
terat set trace off >/dev/null 2>&1
got=$(PATH=/tmp/fakeagent:$PATH TERAT_TRACE_ID= terat --trace q </dev/null 2>&1)
case $got in
*EXT=1*) ;;
*) fail "--trace did not load the extension: [$got]" ;;
esac
# The session toggle set by ask mode's Ctrl+X t has to beat the saved default,
# or pressing it does nothing in the shell it was pressed in.
terat set trace off >/dev/null 2>&1
got=$(PATH=/tmp/fakeagent:$PATH TERAT_TRACE=1 TERAT_TRACE_ID= terat q </dev/null 2>&1)
case $got in
*EXT=1*) ;;
*) fail "TERAT_TRACE=1 did not override set trace off: [$got]" ;;
esac
terat set trace on >/dev/null 2>&1
got=$(PATH=/tmp/fakeagent:$PATH TERAT_TRACE=0 TERAT_TRACE_ID= terat q </dev/null 2>&1)
case $got in
*EXT=0*) ;;
*) fail "TERAT_TRACE=0 did not override set trace on: [$got]" ;;
esac
# Every agent that can carry a traceparent must actually be given one, and each
# carries it in its own place. Appending `-e` (pi's extension loader) to every
# agent was what shipped first: claude answered "unknown option '-e'" and opencode
# misread the flag, so asking for a trace broke two of the six outright.
# The stub reports where the value ended up, so this fails if a mechanism dies.
cat >/tmp/whichhdr <<'SH'
#!/bin/sh
cat >/dev/null
ids=''
[ -n "${ANTHROPIC_CUSTOM_HEADERS:-}" ] && ids="$ids claude:$ANTHROPIC_CUSTOM_HEADERS"
[ -n "${TERAT_TRACEPARENT:-}" ] && ids="$ids codex-env:$TERAT_TRACEPARENT"
case $* in
*-c*env_http_headers.traceparent*) ids="$ids codex-arg" ;;
esac
for d in "${OPENCODE_CONFIG_DIR:-}" "${DSH_HOME:-}"; do
	[ -n "$d" ] || continue
	for f in "$d/opencode.json" "$d/profiles/headless/cordis.patch.yml"; do
		[ -f "$f" ] && ids="$ids $(grep -o 'traceparent[^,}]*' "$f" 2>/dev/null)"
	done
done
printf 'HDR=%s\n' "$ids"
printf 'ARGV=%s\n' "$*"
printf '{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"X"}]}}\n'
printf '{"type":"agent_end"}\n'
SH
chmod +x /tmp/whichhdr
for who in claude codex opencode dsh; do
	case $who in
	claude) hdr_where='claude:traceparent' ;;   # env header list
	codex) hdr_where='codex-env' ;;             # header from an env var
	opencode) hdr_where='traceparent":"' ;;     # options.headers in its config
	dsh) hdr_where='traceparent: ' ;;           # headers: in the provider patch
	esac
	rm -rf /tmp/oneagent && mkdir -p /tmp/oneagent
	cp /tmp/whichhdr "/tmp/oneagent/$who"
	XDG_CONFIG_HOME=$(mktemp -d)
	export XDG_CONFIG_HOME
	(terat set url http://127.0.0.1:9/v1 && terat set model m1) >/dev/null 2>&1
	got=$(PATH=/tmp/oneagent:$PATH TERAT_TRACE_ID= terat --trace "$who" q </dev/null 2>&1)
	rm -rf "$XDG_CONFIG_HOME"
	XDG_CONFIG_HOME=/tmp/terat-claim-nohome
	# None of the other five may be handed pi's extension flag. Read the argv
	# line alone: the question terat builds also lists the working directory, and
	# that listing contains terat-trace.js, so searching the whole output made
	# this fire on a correct run.
	argv_line=$(printf '%s\n' "$got" | grep '^ARGV=' | head -1)
	case $argv_line in
	*terat-trace.js*) fail "$who was handed pi's -e extension: [$argv_line]" ;;
	esac
# The value has to arrive where that agent actually reads it, in the shape the
# router parses, and each agent must get its own mechanism rather than another's.
	case $(printf '%s\n' "$got" | grep '^HDR=' | head -1) in
	*"$hdr_where"*00-[0-9a-f][0-9a-f]*) ;;
	*) fail "$who carried no $hdr_where: $(printf '%s\n' "$got" | grep '^HDR=' | head -1)" ;;
	esac
done
# `trace off` must silence both halves. Gating only the span left the header going
# out, so the router's ledger recorded a trace id while no span was ever posted:
# the split that one id exists to prevent.
cat >/tmp/whichoff <<'SH'
#!/bin/sh
cat >/dev/null
printf 'HDR=%s\n' "${TERAT_TRACEPARENT:-}${ANTHROPIC_CUSTOM_HEADERS:-}"
printf '{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"X"}]}}\n'
printf '{"type":"agent_end"}\n'
SH
chmod +x /tmp/whichoff
rm -rf /tmp/offagent && mkdir -p /tmp/offagent
cp /tmp/whichoff /tmp/offagent/codex
XDG_CONFIG_HOME=$(mktemp -d)
export XDG_CONFIG_HOME
(terat set url http://127.0.0.1:9/v1 && terat set model m1 && terat set trace off) >/dev/null 2>&1
# codex is the witness because it reads the header from an env var, which a stub
# can observe; dsh reads it from a generated YAML and cannot answer this question.
# An exported id is a real setup, and it must not smuggle a header past `off`.
# Assert on the id, not on the word: the stub prints the value, so grepping for
# "traceparent" matched nothing and the guard passed over a leaking header.
offhdr=$(PATH=/tmp/offagent:$PATH TERAT_TRACE_ID=deadbeefdeadbeefdeadbeefdeadbeef \
	terat codex q </dev/null 2>&1 | grep '^HDR=' | grep -c 'deadbeef')
[ "$offhdr" = 0 ] || fail "trace off propagated a header anyway"
# And --trace must beat `off`, or the flag is the thing that does not work.
onhdr=$(PATH=/tmp/offagent:$PATH TERAT_TRACE_ID=deadbeefdeadbeefdeadbeefdeadbeef \
	terat --trace codex q </dev/null 2>&1 | grep '^HDR=' | grep -c 'deadbeef')
[ "$onhdr" = 1 ] || fail "--trace did not beat set trace off"
rm -rf "$XDG_CONFIG_HOME"
XDG_CONFIG_HOME=/tmp/terat-claim-nohome
rm -rf /tmp/offagent

# A bad value must be refused rather than stored and read as neither.
if terat set trace yes >/tmp/trbad.txt 2>&1; then fail "set trace accepted an invalid value"; fi
grep -q 'on or off' /tmp/trbad.txt || fail "set trace did not explain the refusal: [$(cat /tmp/trbad.txt)]"
rm -rf "$XDG_CONFIG_HOME" /tmp/fakeagent
unset XDG_CONFIG_HOME

# 7. the transcript actually reaches the question: a question can only be
#    answered from the shell's own history if the history is sent.
if command -v tmux >/dev/null 2>&1; then
	cat > $D/pi <<'SH'
#!/bin/sh
cat >/tmp/q.txt
printf '{"type":"session","cwd":"/t"}\n'
printf '{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"ANSWER_OK"}]}}\n'
printf '{"type":"agent_end"}\n'
SH
	chmod +x $D/pi
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

# 14. TERAT_SPIN=inline draws the spinner on the question's line, not below it.
#     Two things must hold and both have been wrong here: the frame must not
#     overwrite the question (a leading \b erased its last character), and it
#     must not leave a blank line before the answer (wipe ends the line, so the
#     answer's own leading newline has to be skipped). A pty is used because
#     the spinner only draws on a terminal.
cat > /tmp/spinpty.py <<'PY'
# terat never prints the question: _terat_line does, so stand in for it. That is
# the only way to see whether the frame lands on the question's line or the next.
# A tiny screen model is used rather than the raw bytes because the failure that
# mattered here was cursor movement overwriting a character, which leaves the
# byte stream looking correct.
import os, pty, fcntl, termios, struct, select, sys, re

spin, terat = sys.argv[1], sys.argv[2]
q = "a question long enough to reach the right hand side of the terminal"

pid, fd = pty.fork()
if pid == 0:
    os.environ.update({"TERM": "xterm-256color", "TERAT_CMD": "/tmp/spinanswer.sh"})
    if spin != "-":
        os.environ["TERAT_SPIN"] = spin
    # inline leaves the question's line open for the frame; below ends it first
    sys.stdout.write(q if spin == "inline" else q + "\n")
    sys.stdout.flush()
    os.execv("/bin/sh", ["sh", terat, q])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 60, 0, 0))

buf = b""
while True:
    r, _, _ = select.select([fd], [], [], 0.15)
    if r:
        try:
            c = os.read(fd, 65536)
        except OSError:
            break
        if not c:
            break
        buf += c
    elif b"the answer" in buf:
        break
os.kill(pid, 9)

# escapes first, so the model only ever sees characters the eye would
text = re.sub(r"\x1b\[[0-9;?]*[a-zA-Z]", "", buf.decode("utf-8", "replace"))
# screen model: \n newline, \r column 0, \b back one, printable overwrites
rows, col = [[""]], 0
for ch in text:
    if ch == "\n":
        rows.append([""]); col = 0
    elif ch == "\r":
        col = 0
    elif ch == "\b":
        col = max(0, col - 1)
    elif ch.isprintable():
        r_ = rows[-1]
        while len(r_) <= col:
            r_.append(" ")
        r_[col] = ch
        col += 1
rows = ["".join(r) for r in rows]

raw = text

if spin == "inline":
    # the question must survive the frame: the bug was a \b that stepped back
    # onto its last character and erased it
    line = [r for r in rows if "a question long enough" in r]
    if not line:
        sys.exit("question line vanished: %r" % rows[:3])
    # the frame occupies the cell after the text; what must not happen is the
    # text itself being shortened, which is what a leading \b used to do
    if "terminal" not in line[0]:
        sys.exit("the spinner ate the end of the question: %r" % line[0][-30:])
    # the frame is rewritten in place, which is what keeps it on that line
    head = raw.split("\n")[0]
    if "\b" not in head:
        sys.exit("inline frames were not drawn in place: %r" % head[-40:])
    # and the answer starts on the next line, with no blank line between
    idx = [i for i, r in enumerate(rows) if "a question long enough" in r][0]
    nxt = rows[idx + 1] if idx + 1 < len(rows) else ""
    if nxt.strip() == "":
        sys.exit("inline left a blank line before the answer: %r" % rows[:4])
else:
    # below: the frame goes on the line after the question
    idx = [i for i, r in enumerate(rows) if "a question long enough" in r]
    if not idx:
        sys.exit("question line vanished: %r" % rows[:3])
    if not idx[0] + 1 < len(rows) or not rows[idx[0] + 1].strip():
        sys.exit("default spinner is not on its own line: %r" % rows[:4])
print("OK")
PY
cat > /tmp/spinanswer.sh <<'SH'
#!/bin/sh
cat >/dev/null
sleep 0.7
printf 'the answer\n'
SH
chmod +x /tmp/spinanswer.sh
if command -v python3 >/dev/null 2>&1; then
	verdict=$(cd /tmp && python3 /tmp/spinpty.py inline ~/Projects/terat/terat 2>&1)
	[ "$verdict" = OK ] || fail "inline spinner: $verdict"
	verdict=$(cd /tmp && python3 /tmp/spinpty.py - ~/Projects/terat/terat 2>&1)
	[ "$verdict" = OK ] || fail "default spinner: $verdict"
	note="$note+spin"
fi

# --- ACP ------------------------------------------------------------------
# The bridge is JSON-RPC on stdin and out, so these claims send frames and read
# frames. A stub agent stands in for a real one: the claims are about the
# protocol, and a model's opinion would make them slow and non-deterministic.
# TERAT_CMD replaces the whole command, which is what a stub needs.
cat >/tmp/acpstub.sh <<'SH'
#!/bin/sh
cat >/dev/null
printf 'STUB_ANSWER\n'
SH
chmod +x /tmp/acpstub.sh

acp_send() {
	printf '%s\n' "$@" |
		TERAT_CMD=/tmp/acpstub.sh XDG_CONFIG_HOME="$D/home" sh "$D/terat" acp 2>/dev/null
}

# initialize must answer version 1 and name this harness: the version check is
# the first thing a client does, and a wrong answer ends the conversation there.
acp_out=$(acp_send '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}')
case $acp_out in
*'"protocolVersion":1'*) ;;
*) fail "acp initialize did not answer protocolVersion 1: $acp_out" ;;
esac
case $acp_out in
*'"name":"terat"'*) ;;
*) fail "acp initialize did not name terat: $acp_out" ;;
esac
note="$note+acp-init"

# A full turn: the answer must arrive as an agent_message_chunk before the
# result, because that is where a client looks for the text.
acp_out=$(acp_send \
	'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}' \
	'{"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":"/tmp"}}' \
	'{"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{"sessionId":"sess_1","prompt":[{"type":"text","text":"say it"}]}}')
case $acp_out in
*'"sessionUpdate":"agent_message_chunk"'*STUB_ANSWER*) ;;
*) fail "acp prompt did not stream the answer: $acp_out" ;;
esac
case $acp_out in
*'"stopReason":"end_turn"'*) ;;
*) fail "acp prompt did not end the turn: $acp_out" ;;
esac
note="$note+acp-turn"

# STUB_ANSWER can only appear if the bridge ran an agent, and TERAT_CMD is read
# by the engine rather than the bridge - so the turn went through this script
# rather than being answered in the protocol layer.
case $acp_out in
*'"stopReason"'*) ;;
*) fail "acp did not reach the engine: $acp_out" ;;
esac
note="$note+acp-engine"

# Every frame must be a whole JSON object, and an answer holding a quote and a
# newline must survive escaping. Both are checked, because the braces alone are
# satisfied by a frame that silently drops what it could not escape.
cat >/tmp/acpesc.sh <<'SH'
#!/bin/sh
cat >/dev/null
printf 'a"b\nc\\d\n'
SH
chmod +x /tmp/acpesc.sh
acp_out=$(printf '%s\n' \
	'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}' \
	'{"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":"/tmp"}}' \
	'{"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{"sessionId":"sess_1","prompt":[{"type":"text","text":"q"}]}}' |
	TERAT_CMD=/tmp/acpesc.sh XDG_CONFIG_HOME="$D/home" sh "$D/terat" acp 2>/dev/null)
acp_bad=$(printf '%s\n' "$acp_out" | awk '!/^\{.*\}$/' | head -1)
[ -z "$acp_bad" ] || fail "acp produced a malformed frame: $acp_bad"
# The answer is `a"b` then newline then `c\d`. Escaped, it is a\"b\nc\\d, and the
# chunk must hold exactly that: a raw quote would have broken the frame above,
# and a raw newline would have split this line into two.
case $acp_out in
*'a\"b\nc\\d'*) ;;
*) fail "acp did not escape the answer: $(printf '%s' "$acp_out" | grep agent_message | head -1)" ;;
esac
note="$note+acp-esc"

# An unknown session must be an error. A client that mistypes an id has to be
# told, or it waits forever for a turn that will never start.
acp_out=$(acp_send \
	'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}' \
	'{"jsonrpc":"2.0","id":2,"method":"session/prompt","params":{"sessionId":"nope","prompt":[{"type":"text","text":"x"}]}}')
case $acp_out in
*'"error"'*'unknown session'*) ;;
*) fail "acp did not reject an unknown session: $acp_out" ;;
esac
note="$note+acp-err"

# A method we do not implement must say so by name. fs/* is the sharp case:
# advertising it and doing nothing would silently lose a client's edits.
acp_out=$(acp_send \
	'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}' \
	'{"jsonrpc":"2.0","id":2,"method":"fs/read_text_file","params":{"path":"/etc/passwd"}}')
case $acp_out in
*'-32601'*'fs/read_text_file'*) ;;
*) fail "acp did not refuse fs/read_text_file: $acp_out" ;;
esac
note="$note+acp-refuse"

# An id must come back with its type. A numeric id that gains quotes cannot be
# matched to its request, and a string id that loses them makes the frame not
# JSON at all - the official TCK failed exactly this way.
acp_out=$(acp_send '{"jsonrpc":"2.0","id":7,"method":"initialize","params":{"protocolVersion":1}}')
case $acp_out in
*'"id":7,'*) ;;
*) fail "acp did not echo a numeric id: $acp_out" ;;
esac
acp_out=$(acp_send '{"jsonrpc":"2.0","id":"abc","method":"initialize","params":{"protocolVersion":1}}')
case $acp_out in
*'"id":"abc",'*) ;;
*) fail "acp did not echo a string id quoted: $acp_out" ;;
esac
note="$note+acp-id"

# The spec's error codes are not interchangeable: -32002 is Resource not found
# and carries the id in data, while -32602 is a client mistake. A client
# distinguishes a stale session from a bad request by these codes alone.
acp_out=$(acp_send \
	'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}' \
	'{"jsonrpc":"2.0","id":2,"method":"session/prompt","params":{"sessionId":"nope","prompt":[{"type":"text","text":"x"}]}}')
case $acp_out in
*'-32002'*'"data":{"sessionId":"nope"'*) ;;
*) fail "acp used the wrong code for an unknown session: $acp_out" ;;
esac
# session/new without cwd is invalid params, not a session in the bridge's own
# directory: guessing the directory is the client's decision to make.
acp_out=$(acp_send \
	'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}' \
	'{"jsonrpc":"2.0","id":2,"method":"session/new","params":{"mcpServers":[]}}')
case $acp_out in
*'-32602'*'needs a cwd'*) ;;
*) fail "acp accepted session/new without a cwd: $acp_out" ;;
esac
# Nothing but initialize may come first: a client that opens a session before
# agreeing a protocol version has not been served, it has been guessed at.
acp_out=$(acp_send '{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/tmp"}}')
case $acp_out in
*'-32600'*'initialize'*) ;;
*) fail "acp served a request before initialize: $acp_out" ;;
esac
note="$note+acp-codes"

# A cancel must reach a turn that is still running, and the turn must end with
# `stopReason: cancelled` as a success result. A bridge that only noticed after
# the answer arrived would have nothing to stop, which is the GUI stop button.
cat >/tmp/acpslow.sh <<'SH'
#!/bin/sh
cat >/dev/null
sleep 20
printf 'TOO_LATE\n'
SH
chmod +x /tmp/acpslow.sh
acp_start=$(date +%s)
acp_out=$(
	{
		printf '%s\n' \
			'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}' \
			'{"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":"/tmp"}}' \
			'{"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{"sessionId":"sess_1","prompt":[{"type":"text","text":"slow"}]}}'
		sleep 2
		printf '%s\n' '{"jsonrpc":"2.0","method":"session/cancel","params":{"sessionId":"sess_1"}}'
		sleep 2
	} | TERAT_CMD=/tmp/acpslow.sh XDG_CONFIG_HOME="$D/home" sh "$D/terat" acp 2>/dev/null)
acp_end=$(date +%s)
case $acp_out in
*'"stopReason":"cancelled"'*) ;;
*) fail "acp did not cancel a running turn: $(printf '%s' "$acp_out" | tail -1)" ;;
esac
# The agent sleeps 20s. If the cancel did not reach it this claim would sit here
# until then, so the elapsed time is the proof that the turn was interrupted.
[ $((acp_end - acp_start)) -lt 15 ] ||
	fail "acp cancel did not interrupt the turn: took $((acp_end - acp_start))s"
note="$note+acp-cancel"

# A model switch is per session and must not rewrite the saved config: the
# bridge's caller did not ask for a new default. The value must be one the
# session advertised, so the claim reads the offered value out of the reply
# rather than inventing one the bridge is right to refuse.
acp_out=$(acp_send \
	'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}' \
	'{"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":"/tmp"}}')
acp_offer=$(printf '%s\n' "$acp_out" | sed -n 's/.*"options":\[{"value":"\([^"]*\)".*/\1/p' | head -1)
[ -n "$acp_offer" ] || fail "acp advertised no model to switch to: $acp_out"
acp_out=$(acp_send \
	'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}' \
	'{"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":"/tmp"}}' \
	"{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"session/set_config_option\",\"params\":{\"sessionId\":\"sess_1\",\"configId\":\"model\",\"value\":\"$acp_offer\"}}")
case $acp_out in
*"\"currentValue\":\"$acp_offer\""*) ;;
*) fail "acp did not accept an advertised model: $acp_out" ;;
esac
case $(cat "$D/home/terat/settings" 2>/dev/null) in
*model=$acp_offer*) fail "acp wrote the switched model into the saved config" ;;
esac
# A value that was never offered is the client's mistake, and answering as if
# it worked would leave the session asking a model that does not exist.
acp_out=$(acp_send \
	'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}' \
	'{"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":"/tmp"}}' \
	'{"jsonrpc":"2.0","id":3,"method":"session/set_config_option","params":{"sessionId":"sess_1","configId":"model","value":"_never_offered"}}')
case $acp_out in
*'-32602'*'unsupported value'*) ;;
*) fail "acp accepted an unadvertised model: $acp_out" ;;
esac
note="$note+acp-model"

# `terat acp` at a prompt is a question about acp, not a request to serve one.
# The tell is a pty: reading a terminal as JSON-RPC would eat keystrokes and
# answer nothing, so the bridge must refuse before it reads a frame.
if command -v script >/dev/null 2>&1; then
	acp_out=$(script -q /dev/null sh "$D/terat" acp 2>&1 </dev/null | tr -d '\r')
	case $acp_out in
	*'for a client, not a prompt'*) ;;
	*) fail "acp did not refuse a terminal: $acp_out" ;;
	esac
	note="$note+acp-tty"
fi

# Through a symlink, which is how terat is installed: a link in ~/.local/bin
# pointing into a checkout. $0 is then the link, so the helper is not beside it
# and the bridge used to work only when run from the checkout and fail from
# PATH - which is where a client runs it.
#
# Run from a neutral directory on purpose. The fallback `./terat-acp.awk` means a
# cwd holding the helper hides the bug entirely, which is how the first version
# of this claim passed against the broken build.
acp_neutral=$D/neutral
mkdir -p "$acp_neutral"
ln -sf "$D/terat" "$acp_neutral/terat" 2>/dev/null
if [ -L "$acp_neutral/terat" ]; then
	acp_out=$(cd "$acp_neutral" && printf '%s\n' \
		'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}' |
		TERAT_CMD=/tmp/acpstub.sh XDG_CONFIG_HOME="$D/home" \
			sh ./terat acp 2>&1)
	case $acp_out in
	*'"protocolVersion":1'*) ;;
	*) fail "acp failed when launched through a symlink: $acp_out" ;;
	esac
	note="$note+acp-symlink"
fi

# An agent that fails must arrive as a JSON-RPC error carrying the agent's own
# words, not as an assistant message. Merging stderr into the answer made an
# expired login look like the reply, with `end_turn`, so a client stored it.
cat >/tmp/acpfail.sh <<'SH'
#!/bin/sh
cat >/dev/null
printf 'AUTH EXPIRED: refresh failed\n' >&2
exit 3
SH
chmod +x /tmp/acpfail.sh
acp_out=$(printf '%s\n' \
	'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}' \
	'{"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":"/tmp"}}' \
	'{"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{"sessionId":"sess_1","prompt":[{"type":"text","text":"q"}]}}' |
	TERAT_CMD=/tmp/acpfail.sh XDG_CONFIG_HOME="$D/home" sh "$D/terat" acp 2>&1)
case $acp_out in
*'"error"'*'AUTH EXPIRED'*) ;;
*) fail "acp turned a failed agent into an answer: $acp_out" ;;
esac
case $acp_out in
*'"stopReason"'*) fail "acp gave a failed turn a stop reason: $acp_out" ;;
esac
note="$note+acp-fail"

# A healthy agent that also writes to stderr must still have only its stdout
# treated as the answer, or the diagnostic gets stored as the reply.
acp_out=$(printf '%s\n' \
	'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}' \
	'{"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":"/tmp"}}' \
	'{"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{"sessionId":"sess_1","prompt":[{"type":"text","text":"q"}]}}' |
	TERAT_CMD=/tmp/acpnoisy.sh XDG_CONFIG_HOME="$D/home" sh "$D/terat" acp 2>&1)
case $acp_out in
*'"text":"CLEAN_ANSWER"'*) ;;
*) fail "acp lost a healthy agent's answer: $acp_out" ;;
esac
case $acp_out in
*'NOISE_ON_STDERR'*) fail "acp let stderr into the answer: $acp_out" ;;
esac
note="$note+acp-stderr"

# A client must be able to choose the agent for its own session. ACP has no field
# for "which harness", so it is a config option under the `_` category the spec
# reserves for extensions; a client that ignores unknown categories still gets a
# working session on the saved agent.
cat >/tmp/acpwho.sh <<'SH'
#!/bin/sh
cat >/dev/null
printf 'ANSWERED_BY=%s\n' "${TERAT_AGENT:-unset}"
SH
chmod +x /tmp/acpwho.sh
acp_out=$(printf '%s\n' \
	'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}' \
	'{"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":"/tmp"}}' \
	'{"jsonrpc":"2.0","id":3,"method":"session/set_config_option","params":{"sessionId":"sess_1","configId":"_agent","value":"codex"}}' \
	'{"jsonrpc":"2.0","id":4,"method":"session/prompt","params":{"sessionId":"sess_1","prompt":[{"type":"text","text":"q"}]}}' |
	TERAT_CMD=/tmp/acpwho.sh XDG_CONFIG_HOME="$D/home" sh "$D/terat" acp 2>&1)
case $acp_out in
*'"id":"_agent"'*) ;;
*) fail "acp did not offer a way to pick the agent: $acp_out" ;;
esac
# Answering `codex` in the reply is not the same as codex doing the work: this
# asserts the name reached the process that answered.
case $acp_out in
*'ANSWERED_BY=codex'*) ;;
*) fail "acp did not switch the agent for the session: $acp_out" ;;
esac
# A name that is not an agent is refused rather than stored.
acp_out=$(printf '%s\n' \
	'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}' \
	'{"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":"/tmp"}}' \
	'{"jsonrpc":"2.0","id":3,"method":"session/set_config_option","params":{"sessionId":"sess_1","configId":"_agent","value":"not-an-agent"}}' |
	TERAT_CMD=/tmp/acpwho.sh XDG_CONFIG_HOME="$D/home" sh "$D/terat" acp 2>&1)
case $acp_out in
*'-32602'*'no such agent'*) ;;
*) fail "acp accepted an agent that does not exist: $acp_out" ;;
esac
note="$note+acp-agent"

# A client may put its next request on the wire while a turn is still running.
# The turn's poll reads the transport to catch a cancel, so a line it is not
# interested in has to be kept for the loop: dropping it lost the request
# silently, and the client waited forever for a reply nothing would send.
cat >/tmp/acpcount.sh <<'SH'
#!/bin/sh
cat >/dev/null
printf 'one answer\n'
SH
chmod +x /tmp/acpcount.sh
acp_out=$(printf '%s\n' \
	'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}' \
	'{"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":"/tmp"}}' \
	'{"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{"sessionId":"sess_1","prompt":[{"type":"text","text":"a"}]}}' \
	'{"jsonrpc":"2.0","id":4,"method":"session/prompt","params":{"sessionId":"sess_1","prompt":[{"type":"text","text":"b"}]}}' \
	'{"jsonrpc":"2.0","id":5,"method":"session/prompt","params":{"sessionId":"sess_1","prompt":[{"type":"text","text":"c"}]}}' |
	TERAT_CMD=/tmp/acpcount.sh XDG_CONFIG_HOME="$D/home" sh "$D/terat" acp 2>&1)
acp_n=0
for acp_id in 3 4 5; do
	case $acp_out in
	*"\"id\":$acp_id,\"result\":{\"stopReason\""*) acp_n=$((acp_n + 1)) ;;
	esac
done
[ "$acp_n" -eq 3 ] || fail "acp answered only $acp_n of 3 pipelined requests"
note="$note+acp-pipeline"

# A machine with nowhere to write a settings file must still be configurable.
# This is what makes `docker run -e` work on a fresh image with no writable home.
cat >/tmp/acpcfgpeek.sh <<'SH'
#!/bin/sh
cat >/dev/null
printf 'ENV_CFG=%s\n' "$(cat "$PI_CODING_AGENT_DIR/models.json" 2>/dev/null)"
SH
chmod +x /tmp/acpcfgpeek.sh
acp_out=$(printf 'q\n' |
	HOME="$D/nowhere" XDG_CONFIG_HOME="$D/nowhere" \
	TERAT_URL=http://env-host:1234/v1 TERAT_KEY=ENVKEY TERAT_MODEL=env/model-x \
	TERAT_CMD=/tmp/acpcfgpeek.sh TERAT_THREAD="$D/envthread" \
	sh "$D/terat" pi -- 2>&1)
# The URL, the key and the model all have to land, because a config with two of
# the three is a machine that looks configured and cannot answer.
case $acp_out in
*'http://env-host:1234/v1'*) ;;
*) fail "env did not configure the endpoint: $acp_out" ;;
esac
case $acp_out in
*'ENVKEY'*) ;;
*) fail "env did not configure the key: $acp_out" ;;
esac
case $acp_out in
*'env/model-x'*) ;;
*) fail "env did not configure the model: $acp_out" ;;
esac
note="$note+env-config"

echo "  note=$note"
echo RESULT=PASS