# terat

Short for **Terminal Rat**.

**The agent client protocol compatible native terminal experience.**

Your prompt stays exactly as it is — same starship, same path, same colours — and
one character changes: `❯` becomes `🟅`. Type a question instead of a command, read
the answer, type another. Your terminal is the thread.

This is real output, not a mock-up:

```
🟅 why did that build fail?

Pi: Missing semicolon on line 42 of main.c.
🟅 !cat main.c
int main(void) {
  return 0
}
🟅
MacBookPro%                           ← empty line or Ctrl+C: back to ❯
```

No alternate screen. No redrawn prompt. No TUI. Nothing owns the terminal: the
answer is ordinary stdout and stays in scrollback like any command's output.

## What does terat do?

A native tool for the shell you already use. Ask a question with `terat`, or turn
your current shell into ask mode and stop leaving the terminal:

```sh
terat 'why did that build fail?'      # one question, answer on stdout
terat @screenshot.png 'what is this?' # one question with a file attached
```

Then either press the shortcut, or type `@` at any prompt, and stay in the mode:

```
~/src/api ❯ @why did that build fail?   ← opens the mode and asks
~/src/api 🟅 why did that build fail?    ← asked
~/src/api 🟅 Pi: Missing semicolon on line 42 of main.c.
~/src/api 🟅 and how do I fix it?        ← next question, same mode
```

## How does terat work?

It drives the coding agents you already have — Pi, Claude Code, Codex, the
DeepSeek Harness, opencode, grok — by name. `terat claude 'q'` asks Claude for one
question; `terat set agent claude` asks Claude from then on:

```sh
terat claude 'why is the build failing?'
terat set agent claude
```

| agent | asked with | images |
|---|---|---|
| `pi` | `pi -p --mode json` (default) | yes |
| `claude` | `claude -p` | yes |
| `codex` | `codex exec --skip-git-repo-check` | yes |
| `opencode` | `opencode run` | yes |
| `grok` | `grok -p {}` | yes |
| `dsh` | `dsh --profile headless {}` | yes |

Four things follow from that, and they are the whole trick:

**It shares the terminal session as context.** Every question carries the working
directory, the files beside you, and the commands already run in this shell — so
"why did that fail" works without you pasting anything.

**`@` goes in from a normal prompt, `!` comes back out.** `@` sends a question
without leaving the shell; `!` runs an ordinary command from inside ask mode, in
*this* shell, so `cd` and exports stick.

