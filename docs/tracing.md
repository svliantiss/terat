# Tracing

A question, the model calls it causes and the router's own ledger are separate
records. One trace id joins them, so `terat --trace` is how a run becomes
findable afterwards.


Three ways in, because the three moments differ: `terat --trace '…'` for one
question, `Ctrl+X t` in ask mode for the session you are already in, and
`terat set trace on` for everything from now on. The session toggle beats the
saved default — a key that loses to a file is not a toggle. The flag exists
because the interesting runs are the irregular ones — the
build that failed once, the answer worth keeping — and exporting a variable for
those is how they end up untraced. `set trace off` stops it even with a collector
configured; a setting the run ignores is worse than no setting.

One question is one trace, and one id is shared by the model request and the
span post, so the request that caused the work can be found from either side.
That only holds because `--trace` mints the id *before* propagation: minted
later, the spans get an id of their own and the two records never meet.

Set `TERAT_OTLP` and each question is sent as one OpenTelemetry trace. It is off
until you do, and there is nothing to run alongside it — no collector, no agent,
no background process:

```sh
export TERAT_OTLP=https://api.lmnr.ai:443/v1/traces     # Laminar, OTLP/HTTP/json
export TERAT_OTLP_KEY=pk_...                            # project API key
```

Both can live in a `.env` next to the script instead of in `~/.zshrc`, and
`terat` reads it itself — not only `terat.zsh`. A container or a bare VPS has no
shell hook at all, and tracing that silently does not happen there is worse than
none. The file is parsed rather than sourced: a file kept for one secret should
not be able to run commands. Only `TERAT_OTLP` and `TERAT_OTLP_KEY` are taken. A
value already set in the environment wins, so a one-off `TERAT_OTLP=... terat`
still overrides the file. Keep `.env` out of git — the repo
gitignores it.

Self-hosted Laminar here is `https://otlp.example.com/v1/traces`, and its UI lives
at `https://lm.example.com` behind HTTP basic auth.

### When a trace does not arrive

The post is fire-and-forget by default, on purpose: a collector being down must
never delay a prompt. The cost is that a wrong key is silent. Turn on the log
when you need to know:

```sh
TERAT_OTLP_DEBUG=1 terat 'why is the build failing?'
tail -1 "$TMPDIR/terat.otlp.log"     # "… 200 https://…/v1/traces"
```

Set it to a path to log elsewhere. The log gets the status, the URL, and the
response body, so a rejection explains itself. What the codes mean:

| Code | Meaning |
| --- | --- |
| `200` | accepted and enqueued |
| `401` | bad or missing key — the body is checked *after* auth, so this masks other faults |
| `400` | body rejected; the response names the offending field |
| `415` | wrong `Content-Type`; the server reads anything not `application/json` as protobuf |
| `000` | curl could not connect — DNS or network, not auth |

A `400` is worth reading before touching anything: `Failed to decode
ExportTraceServiceRequest: OTLP/JSON decode failed: invalid trace_id: not hex or
base64` is a format complaint, not a reason to change the span shape.

Guard the key, not the endpoint: `[ -n "$TERAT_OTLP_KEY" ] && export ...`, or
put it in a file you do not commit.

One trace per question, one root span plus a child per model turn and per tool
call, so a run that created a file and then listed it shows both:

```
terat.ask                                  13.4s
├── chat some/model-…        6.7s    1036 in / 117 out
├── tool write                               3ms
├── tool bash                               12ms
└── chat some/model-…        3.3s     192 in /  31 out
```

The numbers are not estimates. Every field comes from the same `--mode json`
event stream the answer came from — token counts and the model name from each
`message_end`, durations from `tool_execution_end`, the working directory from
`session` — so the trace cannot drift from what actually ran. Spans carry the
`gen_ai.*` attributes and `lmnr.span.type` that Laminar reads, which makes the
token and cost panels work without a Laminar SDK.

### Why a cost panel can still read `$0.00`

The cost on a span is the cost **pi** computed for that turn, taken from the
`cost` block of its own `message_end`. terat does not price tokens itself: a
price table in a shell script would go stale, and it would disagree with the one
tool that actually knows what was billed.

pi can only price a turn if it has a price for the model. `~/.pi/agent/models.json`
carries a `cost` block per model, and for a subscription or a custom provider it
is all zeroes — which is what `some/model`
looks like:

```json
"cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 }
```

So the span shows `$0.00` because pi reported `$0.00`, not because the panel is
broken. A metered provider with real prices in that block fills the panel in
without any change here. To check whether a zero is real:

