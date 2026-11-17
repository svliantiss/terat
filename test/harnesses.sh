#!/bin/sh
# The six harnesses terat claims to work with, through terat, against a real
# model, in a container. Run it with a key for any OpenAI-compatible endpoint:
#
#   ROUTER_KEY=... ENDPOINT=https://router.example.com \
#     IMAGE=terat-harness:all sh test/harnesses.sh [1|2]
#
# Nothing is baked into the image: configs are written from the environment at
# run time. Pass 1 runs the list forwards, pass 2 backwards, so a failure that
# depends on a warm cache or a leftover file shows up as a difference.
set -u
K=${ROUTER_KEY:?set ROUTER_KEY to a key for ENDPOINT}
H=${ENDPOINT:-https://router.example.com}
M=${MODEL:-some/model}
export PATH=$HOME/.local/bin:$PATH
export TERAT_MAX=${TERAT_MAX:-300}
mkdir -p ~/.local/bin /tmp/w

# pi reads providers from models.json. Note that it must NOT see an
# ANTHROPIC_API_KEY in the environment: pi takes that as "use Anthropic", stops
# reading its own models.json and 401s against api.anthropic.com. Every harness
# below therefore gets its credential in a wrapper of its own instead of through
# a shared export.
mkdir -p ~/.pi/agent/sessions
cat > ~/.pi/agent/models.json <<EOF
{ "providers": { "router": {
  "baseUrl": "$H/v1", "api": "openai-completions", "apiKey": "$K",
  "models": [ { "id": "$M", "name": "DeepSeek V4.1 Flash" } ] } } }
EOF
chmod 600 ~/.pi/agent/models.json

# opencode reads its provider from the working directory.
cat > /tmp/w/opencode.json <<EOF
{ "\$schema": "https://opencode.ai/config.json",
  "provider": { "router": { "npm": "@ai-sdk/openai-compatible", "name": "router",
    "options": { "baseURL": "$H/v1", "apiKey": "$K" },
    "models": { "$M": { "name": "DeepSeek V4.1 Flash" } } } },
  "model": "router/$M" }
EOF
chmod 600 /tmp/w/opencode.json

cat > ~/.local/bin/claude-ask <<EOF
#!/bin/sh
ANTHROPIC_BASE_URL=$H ANTHROPIC_API_KEY=$K \\
	exec claude -p --model $M "\$@"
EOF

# codex 0.169 rejects wire_api = "chat" and speaks only the responses API.
mkdir -p ~/.codex
cat > ~/.codex/config.toml <<EOF
model = "$M"
model_provider = "router"
[model_providers.router]
name = "router"
base_url = "$H/v1"
env_key = "ROUTER_KEY"
wire_api = "responses"
EOF

# dsh needs a provider route and a default model in its profile patch layer, and
# its DSH_HOME defaults to ~/.dsh where it is not set. Both grok and dsh take the
# question as an argv argument rather than stdin, which is what `{}` in
# TERAT_CMD is for: no wrapper script is needed for either.
mkdir -p ~/.dsh/profiles/headless
cat > ~/.dsh/profiles/headless/cordis.patch.yml <<EOF
- id: llm-pi-ai
  config:
    providers:
      router:
        displayName: router
        apiKeyEnv: ROUTER_KEY
        api: openai-completions
        baseURL: $H/v1
        models:
          - id: $M
            name: DeepSeek V4.1 Flash
- id: agent-default-model
  config:
    provider: router
    model: $M
EOF

chmod +x ~/.local/bin/claude-ask
export GROK_API_KEY="$K" GROK_BASE_URL="$H/v1" GROK_MODEL="$M"
mkdir -p ~/P && cp -R /src/. ~/P/ && chmod +x ~/P/terat
export ROUTER_KEY="$K"
cd /tmp/w

printf 'the code is TANGERINE\n' >/tmp/code.txt

row() {
	name=$1; cmd=$2; want=$3
	# Every row gets its own thread. terat keys the thread on $PPID, which is the
	# same for every row here, so without this each harness would inherit the
	# questions asked of the ones before it and could answer those instead.
	export TERAT_THREAD=/tmp/thread.$name
	rm -f "$TERAT_THREAD"
	ans=$(TERAT_CMD="$cmd" ~/P/terat "Reply with exactly: $want" </dev/null 2>&1 | tail -1)
	case $ans in *"$want"*) v=ok ;; *) v=FAIL ;; esac
	printf '  %-9s %-4s %s\n' "$name" "$v" "$(printf '%s' "$ans" | cut -c1-54)"
	# The same harness must also see a file it is never given a path to, which
	# is what inlining buys: @file used to work only where the harness itself
	# understood the syntax.
	if [ "${4:-}" != nofile ]; then
		rm -f "$TERAT_THREAD"
		ans=$(TERAT_CMD="$cmd" ~/P/terat 'what is the code? one word only' @/tmp/code.txt </dev/null 2>&1 | tail -1)
		case $ans in
		*TANGERINE*) af=ok ;;
		*) af=FAIL ;;
		esac
		printf '  %-9s %-4s %s\n' "" "" "@file $af"
	fi
}

echo "  distro: $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")"
echo "  pass:   ${1:-1}"
echo '  HARNESS   RESULT  ANSWER'
echo '  --------- ------  ----------------------------------------------------'
if [ "${1:-1}" = 1 ]; then
	row pi       'pi -p --mode json'                  R1
	row opencode 'opencode run'                       R1
	row claude   'claude-ask'                         R1
	row codex    'codex exec --skip-git-repo-check'   R1
	row grok     'grok -p {}'                         R1
	row dsh      'dsh --profile headless {}'          R1
else
	row dsh      'dsh --profile headless {}'          R2
	row grok     'grok -p {}'                         R2
	row codex    'codex exec --skip-git-repo-check'   R2
	row claude   'claude-ask'                         R2
	row opencode 'opencode run'                       R2
	row pi       'pi -p --mode json'                  R2
fi

# The piped path is only half the product. Drive one harness through the real
# prompt: the line becomes the glyph, the answer comes back labelled, and the
# prompt is ready again for the next question.
if [ "${TTYCMD:-}" != none ] && command -v tmux >/dev/null 2>&1 &&
	command -v zsh >/dev/null 2>&1; then
	ptycmd=${TTYCMD:-pi -p --mode json}
	rm -f ~/.zshrc
	touch ~/.zshrc
	{
		echo "export PATH=$HOME/.local/bin:\$PATH"
		echo "export TERAT_CMD='$ptycmd'"
		echo "export ROUTER_KEY=$ROUTER_KEY"
		echo "export GROK_API_KEY=${GROK_API_KEY:-} GROK_BASE_URL=${GROK_BASE_URL:-} GROK_MODEL=${GROK_MODEL:-}"
		echo "source ~/P/terat.zsh"
	} >>~/.zshrc
	tmux kill-server 2>/dev/null
	tmux new-session -d -s P -x 100 -y 24 "zsh -i"
	i=0
	while [ $i -lt 30 ]; do
		sleep 1
		tmux capture-pane -pt P 2>/dev/null | grep -q '%' && break
		i=$((i + 1))
	done
	tmux send-keys -t P '@Reply with exactly: PTYOK' Enter
	i=0
	while [ $i -lt 120 ]; do
		sleep 1
		tmux capture-pane -pt P 2>/dev/null | grep -q 'Pi: PTYOK' && break
		i=$((i + 1))
	done
	echo
	echo '  pty:'
	tmux capture-pane -pt P 2>/dev/null | grep -E '🟅|Pi:|terat:' | tail -3 | sed 's/^/    /'
	tmux kill-server 2>/dev/null
fi
