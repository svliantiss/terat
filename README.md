# terat

**The agent-compatible terminal.** Your prompt stays exactly as it is — same
starship, same path, same colours — and one character changes: `❯` becomes `🟅`.
Type a question instead of a command, read the answer, type another. Your
terminal is the thread.

```
~/src/api ❯ @why did that build fail?
~/src/api 🟅 why did that build fail?
Pi: The missing semicolon on line 42.
~/src/api 🟅 and how do I fix it?
Pi: Add one on line 42.
~/src/api 🟅 !cd src                     ← shell command, stays in the mode
~/src/api/src 🟅 @main.c does this leak?
Pi: Yes — the buffer is never freed on the error path.
~/src/api/src 🟅                         ← empty line or Ctrl-C: back to ❯
~/src/api/src ❯
```

No alternate screen. No redrawn prompt. No TUI. Nothing owns the terminal: the
answer is ordinary stdout and stays in scrollback like any command's output.

## Any agent, not one agent

Six harnesses are wired in by name. It is always the same prompt, whatever
answers:

```sh
terat claude 'why is the build failing?'   # ask claude for one question
terat set agent claude                     # ask claude from now on
```

| agent | asks it with | images |
|---|---|---|
| `pi` | `pi -p --mode json` (default) | yes |
| `claude` | `claude -p` | yes |
| `codex` | `codex exec --skip-git-repo-check` | yes |
| `opencode` | `opencode run` | yes |
| `grok` | `grok -p {}` | yes |
| `dsh` | `dsh --profile headless {}` | yes |

A name beats a command string because each harness takes its endpoint somewhere
else, and getting it wrong fails quietly. `terat set url`/`key`/`model` generates
what each one needs in a temporary directory, so your real `~/.pi`, `~/.codex`,
`~/.config/opencode` and `~/.dsh` are never touched.

**Anything that reads a question on stdin and writes an answer on stdout is an
agent.** Nothing has to be added for it:

```sh
TERAT_CMD='some-agent -p' terat 'why is the build failing?'
```