```sh
pi -p --mode json 'say hi' </dev/null | grep -o '"cost":{[^}]*}'
```

Cache reads are sent as `gen_ai.usage.cache_read_input_tokens` and count toward
the span's tokens even when the price is zero — on a long conversation they are
usually most of the tokens, so leaving them out understates the size of the run.

Which attribute holds what is not obvious, and guessing it wrong is silent — the
span renders, the panel is just empty:

| Panel | Attribute | Shape |
| --- | --- | --- |
| Span Input / Output | `lmnr.span.input`, `lmnr.span.output` | JSON array of `{role, content}` |
| LLM Messages | `gen_ai.input.messages`, `gen_ai.output.messages` | same |
| Span Input / Output on a tool | `gen_ai.tool.call.arguments`, `.result` | JSON |

`gen_ai.prompt.0.content` is the older path and does not fill those panels. Two
traps worth knowing: the values are **JSON strings**, and a bare string parses
to a string rather than a message, so the array is what makes them render; and
tool arguments are only read on spans typed `TOOL`, so a tool span typed
`DEFAULT` shows its name and nothing else.

How it is built, and why:

- **OTLP/HTTP/json, not gRPC.** The payload is JSON posted with `curl`. That
  keeps the "works from a fresh install" promise: no SDK, no protobuf encoder,
  no runtime. Laminar accepts all three transports; gRPC is faster, JSON is the
  one that needs nothing installed.
- **Built by `awk`, from the log.** `terat-trace.awk` turns the event stream
  into spans. `awk` is on every Unix, so tracing adds no dependency to a script
  that is otherwise plain `sh`.
- **Backgrounded, after the answer.** The POST runs in a subshell after the
  answer is printed. A dead collector, a bad key or no network costs you nothing
  but the trace: verified to return the same answer, at the same speed, with the
  endpoint pointed at a closed port.
- **Failures are traced too.** A run that errored, or that went quiet for
  `TERAT_MAX` seconds with no tool running, still posts what it has: the question, the turns
  and tool calls that did happen, and no invented completion. These were the one
  class of run that produced no trace at all, which is backwards — a question
  that failed is the one worth looking at. A run that produced no events
  whatsoever has nothing to build a span from, and is still silent.
- **Silent when it cannot work.** No `curl`, no `awk`, an unwritable temp
  directory or an empty event stream all mean no trace, never a broken prompt.
- **A real `/v1/traces` path.** Unlike the OTel HTTP exporters, the path is not
  appended for you — put it in `TERAT_OTLP`, as above.

`terat-trace.awk` is the only file that knows what a span is. `terat` just runs
it and posts the result, so tracing can be deleted without touching the answer
path, and the answer path can be changed without touching tracing.

### Joining a trace to the router's ledger

The gateway already records every call it makes — model, tokens, cost, latency,
in `requests` and `agent_messages`. What it cannot record is the part that never
leaves the machine: which tools ran, in what order, from which directory, and
what was actually asked. Both halves are useful, and by default they share no
identifier.

A W3C `traceparent` fixes that. router reads `traceparent` and stores its trace
id as `requests.trace_id`; `terat` also uses that id for the OTLP spans. One
value then finds the same work in Laminar and in the router:

```sh
terat set trace on        # or: terat --trace
```

`terat` mints the id itself, so there is nothing to export by hand. `--trace`
turns it on for one question, `terat set trace on` for every question after it,
and `Ctrl+X t` at the prompt toggles the session and says which way it went. An
id you do supply wins: `TERAT_TRACE_ID` in the environment is used as-is, which is
what makes a wrapper or a batch job able to put many questions under one trace.

Every agent carries the header differently, and none of it is guessable. The one
thing all six do *not* share is pi's mechanism: `-e` loads a JS module into pi,
and appending it to the others is not a no-op — `claude` answers
`error: unknown option '-e'` and `opencode` reads the flag as its own, so asking
for a trace broke two agents outright. Each therefore gets the header where that
agent actually reads it:

| agent | how the header reaches the request |
| --- | --- |
| `pi` | `-e terat-trace.js`, loaded for that run only |
| `claude` | `ANTHROPIC_CUSTOM_HEADERS="traceparent: …"` |
| `codex` | `-c model_providers.terat.env_http_headers.traceparent=TERAT_TRACEPARENT` |
| `opencode` | `options.headers` in the generated `opencode.json` |
| `dsh` | `headers:` in the generated `profiles/headless/cordis.patch.yml` |
| `grok` | nothing — see below |

