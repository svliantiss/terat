# ACP compatibility and infra fit

Two questions, answered with measurements rather than intent:

1. **Is terat properly ACP compatible?**
2. **Is it flexible enough to run agents as infrastructure — for a dev on a laptop
   and for a box with no writable disk?**

Everything below was run against this checkout. Where something is missing, it
says so, because a compatibility doc that only lists wins is marketing.

---

## 1. ACP compatibility

### Measured result

```
$ uvx --from git+https://github.com/agentclientprotocol/acp-tck@v0.5.0 \
    acp-tck -- sh terat acp

1 failed, 66 passed, 83 skipped
```

The single failure is `ACP-SESSION-004`, the **advisory** MCP test. The 83 skips
are almost entirely capability-gated: the kit only runs a test when the agent
advertises the capability. That is the honest way to be compatible — an agent
that claims less is tested on less, and never on a promise it did not make.

### What is implemented

| Method | State |
| --- | --- |
| `initialize` | returns protocol v1, honest capabilities |
| `session/new` | requires `cwd`; offers model + agent selectors |
| `session/prompt` | streams `user_message_chunk` → `agent_message_chunk` → `stopReason` |
| `session/cancel` | interrupts a running turn, returns `stopReason: "cancelled"` |
| `session/set_config_option` | per-session model and `_agent`, validated against what was offered |
| `session/set_mode` | accepts `ask`; also accepts a stray `modelId` the reference client sends |
| `authenticate` / `logout` | acknowledged; configuration is `terat set` |

### What is deliberately not implemented

These are refused with `-32601` (method not found) rather than faked, and none is
advertised:

| Not implemented | Why |
| --- | --- |
| `fs/read_text_file`, `fs/write_text_file` | the agent's own tools read files; a bridge that also read them would be a second, silently different view |
| `terminal/*` | the answer is produced by one process; the bridge is not a terminal host |
| `session/load`, `session/resume`, `session/list`, `session/delete`, `session/close` | no session store. terat's thread is the scrollback, not a database |
| MCP (`mcpServers`) | accepted and ignored. This bridge asks an agent; the agent's own MCP config is what applies |
| `session/request_permission` | no permission surface to raise: terat asks, the agent decides |

`loadSession: false`, `promptCapabilities: {}`, `sessionCapabilities: {}` — the
empty objects mean "none advertised", which is what the schema says they mean.

### Error codes are the spec's, not approximations

This is where a bridge quietly breaks clients. Measured:

| Situation | Reply |
| --- | --- |
| anything before `initialize` | `-32600` invalid request |
| `session/new` without `cwd` | `-32602` invalid params |
| unknown `sessionId` | `-32002` + `{"data":{"sessionId":...}}` |
| unknown `configId`, unoffered value | `-32602` |
| unknown method | `-32601`, naming the method |
| unreadable frame | `-32700` |
| agent failed | `-32000`, carrying the agent's own first lines |

A client distinguishes a stale session from its own mistake by those codes alone.

### Protocol edges, measured

| Probe | Result |
| --- | --- |
| client asks for `protocolVersion: 2` | answers v1 — spec-correct: the client continues if it supports v1 |
| `initialize` with no `protocolVersion` | answers v1 |
| integer id `424242` | echoed bare |
| string id `"abc"` | echoed **quoted** (this was a real bug: unquoted made the frame invalid JSON) |
| blank line | ignored |
| double `initialize` | accepted; existing sessions survive |
| two `session/new` | `sess_1`, `sess_2` — distinct and monotonic |
| stderr during a session | **0 lines**. The transport is clean; diagnostics go to the client as errors |
| `stdin` closes | exits 0 |

One known wrinkle: a JSON-RPC **batch array** is not unpacked — it is read as one
frame, so the first element is served and the rest are not. ACP does not use
batches over stdio, and no client observed has sent one. Documented rather than
hidden.

---

## 2. Infra fit

### Dependencies

`#!/bin/sh` plus `awk`, `sed`, `grep`, `curl`, `od`, `head`, `tail`, `cat`. No
Node, no Python, no jq, no SDK. Verified running under **dash**, not just bash.

That is the whole reason this works where heavier bridges do not: it is a shell
script and an awk script, so a machine that can run `terat` can serve ACP.

### Configuration without a writable disk

```sh
docker run -e TERAT_URL=https://api.example.com/v1 \
           -e TERAT_KEY=sk-... \
           -e TERAT_MODEL=some-model \
           image terat acp
```

`TERAT_URL`, `TERAT_KEY`, `TERAT_MODEL` win over the settings file, so a fresh
image with no writable home and no `terat set` is configured. Measured cases:

