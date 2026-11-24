# Harnesses

How each agent is called, where its endpoint goes, and how a trace reaches it.
Everything here was measured against the real binary, not read off help text.

## The two tables

`terat`'s agent differences live in `agent_cmd`, `agent_name` and one config
`case`. That is the whole surface — a wrapper script per agent, or a `case`
scattered through the run, is the version that rots.

| agent | asks it with | `@file` | url/key reaches it through | `--trace` through |
|---|---|---|---|---|
| `pi` | `pi -p --mode json` (default) | yes | `PI_CODING_AGENT_DIR` → `models.json` | `-e terat-trace.js` |
| `claude` | `claude -p` | yes | `ANTHROPIC_BASE_URL`, `ANTHROPIC_API_KEY` | `ANTHROPIC_CUSTOM_HEADERS` |
| `codex` | `codex exec --skip-git-repo-check` | yes | `-c key=value` overrides | `-c …env_http_headers.traceparent` |
| `opencode` | `opencode run` | yes | `OPENCODE_CONFIG_DIR` → `opencode.json` | `options.headers` |
| `grok` | `grok -p {}` | yes | `GROK_BASE_URL`, `GROK_API_KEY` | — cannot join |
| `dsh` | `dsh --profile headless {}` | yes | `DSH_HOME` → profile patch | `headers:` in the patch |

The tracing column is a column because it is the same problem once more: five
agents carry a `traceparent` five different ways, and the sixth has no way at all.
It is not one mechanism applied six times. `-e` loads a JS module and only `pi`
has one; handing it to `claude` is `error: unknown option '-e'`.

## Harnesses that want the question as an argument

`grok -p` and `dsh --profile headless` will not read the question from stdin: they
take it as an argument and refuse to start otherwise. Put `{}` where the question
goes:

```sh
TERAT_CMD='grok -p {}' terat 'what changed in this diff?'
TERAT_CMD='dsh --profile headless {}' terat 'why is the build failing?'
```

The argument is the whole transcript — question, earlier turns, attached files —
because a task-style CLI takes a single prompt string and there is nowhere else to
put them. It is one argument no matter how many words or newlines it has, and
nothing in it is executed.

Without the placeholder the command runs exactly as written and the question
arrives on stdin.

`TERAT_CMD` is word-split, so a command at a path with spaces needs a wrapper on
`PATH` rather than quotes.

The trap in this area: a harness that does not understand how it is being called
still *starts*, and fails in a way that looks like terat. `grok -p` with no
argument prints "option '-p, --prompt <prompt>' argument missing" and discards
piped stdin silently; `dsh` says "a task is required". Neither reads stdin, and
neither says so in its help text.

## Wiring each one in

The six named agents do this for you: `terat set url`/`key`/`model` generates
what each one needs. The shapes below are what that generation produces, and are
worth knowing if you would rather keep your own config:

```sh
# codex: 0.169 rejects wire_api = "chat" outright and speaks only the responses
# API. terat passes these as `-c` overrides, which codex accepts on the command
# line; the equivalent in ~/.codex/config.toml is:
#   model = "<model>"
#   model_provider = "terat"
#   [model_providers.terat]
#   name = "terat"
#   base_url = "https://.../v1"
#   env_key = "ROUTER_KEY"
#   wire_api = "responses"

# claude is an Anthropic-shaped client, so it needs its own base URL and key and
# a model id the endpoint actually serves. terat exports these for the run only.
# Note the base URL has no /v1 on the end: claude appends /v1/messages itself.
#   ANTHROPIC_BASE_URL=https://...
#   ANTHROPIC_API_KEY=$ROUTER_KEY
#   claude -p --model <model>

# dsh reads its provider from the profile patch layer. Note that DSH_HOME is not
# always ~/.dsh (on macOS this build uses
# "~/Library/Application Support/gnts.dev/harness"), and edit the profile there:
#   - id: llm-pi-ai
#     config:
#       providers:
#         myrouter:
#           apiKeyEnv: ROUTER_KEY
#           api: openai-completions
#           baseURL: https://.../v1
#           models: [{ id: <model> }]
#   - id: agent-default-model
#     config: { provider: myrouter, model: <model> }

# opencode's header lives in the ai-sdk options object it already reads:
#   "provider": { "terat": { "options": {
#     "baseURL": "https://.../v1", "apiKey": "...",
#     "headers": { "traceparent": "00-<trace>-<span>-01" } } } }
```

Six traps that cost an afternoon each:

- **Do not export `ANTHROPIC_API_KEY` or `OPENAI_API_KEY` while using `pi`.**
  pi sees either and stops reading its own `models.json`, then calls that
  provider directly and fails. This is why the credential is scoped to the agent
  that wants it: `terat claude` exports `ANTHROPIC_API_KEY` for that run only,
  and `terat pi` never sees it. Verified rather than assumed — a key configured
  for claude does not appear in pi's environment.
