# Next steps

Written after measuring, not guessing. Every gap below was reproduced on this
machine, and the two container results were produced in real Alpine and Debian
images rather than reasoned about.

The short version: **the protocol work is done. What is left is the part that
makes a stranger able to use it** — an install that survives being copied, a
licence, and telling the truth about the one shape limit.

---

## What is already true (verified, not claimed)

| Claim | Evidence |
| --- | --- |
| ACP conformance | **66 passed, 1 failed** (advisory MCP), 83 skipped by capability |
| Same result inside a container | **66/1 in `python:3.14-slim`, `/bin/sh` = dash** |
| Full turn in bare Alpine/busybox | `end_turn` with `IN_CONTAINER_OK` |
| No interpreter | `sh` + `awk`. Verified under busybox and dash |
| Config with no writable disk | `docker run -e TERAT_URL=... -e TERAT_KEY=...` |
| No `HOME` at all | answers |
| Per-session agent switch | `pi` then `opencode`, one process, both `end_turn` |
| Adding an agent | 3 edits, zero ACP code |
| Suite | green twice, 20 claim groups, each falsified first |

That is a working product. The rest is packaging.

---

## P0 — things that break a stranger today

### 1. Copying `terat` alone breaks ACP

Measured:

```
$ cp terat ~/.local/bin/ && terat acp
terat: cannot find terat-acp.awk beside ~/.local/bin/terat
terat: acp needs it; it ships next to terat
```

The README's install step symlinks only `terat`. That works **by accident**,
because the symlink resolves back into the checkout. A real install — copying
files out, or `curl | tar` — has no `terat-acp.awk` and ACP is dead.

**Two acceptable fixes:**

- **(a) Embed the awk in the script.** The whole helper is 106 lines. Appending
  it as a heredoc, writing it to `$TMPDIR` at first use, makes `terat` a genuine
  single file — which is the "just add this package" goal in its strongest form.
  Cost: ~110 lines, one `mktemp`, and the awk is no longer editable on its own.
- **(b) Ship and document them as a set.** Honest and cheaper, but "one file" is
  a nicer promise than "four files".

Preference: **(a)**, because it turns three runtime dependencies into one and it
is the difference between "copy this file" and "read the install section".

Also needed: `terat-trace.awk` and `terat-trace.js` are optional, but
`terat-trace.awk` failing silently means traces quietly stop. Either embed or
make the absence loud.

### 2. No `LICENSE`

There is no licence file. For an OSS project this is not a formality: **without a
licence nobody may legally use it.** Every other question about adoption is moot
until this exists. Pick one (MIT or Apache-2.0 both fit a shell tool) and add it.

### 3. `CONTRIBUTING.md` does not exist

The knowledge is in `README.md` and in the test fixture I wrote, but a
contributor looks for a named file. It should say, in this order:

- the contract: anything that reads a question on stdin and writes an answer on
  stdout is a harness
- the 3-edit recipe for a new agent
- run `sh test/check.sh`, and that every claim must fail when the code is broken
  (this is the rule that has caught the most bugs here)
- ACP is not the thing to change when adding an agent

---

## P1 — the one shape limit to fix or document loudly

### Turns are serial

Measured: two 4-second turns in two sessions took **9 seconds**.

This is the honest limit and it is already in
[`docs/acp-compatibility.md`](acp-compatibility.md). Two options:

- **Document and move on.** Say "one process per concurrent user" in the README
  install section, not just the compatibility doc. A dev running a shared server
  will otherwise discover it in production.
- **Make turns concurrent.** Each turn already runs in a background subshell, so
  the work is a job table: session → pid, an output file per turn, and a loop that
  can resume. This is a genuine architectural change to the one piece that is
  currently simple, and it should only be done if someone actually needs it.

Preference: **document now**, build the job table only when a real user asks. The
bridge's simplicity is an asset that concurrency would spend.

---

## P2 — polish that makes it feel finished

| Item | Why |
| --- | --- |
| `--version` / `agentInfo.version` is hardcoded `"1"` | a client cannot report which terat it is talking to, and bug reports cannot be tied to a release |
| `CHANGELOG.md` | the commit log is good; a stranger will not read it |
| `test/check.sh` needs `/src` rewritten to run on a host | the suite is the best documentation here and currently needs a sed to use. It should discover its own directory |
| batch JSON-RPC arrays | served first element only. Documented; either unpack or say so in the ACP doc (it currently is) |
| MCP | the 1 failing advisory test. Out of scope until someone needs it — an ACP client that expects MCP will find the agent's own config applies |

---

## The order I would do it

1. **`LICENSE`** — one file, unblocks everything legal.
2. **Embed `terat-acp.awk`** — makes the one-file promise true, and directly
   serves the "fresh install, just add this package" goal.
3. **`CONTRIBUTING.md`** — turns the fixture in `test/check.sh` into an
   invitation.
4. **`--version`, and make the suite run where it stands.**
5. Concurrency **only** on evidence.

Steps 1–4 are packaging, not engineering. Nothing in the protocol needs to
change, which is the actual good news: the hard part is done and the remaining
work carries no risk to it.

---

## What I would not do

- **Not** add `fs/*` or `terminal/*` to look more complete. Refusing them is
  correct and each refusal is one line.
- **Not** chase the MCP test. It is advisory, and being an MCP client is a
  different product.
- **Not** add a session store. terat's thread is the scrollback; `session/load`
  would mean inventing history that the terminal already has.
- **Not** reach for a runtime. The no-interpreter property is the reason it runs
  in bare Alpine, and that is worth more than any convenience a dependency buys.