The id is minted *before* the per-agent settings are applied, because four of the
five that can join read it there — two write it into a generated file, two export
it. Minting it later left the generated files with no id in them and the
propagation silently absent: the trace posted, the span looked right, and the
router had never heard of it.

`grok` is the one agent that cannot join. It has no header option, no field in
`config.toml`, no environment hook it documents, and nothing in its bundle reads
`traceparent` — so it can post a span and cannot correlate the request. Ask it for
a trace and you get the span half of the join and not the ledger half.

For `pi`, the extension registers the header against a provider *name*, and a name
that does not match the one in `models.json` is not an error: the header simply
never goes out. terat's generated config calls its provider `terat`; only a
hand-written router setup uses the other name. That mismatch was silent once and
is now asserted.

That indirection for pi is deliberate, and worth keeping even though the other
agents write the header into a config. pi resolves provider headers strictly: a
header value that works out to nothing is a fatal error, not a skipped header. So
the obvious implementation — a `traceparent` entry in `models.json` — breaks every
plain `pi` on any machine where `TERAT_TRACE_ID` is not exported, which is every
machine but yours, and contradicts the point of installing one package. Measured,
with the variable absent:

```
API key auth failed for provider router: Failed to resolve provider
header "traceparent" from environment variables: TERAT_TRACE_ID
```

Loading it per run means there is no state to forget. `models.json` is never
edited and `pi` on its own stays exactly as it was. Confirmed both ways: with the
variables set the id reaches the router, and with them absent `pi` runs normally
and sends no `traceparent` at all. The two that write a config get theirs in a
directory that exists only for that run, so nothing there is remembered either.

This is optional in the same sense as `TERAT_OTLP`: nothing is propagated unless
tracing is on, and tracing without `TERAT_OTLP` is still useful, because the join
lives in router's own database rather than in a trace backend.

### Which model answers

With no settings at all, `terat` runs whatever `pi -p` resolves to, so the model
stays pi's business. On a machine where Passy Me is running, its local router is
the route that uses a subscription rather than a metered key. Either point pi at
it by hand:

```jsonc
// ~/.pi/agent/models.json
"router": {
  "baseUrl": "https://router.example.com/v1",
  "api": "openai-completions",
  "apiKey": "router_...",
  "models": [{ "id": "some/model" }]
}
```

```jsonc
// ~/.pi/agent/settings.json
"defaultProvider": "router",
"defaultModel": "some/model"
```

Or let terat write those two files for the run, which is what this does:

```sh
terat set url https://router.example.com/v1
terat set key router_...
terat set model some/model
```

Then `pi -p` routes there by default and `terat` needs no change. Check it with
`pi --list-models`, or ask `terat` and watch which route is used in the pi log.
A metered key (`api.passy.ai`) answers as the same model family but bills per
token; the subscription ids end in `-subscription` and only exist on the router.

A route that works for one agent does not always work for another: claude speaks
the Anthropic Messages API and needs a model id the endpoint serves under that
API (`passy/aws-bedrock/claude-sonnet-4-6`, say), where pi, grok and opencode
speak the OpenAI one. Per-agent settings are the same file, so switching agent
means switching model too.

### Other harnesses

`TERAT_CMD` takes any command that reads the question on stdin and writes the
answer on stdout, so a harness that works that way needs nothing else:

```sh
TERAT_CMD='some-agent -p' terat 'why is the build failing?'
```

What you get back depends on how much the command says. `pi --mode json` reports
each model turn and tool call, so its traces have the full span tree. A command
that prints plain text produces one root span with the question, the answer, the
directory and the real elapsed time — no children, because there is no event
stream to read them from. Both are traced; neither is guessed at.

Two limits are worth knowing before reaching for a different harness:

- **The question goes in on stdin.** A harness that wants the task as an
  argument instead will see an empty prompt. Wrapping it is a one-line script
  that reads stdin and passes it as an argument:
  `task=$(cat); exec other-agent "$task"`.
- **Failures are reported from stderr.** If the command prints nothing usable,
  `terat` prints the first non-empty line the command wrote to stderr, so a
  missing key or a bad flag is visible instead of appearing as an empty answer.

Each of the six named agents has been exercised end to end — answering a real
question through a router — rather than only `pi`. Five were checked on this
machine; `dsh` was checked in the container, which is also where its
`apiKeyEnv`-versus-`apiKey` trap was found. That is what keeps the per-agent
table honest: every row was run, and the two mistakes in it (claude's base URL,
dsh's key field) were only visible by running it.
