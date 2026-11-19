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

echo "  note=$note"
echo RESULT=PASS