- **claude's base URL must not end in `/v1`.** It appends `/v1/messages` itself,
  so `https://host/v1` becomes `/v1/v1/messages` and the failure is reported as
  "the selected model may not exist or you may not have access to it" — an error
  about the model, caused by the URL. `terat` strips the suffix for claude only,
  since `grok` and `opencode` do want it.
- **A dsh provider names its key, it does not hold one.** `apiKeyEnv: TERAT_KEY`
  is read; a literal `apiKey: sk-...` is silently ignored and dsh then reports
  `PI_AI_ERROR: No API key for provider: terat` — which reads like a bad key
  rather than a field dsh does not know. The named variable must also be exported
  to the child. Verified both ways in the container: `apiKeyEnv` answers,
  `apiKey` fails.

## What went wrong, so you do not

  pi sees either and stops reading its own `models.json`, then calls that
  provider directly and fails. This is why the credential is scoped to the agent
  that wants it: `terat claude` exports `ANTHROPIC_API_KEY` for that run only,
  and `terat pi` never sees it. Verified rather than assumed — a key configured
  for claude does not appear in pi's environment.
- **claude's base URL must not end in `/v1`.** It appends `/v1/messages` itself,
  so `https://host/v1` becomes `/v1/v1/messages` and the failure is reported as
  "the selected model may not exist or you may not have access to it" — an error
  about the model, caused by the URL. `terat` strips the suffix for claude only,
  since `grok` and `opencode` do want it.
- **A dsh provider names its key, it does not hold one.** `apiKeyEnv: TERAT_KEY`
  is read; a literal `apiKey: sk-...` is silently ignored and dsh then reports
  `PI_AI_ERROR: No API key for provider: terat` — which reads like a bad key
  rather than a field dsh does not know. The named variable must also be exported
  to the child. Verified both ways in the container: `apiKeyEnv` answers,
  `apiKey` fails.
- **A dsh install can be internally inconsistent.** `npm i -g @deepseek-ai/dsh`
  cannot resolve a pre-release at all, and pinning an old one (0.1.5-rc.2) pulls
  a *newer* `dsh-base` whose `dsh-sandbox-local` is then missing: dsh dies at
  boot with `plugin(s) failed to load` before it ever reads a key. Install a
  line that agrees with itself, e.g. `@deepseek-ai/dsh@0.2.2-rc.3`.
- **A `${var:+word}` with a brace in the word leaks a brace.** The natural way to
  write an optional JSON fragment is
  `"${traceparent:+,\"headers\":{…}}"`, and under `sh` it expands to a bare `}`
  when the variable is unset. One stray brace in `opencode.json` and opencode
  cannot parse its own config, on every plain run — the tracing path looked fine
  and only the untraced one was broken. Build the fragment with an explicit `if`
  instead, and let the test parse the generated file rather than search it.
- **A model that cannot see pictures is usually a config that never said it
  could.** Three of the six decide *before asking* whether to attach an image,
  from the model entry: `"input":["text","image"]` for pi and dsh,
  `"modalities":{"input":["text","image"]}` for opencode. Omit it and the entry
  is text-only by default, the file is dropped from the request, and the model
  answers that it cannot see images — a prompt that reads exactly like the
  model's own limitation. `terat` writes all three. Verified with a picture
  whose text is known: without the field the answer is "I'm unable to view the
  image", with it the text is read back exactly.

  The other three need no such field and still differ, which `terat attach`
  prints rather than leaves to be discovered one screenshot at a time:

  | agent | how an image reaches the model |
  | --- | --- |
  | `pi`, `opencode`, `dsh` | its own `read` attaches it, gated on the model's `input` |
  | `claude`, `codex` | passed through directly, no capability field |
  | `grok` | its `view_file` renders images |

  All six read a known code out of a PNG when asked normally. `grok` is the one
  that will also hand back raw IDAT bytes if you explicitly tell it to use
  `view_file` on the path — the same question, asked as a command rather than a
  question, gets a worse answer.


Tested and not usable: `cursor-agent` needs a Cursor account and draws a TUI;
`gemini` wants a Google key and has no OpenAI-compatible mode; `aider` failed on an unrelated
scipy build; `sgpt` ships without its `click` dependency; `mods` would not
accept a custom endpoint. `goose` on Homebrew is a database-migration tool, and
`cc` is a compiler.

Sourcing `terat.zsh` is the whole install for ask mode: it runs the `terat` that
sits beside it, so the symlink is only needed if you want to type `terat` at the
prompt yourself.
