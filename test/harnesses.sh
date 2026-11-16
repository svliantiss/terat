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

# grok takes the prompt as argv and prints the transcript as json lines.
# Written with printf so the sed pattern keeps its backslashes exactly, which a
# heredoc or a double-quoted string would eat one layer at a time.
{
	printf '#!/bin/sh\n'
	printf 'GROK_API_KEY=%s GROK_BASE_URL=%s/v1 GROK_MODEL=%s \\\n' "$K" "$H" "$M"
	printf '\tgrok -p "$(cat)" 2>/dev/null \\\n'
	printf '%s\n' "	| sed -n 's/^{\"role\":\"assistant\",\"content\":\"\\(.*\\)\"}\$/\\1/p' | tail -1"
} > ~/.local/bin/grok-ask
chmod +x ~/.local/bin/claude-ask ~/.local/bin/grok-ask

mkdir -p ~/P && cp -R /src/. ~/P/ && chmod +x ~/P/tert
export ROUTER_KEY="$K"
cd /tmp/w

row() {
	name=$1; cmd=$2; want=$3
	ans=$(TERAT_CMD="$cmd" ~/P/tert "Reply with exactly: $want" </dev/null 2>&1 | tail -1)
	case $ans in *"$want"*) v=ok ;; *) v=FAIL ;; esac
	printf '  %-9s %-4s %s\n' "$name" "$v" "$(printf '%s' "$ans" | cut -c1-54)"
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
	row grok     'grok-ask'                           R1
	row dsh      'dsh --profile headless'             R1
else
	row dsh      'dsh --profile headless'             R2
	row grok     'grok-ask'                           R2
	row codex    'codex exec --skip-git-repo-check'   R2
	row claude   'claude-ask'                         R2
	row opencode 'opencode run'                       R2
	row pi       'pi -p --mode json'                  R2
fi
