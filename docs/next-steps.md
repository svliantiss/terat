# Next steps

Written after measuring, not guessing. Every gap below was reproduced on this
machine, and the container results came from real Alpine and Debian images rather
than being reasoned about.

The short version: **the protocol work is done and the packaging is done.**
What is left is one shape limit worth knowing, and polish.

---

## What is already true (verified, not claimed)

| Claim | Evidence |
| --- | --- |
| ACP conformance | **66 passed, 1 failed** (`ACP-SESSION-004`, the advisory MCP test), 83 skipped by capability |
| Same result inside a container | **66/1 in `python:3.14-slim`, `/bin/sh` = dash** |
| Full turn in bare Alpine/busybox | `end_turn` with `IN_CONTAINER_OK` |
| No interpreter | `sh` + `awk`. Verified under busybox and dash |
| Config with no writable disk | `docker run -e TERAT_URL=... -e TERAT_KEY=...` |
| No `HOME` at all | answers |
| Per-session agent switch | `pi` then `opencode`, one process, both `end_turn` |
| Adding an agent | 3 edits, zero ACP code |
| Suite runs where it stands | `TERAT_TEST_HOME=/tmp/x sh test/check.sh` from a fresh clone |
| Licence and contributing | `LICENSE` (MIT), `CONTRIBUTING.md` |
| Single-file install | a copied `terat` alone answers, and ACP works: the awk is embedded |
| Version reported | `terat --version` and ACP `agentInfo.version` are the same string, asserted |

---


## P1 — the one shape limit to document loudly

### Turns are serial

Measured: two 4-second turns in two sessions took **9 seconds**.

This is the honest limit and it is in [`acp-compatibility.md`](acp-compatibility.md).
Two options:

- **Document and move on.** Say "one process per concurrent user" in the README
  install section, not only in the compatibility doc. A dev running a shared
  server will otherwise discover it in production.
- **Make turns concurrent.** Each turn already runs in a background subshell, so
  the work is a job table: session → pid, an output file per turn, and a loop that
  can resume. A genuine architectural change to the one piece that is currently
  simple, and only worth doing if someone actually needs it.

Preference: **document now**, build the job table when a real user asks. The
bridge's simplicity is an asset that concurrency would spend.

---

## P2 — polish that makes it feel finished

| Item | Why |
| --- | --- |
| `CHANGELOG.md` | the commit log is good; a stranger will not read it |
| batch JSON-RPC arrays | served first element only. Documented; either unpack or say so (it currently does) |
| MCP | the 1 failing advisory test. Out of scope until someone needs it — an ACP client expecting MCP will find the agent's own config applies |

---

## The order I would do it

1. Concurrency **only** on evidence.
2. A `CHANGELOG.md` when there are releases to list.

Nothing in the protocol needs to change, which is the good news: the hard part is
done and the remaining work carries no risk to it.

---

## What I would not do

- **Not** add `fs/*` or `terminal/*` to look more complete. Refusing them is
  correct and each refusal is one line.
- **Not** chase the MCP test. It is advisory, and being an MCP client is a
  different product.
- **Not** add a session store. terat's thread is the scrollback; `session/load`
  would mean inventing history that the terminal already has.
- **Not** reach for a runtime. The no-interpreter property is why it runs in bare
  Alpine, and that is worth more than any convenience a dependency buys.
