# Next steps

Written after measuring, not guessing. Every gap below was reproduced on this
machine, and the container results came from real Alpine and Debian images rather
than being reasoned about.

The short version: **the protocol work is done and the packaging is nearly done.**
What is left is one real install problem, one shape limit worth knowing, and
polish.

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

---

## P0 — the one thing that still breaks a stranger

### Copying `terat` alone breaks ACP

Measured, from an unrelated working directory:

```
$ cp terat ~/.local/bin/ && cd /tmp && terat acp
terat: cannot find terat-acp.awk beside ~/.local/bin/terat
terat: acp needs it; it ships next to terat
```

The README's install step symlinks into the checkout, so it works there — the
symlink resolves back to the real directory and the awk is beside it. A real
install — copying files out, or `curl | tar` into `/usr/local/bin` — has no
`terat-acp.awk`, and ACP is dead.

`terat` also looks for `./terat-acp.awk` in the current directory, so it can
appear to work if you happen to run it from the repo. That is not a fix; it is a
second way to be confused.

**Two acceptable fixes:**

- **(a) Embed the awk in the script.** The helper is 106 lines. Appending it as a
  heredoc and writing it to `$TMPDIR` at first use makes `terat` a genuine single
  file — the "just add this package" goal in its strongest form. Cost: ~110 lines,
  one `mktemp`, and the awk stops being editable on its own.
- **(b) Ship and document them as a set.** Honest and cheaper, but "one file" is a
  better promise than "four files".

Preference: **(a)**. It turns three runtime dependencies into one and is the
difference between "copy this file" and "read the install section".

`terat-trace.awk` and `terat-trace.js` are optional, but a missing
`terat-trace.awk` means traces quietly stop. Either embed it or make the absence
loud.

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
| `--version` / `agentInfo.version` is hardcoded `"1"` | a client cannot report which terat it is talking to, and bug reports cannot be tied to a release |
| `CHANGELOG.md` | the commit log is good; a stranger will not read it |
| batch JSON-RPC arrays | served first element only. Documented; either unpack or say so (it currently does) |
| MCP | the 1 failing advisory test. Out of scope until someone needs it — an ACP client expecting MCP will find the agent's own config applies |

---

## The order I would do it

1. **Embed `terat-acp.awk`** — makes the one-file promise true and directly serves
   the "fresh install, just add this package" goal.
2. **`--version`**, so a bug report can name a release.
3. Concurrency **only** on evidence.

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