**The same engine answers ACP.** `terat acp` speaks the
[Agent Client Protocol](https://agentclientprotocol.com) on stdin, so an editor
can ask what the terminal asks. One engine, two front doors — that is the
"agent client protocol compatible" part.

**Type ahead while it thinks.** A question typed while one is still out is queued
and asked in order as the answers land. Nothing blocks the line:

```
🟅 why did that build fail?
🟅 and the flaky test?
  queued (1)
🟅 ok, fix it then
  queued (2)

Pi: Missing semicolon on line 42 of main.c.

Pi: It sleeps 50ms and asserts a wall clock; CI is slower.

Pi: Added the semicolon and a 200ms tolerance.
```

Leaving ask mode: an empty line, `Ctrl+C`, `Ctrl+X i`, or type `terat` again.

## How should I use terat?

I built terat to make my local and remote shells AI compatible. In practice that
is asking a question over SSH, or inside a container I am inspecting, without
swapping focus or tools — that is my number one daily use.

The bigger win is agentic work and sandboxes: one place to put provider
credentials for every harness at once, so switching between them is one word
instead of editing config in six formats. I also use it to compare harnesses on
the same task.

### Why should I use terat?

Getting more done quickly. Constantly shifting focus, swapping tools, and
copy-pasting is a real waste of time, and it is worse on a remote box or inside a
container. If you want a small, no-fluff way to ask a question and get back to
work, this is it.

It is deliberately basic and small: a shell script and an awk script, no build, no
runtime, no SDK. You can read all of it in an evening and change it to suit you.

### terat primitives

1. **A simple, native terminal experience.** It has to work like I am used to
   from ten years of coding — whether that is a MacBook, a Raspberry Pi, or a
   server. Your prompt, your colours, your scrollback.
2. **Universally compatible.** The `terat` command works in `sh`, `bash`, `zsh`,
   `fish`, in a container, over SSH. Ask mode is zsh, because holding the line
   through the shell's own editor is what stops it feeling like a TUI.
3. **It just has to work.** Sometimes forgotten in the AI age: I want to ask a
   question, find a file, start a project, read a diagnostic, or have a bad
   command corrected. That should take one line and not a new window.

## Runs where the others do not

A shell script and an awk script. No node, no python, no jq, no SDK.

```dockerfile
FROM alpine:3.20
RUN apk add --no-cache gawk coreutils curl
COPY terat terat-trace.awk /usr/local/bin/
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

This is a second front door, not a layer under the first: `terat 'q'` and
`terat acp` both end up running the same agent CLI. Nothing in your shell flow
goes through the protocol.

It passes the official conformance suite at **66 passed, 1 failed, 83 skipped**.
The one failure is `ACP-SESSION-004`: an agent *should* connect to MCP servers the
client names, and terat has no MCP. What it implements, what it refuses and why,
and the one honest limit (turns are serial) are measured in
[`docs/acp-compatibility.md`](docs/acp-compatibility.md).

## Install

Nothing to build.

```sh
sh -c "$(curl -fsSL https://raw.githubusercontent.com/svliantiss/terat/main/install.sh)"
```

That writes `terat` and `terat.zsh` to `~/.local/bin`, adds one `source` line to
`~/.zshrc`, and tells you if `~/.local/bin` is not on your `PATH`. It prints the
version it installed, so a failed download is visible rather than silent.

Prefer to see it first, and to keep the checkout:

```sh
git clone https://github.com/svliantiss/terat
cd terat
mkdir -p ~/.local/bin                            # absent on a fresh machine
ln -sf "$PWD/terat" ~/.local/bin/terat
echo "source $PWD/terat.zsh" >> ~/.zshrc         # ask mode in zsh
```

`~/.local/bin` is on most people's `PATH` already. If `terat` is not found
afterwards, that is why — add it:

```sh
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
```

To remove it again:

```sh
sh -c "$(curl -fsSL https://raw.githubusercontent.com/svliantiss/terat/main/install.sh)" --uninstall
```

The `terat` command needs one agent on `PATH` and otherwise only `awk`, `grep`,
`sed`, `od` and `date`, which are on any Unix. **Ask mode needs `zsh`** — that is
what holds your line while a question is out. `curl` only for traces; `script` for
the pty relay (see [when it is missing](#when-script-is-missing)).

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

To toggle without typing anything: `Ctrl+X i`, or `Option+i` where the terminal
sends meta. `Shift+Enter` starts a second line, so a question can be a paragraph;
that needs a terminal that reports it (kitty keyboard protocol, xterm
modifyOtherKeys, or `Option+Enter`).

### Ctrl+Shift+I

`Ctrl+Shift+I` is the shortcut most people try, and in most terminals it cannot
work. A legacy terminal encodes `Ctrl`+letter as a control byte and drops the
modifiers, so `Ctrl+I` **is** the TAB byte — by the time the shell reads `0x09`
there is nothing left to say whether Shift was down. That is a limit of the
terminal, not of terat.

A terminal that speaks the kitty keyboard protocol can send a distinct sequence
instead. terat.zsh already binds it, so the terminal only has to be told to send
it. Ghostty:

```
keybind = ctrl+shift+i=text:\x1b[105;6u
```

`install.sh` adds that line to `~/.config/ghostty/config` when that file already
exists, and removes it again with `--uninstall`. Reload Ghostty, then a new
terminal window has the shortcut.

Which terminal you are in decides whether this is possible at all:

| terminal | `Ctrl+Shift+I` |
|---|---|
| Ghostty | works, with the keybind above (added by the installer) |
| kitty, WezTerm, foot | works once the terminal is put in kitty-protocol mode |
| Terminal.app, Warp | **not possible** — they never report Ctrl+Shift |
| anywhere over SSH | depends on the client you are typing into |

Where it cannot work, `Ctrl+X i` and typing `terat` always do, because they cost
the terminal nothing.

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
🟅 @shot.png what is wrong with this layout?
🟅 #src/parser why is this slow?
🟅 @package.json and #. compare these
```

The attachment goes in before the question, as text or as an image depending on
what the file is, and a binary is named with its size rather than inlined.

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
arrives. It is drawn on the terminal itself, not into the answer, so it never
appears in piped output — `git diff | terat 'review this'` gets a clean diff and
no frames.

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
terat --version             # the release, for a bug report
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

## Rex

In [Rex](https://rex.li), Cmd+Shift+I toggles ask mode in the focused pane. The
installer puts `terat.lua` beside the other two files; add one line to Rex's
config and reload:

```sh
echo 'dofile(os.getenv("HOME") .. "/.local/bin/terat.lua")' >> ~/.config/rex/init.lua
```

```sh
rex config reload      # or restart Rex
```

Rex claims the key before the shell sees it, so the action sends the shell its
own Ctrl-X i binding: no command is typed, no Return is needed, and whatever was
half-written on the line survives the round trip. `install.sh` prints that same
path when it detects a Rex config.

From a checkout, point the `dofile` at the file you have rather than a fixed
location — the path in the comment at the top of `terat.lua` is an example, not
a requirement.

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
| `terat` | the whole thing: asks, prints, remembers, and speaks ACP |
| `terat.zsh` | the ask mode: glyph, Enter, `!`, queueing, Ctrl-C, plugins off |
| `install.sh` | the one-liner: fetches both into `~/.local/bin`, edits `.zshrc` |
| `terat-trace.awk` | optional: builds OTLP spans; without it, tracing says so |
| `terat.lua` | the Rex half: Cmd+Shift+I toggles ask mode in the pane |

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