Adding one of the named kind takes three edits — see
[CONTRIBUTING.md](CONTRIBUTING.md#adding-an-agent).

## Any program can ask, too (ACP)

`terat acp` speaks the [Agent Client Protocol](https://agentclientprotocol.com)
on stdin, so an editor can ask the same engine the terminal does:

```sh
terat acp        # JSON-RPC over stdio, for a client
```

It passes the official conformance suite at **66 passed, 1 failed** — the failure
is the advisory MCP test. What it implements, what it refuses and why, and the
one honest limit (turns are serial) are measured in
[`docs/acp-compatibility.md`](docs/acp-compatibility.md).

## Runs where the others do not

A shell script and an awk script. No node, no python, no jq, no SDK.

```dockerfile
FROM alpine:3.20
RUN apk add --no-cache gawk coreutils curl
COPY terat terat-acp.awk terat-trace.awk /usr/local/bin/
```

```sh
docker build -t terat . && docker run -i --rm \
  -e TERAT_URL=https://router.example/v1 \
  -e TERAT_KEY=sk-... \
  -e TERAT_MODEL=some/model \
  terat acp
```

That is the whole image. There is nothing to install and no entrypoint script.

Verified in bare **Alpine (busybox)** and **Debian (dash)**: a full turn
completes, and the conformance suite returns the identical result inside the
container. Works with a read-only `HOME`, and with no `HOME` at all.

## Install

Nothing to build.

```sh
git clone https://github.com/svliantiss/terat
cd terat
ln -sf "$PWD/terat" ~/.local/bin/terat          # type `terat` anywhere
echo "source $PWD/terat.zsh" >> ~/.zshrc        # ask mode in zsh
```

Needs `zsh` and one agent on `PATH`. `awk`, `grep`, `sed`, `od` and `date` are on
any Unix. `curl` only for traces; `script` for the pty relay (see
[when it is missing](#when-script-is-missing)).

The first run on a machine with no agent still gives you a shell — that is where
you install one:

```
$ terat                     ← a shell, before anything is installed
~/src ❯
$ terat 'hello'             ← a question needs something to ask
terat: pi is not installed, and it is what answers the question
terat: install it, point TERAT_CMD at another harness, or ask a different agent: pi claude codex opencode grok dsh
```

## Using it

The prefix is the whole interface:

| Type | What happens |
| --- | --- |
| `@` + Return | prompt becomes `🟅`, nothing is sent |
| `@what is this?` | asks now, and stays in the mode |
| `@shot.png what is this?` | attaches the file and asks |
| `!ls` | runs the command, stays in the mode |
| `#src` | attaches that folder's files |
| `terat` | flips in place, either direction |
| `Ctrl+C` / empty Return | leaves the mode |

Everything else is the shell you had: same prompt, same path, same scrollback.
`Ctrl+X i` and `Option+i` also toggle the mode. `Shift+Enter` starts a second line
so a question can be a paragraph — that needs a terminal that reports it (kitty
keyboard protocol, xterm modifyOtherKeys, or `Option+Enter`).

`!` runs in *this* shell, so `cd`, `export` and aliases stick, and the command
and its output join the transcript so the next question can refer to them.
Anything full-screen (`vim`, `less`, `top`) goes in normal mode instead, because
copying its output would break the terminal it draws on.

### The prompt is not faked

`terat.zsh` keeps starship's prompt *command* and re-runs it, swapping one
character on the way out:

```zsh
eval "p=$_terat_prompt"          # p=$(starship prompt …)
(( TERAT_MODE )) && p=${p//❯/🟅}
```

So the prompt is always the real one. Nothing is drawn in its place and nothing is
redrawn after the fact, so there is no flicker to have.

### What the model can see

Two cheap facts go with every question, so questions about what is in front of you
work without attaching anything:

```
Where: /home/me/src/api
Here: main.c Makefile src
```

The question is sent **first**, and everything else follows under a line saying it
is context which has already happened — the working directory, shell history whose
commands were already run, and any attached files. That ordering is why a `cmd:`
line from a previous turn is read as history rather than as an instruction to run
it again.

## Attaching files and folders

`@path` or `#path` puts a file in front of the model — images as images, text as
text — and a folder is expanded to the files it holds, because an agent cannot
read a directory:

```
~/src/api 🟅 @shot.png what is wrong with this layout?
~/src/api 🟅 #src/parser why is this slow?
~/src/api 🟅 @package.json and #. compare these
```

Quotes are optional even with spaces in the path: a path that does not exist is
retried with the next word, so `@My Latest Screenshot.png` works unquoted, and a
`@` naming nothing simply stays part of your question.

The same works outside the mode, and in bash or a container:

```sh
terat @shot.png "what is this?"
terat "#src" "summarise this folder"
```

`TERAT_ATTACH_MAX` (default 200000 bytes) caps the total. Files are read by
`terat`, not passed as `@path` to the agent, because on an agent that does not
understand `@path` the model is handed a path it cannot open and answers about the
path instead of the file.

## While it waits

A spinner turns on the line below the question and vanishes when the answer
arrives. The frame is drawn on its own line and erased before the print, so it
never touches the question.

It waits for the run to finish rather than for a pause in the output. `pi` is a
coding agent: asked to run a test or search a tree it goes silent while the tool
works, so a gap in the output is normal work, not a failure. `pi --mode json`
prints `agent_end` when it is genuinely done, and that is what the wait follows.

## Why answers are wrapped

A model writes prose as one very long line — a single sentence can be 600
characters with no newline at all. A terminal does not wrap at word boundaries; it
breaks at the exact column, so that sentence arrives cut through the middle of
words with the left edge drifting. `terat` breaks the answer at spaces to the
width of your terminal before printing.

## Endpoint, key, model

```sh
terat set url https://router.example/v1
terat models                # what it serves, one per line, vision or text
terat set key sk-...
terat set model some/model
terat config                # url, model, and key=(set)
```

`terat models` asks the endpoint for its own list, so a model is named rather than
guessed. The first column is not decoration: a text-only model drops an attached
image before the request is sent, so knowing which ids can see a screenshot is what
makes `terat @shot.png "what is this?"` worth typing.

Settings live in `~/.config/terat/settings` (mode `600`), one `key=value` per line.
`terat set key` never echoes the key back. `terat set` writes a file and exits, so
it is safe in a script.

For a container or a cron job, three variables override the file and need no
writable disk:

```sh
TERAT_URL=... TERAT_KEY=... TERAT_MODEL=... terat 'why did it fail?'
```

## Unattended

Piped output is raw — no glyph, no label — so it composes:

```sh
git diff | terat 'review this diff'
make 2>&1 | terat 'why did that fail?'
```

In a cron job, pass the question as an argument rather than relying on stdin, and
`terat --trace` if you want the run in the trace collector.

## When `script` is missing

The pty relay uses `script` so that a full-screen program inside `!` still has a
terminal. It ships with macOS and util-linux. On a system without it, `terat`
says so and runs the command without the relay rather than failing.

## Tests

```sh
TERAT_TEST_HOME=/tmp/terat_test sh test/check.sh
```

Prints `RESULT=PASS`, or `RESULT=FAIL` with the one claim that broke. Needs `zsh`;
pty claims need `tmux`. `TERAT_TEST_HOME` matters — the suite installs into that
home and appends to its `.zshrc`, so without it the suite refuses to run rather
than touching yours.

`test/run.sh` runs the same claims in a container per distro (Debian, Ubuntu,
Fedora, Alpine, Amazon Linux, Arch) from an empty home.

The suite is the behaviour documentation. Each claim is written so it **fails when
the code is wrong** — see [the rule](CONTRIBUTING.md#the-rule).

## Files

| File | Job |
| --- | --- |
| `terat` | asks the chosen agent one question, prints the answer, remembers it |
| `terat.zsh` | the ask mode: glyph, Enter, `!`, Ctrl-C, plugins off |
| `terat-acp.awk` | the three JSON jobs the ACP bridge needs |
| `terat-trace.awk` | builds the OTLP spans from the agent's event stream |
| `terat.lua` | optional: the same thing under a Rex shortcut |

## Details

- [`docs/harnesses.md`](docs/harnesses.md) — per-agent wiring, the six ways to
  carry a `traceparent`, `{}` for argument-style agents, and what was measured
  against each real binary
- [`docs/acp-compatibility.md`](docs/acp-compatibility.md) — ACP conformance and
  infra fit, measured
- [`docs/tracing.md`](docs/tracing.md) — OTLP, why a cost panel can read `$0.00`,
  and joining a trace to the router's ledger
- [`docs/next-steps.md`](docs/next-steps.md) — what is still missing

## Rules

- Shell only. Adding a runtime is how this stops working in a bare container.
- An agent is a command that reads stdin and writes stdout. Nothing else.
- Never advertise an ACP capability that is not implemented.
- A comment says what the code does. Git remembers which bug came first.

## Licence

MIT — see [LICENSE](LICENSE).