| Environment | Result |
| --- | --- |
| `HOME` read-only (`chmod 500`), env-only config | `end_turn`, answers |
| `HOME` unset entirely (`env -u HOME`) | answers |
| normal laptop, `~/.config/terat/settings` | answers |

A key supplied by environment lands in the *generated* agent config under
`$TMPDIR`, never in a file terat wrote.

### Lifecycle

| Property | Measured |
| --- | --- |
| exits when stdin closes | yes, code 0 |
| leaves temp files behind | no (`mktemp -d`, removed by `trap` on EXIT/INT/TERM) |
| writes to stderr | no |
| survives a malformed frame | yes, replies `-32700` and continues |
| concurrent sessions in one process | yes, `sess_N` keyed independently |

### The honest limitation: turns are serial

One `terat acp` process runs **one turn at a time**. Measured: two 4-second turns
in two different sessions took **9 seconds**, not 4.

This is not a bug, it is the shape. The question is asked of one subprocess and
the answer is awaited. Consequences an infra user must plan for:

- **A slow turn blocks every other session in that process.** If you run a
  multi-session server, run **one process per concurrent user**, not one shared
  process.
- **Cancel is per session**, measured: with `sess_1` running, a `session/cancel`
  naming `sess_2` leaves `sess_1` to finish with `end_turn`. That was a real bug
  until it was measured — the poll killed whichever turn was running, regardless
  of which session the cancel named, which is exactly what a session id exists to
  prevent.
- A client still waits for the turn ahead of it, because turns are serial.
- This is why the bridge is small: making turns concurrent is a supervisor's job,
  and a supervisor is what a container orchestrator already is.

### Agent selection at runtime

`configOptions` carries two selectors:

```jsonc
{"type":"select","id":"model",   "category":"model",   "name":"Model", ...}
{"type":"select","id":"_agent",  "category":"_agent",  "name":"Agent", ...}
```

`_agent` uses the spec's reserved `_` prefix for extensions, so it travels as
ordinary config: a client that renders config options shows it without knowing
terat exists. A client that ignores unknown categories still gets a working
session on the saved agent.

Verified: one process, `pi` answers, client switches, `opencode` answers — both
`end_turn`. So a dev can compare two harnesses on one question without restarting
anything.

### Adding an agent (the OSS path)

Three edits, no ACP work, because the bridge asks `terat` rather than knowing any
harness:

```sh
agents='pi claude codex opencode grok dsh newthing'   # 1. the list
newthing) echo 'newthing --prompt {}' ;;              # 2. how to ask it
newthing) echo Newthing ;;                            # 3. display name
```

An unknown agent now receives configuration through `TERAT_URL`, `TERAT_KEY`,
`TERAT_MODEL` and `OPENAI_BASE_URL`/`OPENAI_API_KEY`. Before that fallback existed
a contributed agent ran and **silently ignored every setting** — the worst way to
be misconfigured.

`TERAT_CMD` is *not* the way to add an agent: it bypasses the agent table and the
config switch entirely. It is for testing a command.

---

## Scorecard

| Question | Answer |
| --- | --- |
| Passes the official TCK? | **66 pass, 1 fail** (advisory MCP), 83 skipped by capability |
| Implements the core protocol? | **yes** — initialize, session/new, prompt, cancel, config, modes |
| Honest about what it refuses? | **yes** — refused methods return `-32601`, not silence |
| Spec-correct error codes? | **yes**, all seven in use, measured |
| Runs on a bare box? | **yes** — `sh` + `awk`, no interpreter |
| Configurable with no writable disk? | **yes** — three env vars |
| Concurrent turns? | **no** — one turn at a time, by design. Scale with processes |
| Session persistence? | **no** — in-memory; terat's thread is the scrollback |
| MCP client? | **no** — the agent's own MCP config applies |

**Verdict on compatibility:** compatible with the protocol it claims, and
deliberately incompatible with the parts it cannot honestly serve. The one gap a
client cannot work around is MCP; everything else is either implemented or
explicitly refused.

**Verdict on infra flexibility:** it is a good fit for *one agent per process* —
unchanged from a laptop to a read-only container — and the wrong tool for a
multi-tenant server that needs many concurrent turns in one process. Run more
processes.

---

## Reproducing this

```sh
# conformance
uvx --from git+https://github.com/agentclientprotocol/acp-tck@v0.5.0 \
  acp-tck -- sh terat acp

# the suite (stages tracked files only; a developer checkout may hold
# gitignored reference clones that break cp -R on a second run)
sh test/check.sh
```

`terat` is 1772 lines, `terat-acp.awk` 106. The bridge is 436 of those 1772.
