# terat

Ask pi at your prompt. The prompt itself is unchanged — same path, same colours,
same starship — only its `❯` becomes `🟅`, and a line you type is a question
instead of a command:

```
~/Projects/terat ❯ @why did that build fail?
~/Projects/terat 🟅 why did that build fail?
Pi: The missing semicolon on line 42.
~/Projects/terat 🟅 and how do I fix it?
Pi: Add one on line 42.
~/Projects/terat 🟅 !cd src        ← shell command, stays in the mode
~/Projects/terat/src 🟅 @main.c and how do I fix it?
Pi: Add a semicolon after the return on line 42.
~/Projects/terat/src 🟅            ← empty line or Ctrl-C: back to ❯
~/Projects/terat/src ❯
```

No alternate screen, no redrawn prompt, nothing that owns the terminal: the
answer is ordinary stdout and stays in scrollback like any command's output.

## How the glyph changes

`terat.zsh` keeps starship's prompt *command* and re-runs it, substituting one
character on the way out:

```zsh
eval "p=$_terat_prompt"          # p=$(starship prompt …)
(( TERAT_MODE )) && p=${p//❯/🟅}
```

So the prompt is always the real one. Nothing is drawn in its place, nothing is
redrawn after the fact — there is no flicker to have.

## Files

| File | Job |
| --- | --- |
| `terat` | asks the chosen agent one question, prints the answer, remembers it |
| `terat.zsh` | the ask mode: glyph, Enter, `!`, Ctrl-C, plugins off |
| `terat-acp.awk` | the three JSON jobs the ACP bridge needs: read a field, join prompt text, escape a string |
| `terat.lua` | optional: the same thing under a Rex shortcut |

Shell only: `sh`, `sleep`, `awk`, and one agent. No python, no jq, no curl — the
agent does the network. `curl` is the one exception, and only for posting a trace:
without it `terat` still answers and simply posts nothing, rather than failing a
question because a telemetry endpoint is unreachable. A minimal container therefore
needs `curl` installed only if you want traces out of it.

## Install

`terat` is a shell script and a zsh file; there is nothing to build. It needs
zsh, and it needs `pi` on `PATH`, because pi is what answers the question.
Nothing else is required — `awk`, `grep`, `od` and `date` are already on any
Unix, and the pty relay uses `script`, which ships with macOS and util-linux
(see [When `script` is missing](#when-script-is-missing)).

```sh
ln -sf $PWD/terat ~/.local/bin/terat   # optional: for typing `terat` yourself
echo "source $PWD/terat.zsh" >> ~/.zshrc   # zsh ask mode
```

If the agent is not installed, `terat` says so and exits rather than relaying a
shell error:

```
🟅 hello
terat: pi is not installed, and it is what answers the question
terat: install it, point TERAT_CMD at another harness, or ask a different agent: pi claude codex opencode grok dsh
```

### Choosing an agent

Six agents are wired in by name, so there is no command string to remember:

```sh
terat claude 'why is the build failing?'   # ask claude for one question
terat set agent claude                      # ask claude from now on
```

| name | asks it with | `@file` | url/key reaches it through | `--trace` reaches it through |
|---|---|---|---|---|
| `pi` | `pi -p --mode json` (the default) | yes | `PI_CODING_AGENT_DIR` → `models.json` | `-e terat-trace.js` |
| `claude` | `claude -p` | yes | `ANTHROPIC_BASE_URL`, `ANTHROPIC_API_KEY` | `ANTHROPIC_CUSTOM_HEADERS` |
| `codex` | `codex exec --skip-git-repo-check` | yes | `-c key=value` overrides | `-c …env_http_headers.traceparent` |
| `opencode` | `opencode run` | yes | `OPENCODE_CONFIG_DIR` → `opencode.json` | `options.headers` |
| `grok` | `grok -p {}` | yes | `GROK_BASE_URL`, `GROK_API_KEY` | — cannot join |
| `dsh` | `dsh --profile headless {}` | yes | `DSH_HOME` → profile patch | `headers:` in the patch |

The tracing column is a column because it is the same problem once more: five
agents carry a `traceparent` five different ways, and the sixth has no way at all.
It is not one mechanism applied six times. `-e` loads a JS module and only `pi` has
one; handing it to `claude` is `error: unknown option '-e'`. See
[Joining a trace to the router's ledger](#joining-a-trace-to-the-routers-ledger).

Those last-column differences are the reason a name beats a command string. Each
agent takes its endpoint somewhere else, and getting that wrong fails quietly: a
`claude` whose base URL ends in `/v1` is asked for `/v1/v1/messages` and answers
"the selected model may not exist or you may not have access to it", which reads
like a bad model id. `terat` normalises that one, and generates the JSON or YAML
the file-based agents need in a directory of their own under `$TMPDIR`, removed
after the answer. Nothing is written into your real `~/.pi`, `~/.codex`,
`~/.config/opencode` or `~/.dsh`, so a setup that already works is left alone.

### Endpoint, key and model

```sh
terat set url https://router.example/v1
terat models                # what that endpoint serves, one per line
terat set key sk-...
terat set model some/model
terat config
```

```
url=https://router.example/v1
key=(set)
model=some/model
```

`terat models` asks the endpoint for its own list, so a model is named rather
than guessed from a docs page. Each line is `vision` or `text`, then the id:

```
vision	passy/Qwen3-VL-235B-A22B-Instruct
text	passy/DeepSeek-V4-Flash
```

The first column is not decoration. A model that cannot take images drops an
attached file before the request is sent, and the reply then reads as the
model's own limitation rather than as a property of what was configured — so
knowing which ids can see a screenshot is what makes
`terat @shot.png "what is this?"` worth typing. `terat models qwen` narrows by
substring.

Reading the list needs no key, and nothing is cached: a stale list is worse than
a slow one when the router is the thing that knows. An endpoint that does not
serve `/models` still works with `terat set model` — the id is only checked by
the agent that receives it.


Settings live in `~/.config/terat/settings` (mode `600`), one `key=value` per
line, so they are readable and hand-editable and survive re-cloning the repo.
`terat set key` never echoes the key back; `terat config` prints `key=(set)`.
`XDG_CONFIG_HOME` and `TERAT_CONFIG` relocate the file.

`terat set` writes a file and exits — it never asks an agent anything, which is
what makes it safe to run from a script.

`TERAT_CMD` remains the general form and still wins over all of this, for a
harness that is not one of the six: anything that takes the question on stdin and
writes the answer on stdout can stand in.

```sh
TERAT_CMD='some-agent -p' terat 'why is the build failing?'
```

A harness that wants the question as an *argument* instead of on stdin needs no
wrapper either: put `{}` where the question goes and `terat` fills it in (see
[harnesses that want the question as an argument](#harnesses-that-want-the-question-as-an-argument)).

When a question itself begins with an agent name — `claude wrote this` — pass `--`
first and the word is taken as part of the question:

```sh
terat -- claude wrote this
```

Ask mode always does this, so the interactive path needs no such thought.

| harness | answers | `@file` | `TERAT_CMD` |
|---|---|---|---|
| `pi` | yes | yes | `pi -p --mode json` (the default) |
| `opencode` | yes | yes | `opencode run` |
| `claude` | yes | yes | `claude -p` (see the wrapper below) |
| `codex` | yes | yes | `codex exec --skip-git-repo-check` |
| `grok` | yes | yes | `grok -p {}` |
| `dsh` | yes | yes | `dsh --profile headless {}` |

All six are verified answering, reading an attached file, and driving the real
prompt (glyph, label, prompt restored), in a container and on a laptop, twice
each and in both orders:

```sh
docker build -f test/D.harness -t terat-harness test
docker run --rm --add-host=host.docker.internal:host-gateway \
	-e ROUTER_KEY -e TERM=xterm-256color \
	-v "$PWD":/src:ro -v "$PWD/test/harnesses.sh":/h.sh:ro \
	terat-harness sh /h.sh 1
```

Two things about that image are worth knowing before blaming the code. It needs
`TERM` set, or `tmux` refuses to start a session and the prompt half of the test
silently reports nothing. And it is a large image: a `docker build` that fails
deep inside an `npm i -g` with a bare exit code is more often the daemon being
out of disk than the registry being down (`docker system df`, then
`docker builder prune`).

`@file` is handled by `terat`, not by the harness. The file is read, and its text
is inlined into the question under `Attached:`; a binary is named and skipped, and
`TERAT_ATTACH_MAX` (default 200000 bytes) caps the total. This is the one place a
little of the terminal's own reading is worth doing: passing `@path` through only
works on a harness that understands it, and on one that does not the model is
handed a path it cannot open and answers about the path instead of the file.

### Harnesses that want the question as an argument

`grok -p` and `dsh --profile headless` will not read the question from stdin:
they take it as an argument, and refuse to start otherwise. Put `{}` in
`TERAT_CMD` and the question goes there instead, as a single argument, with
spaces and shell syntax intact:

```sh
TERAT_CMD='grok -p {}' terat 'what changed in this diff?'
TERAT_CMD='dsh --profile headless {}' terat 'why is the build failing?'
```

The argument is the whole transcript — the question, any earlier turns, and any
attached files — because a task-style CLI takes a single prompt string and there
is nowhere else to put them. It is one argument no matter how many words or
newlines it has, and nothing in it is executed.

Without the placeholder the command is run exactly as written and the question
arrives on stdin, so nothing changes for a harness that reads it the usual way.
`TERAT_CMD` itself is word-split, so a command living at a path with spaces in
it needs a wrapper on `PATH` rather than quotes.

Authors' note: the trap in this whole area is that a harness which does not
understand how it is being called still *starts*, and fails in a way that looks
like terat. `grok -p` with no argument prints "option '-p, --prompt <prompt>'
argument missing", and a pipe of stdin to it is silently discarded; `dsh` says
"a task is required". Neither reads stdin, and neither says so in its help text.

### Wiring each one in

The six named agents do this for you: `terat set url`/`key`/`model` generates
what each one needs. The shapes below are what that generation produces, and are
worth knowing if you would rather keep your own config and skip `terat set`:

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

### When `script` is missing

Capture needs `script` to give the command a pty. Debian, Ubuntu, macOS and util-linux
distributions have it. **Alpine does not** — busybox has no `script` applet, and
the package is not pulled in by `util-linux`'s default split:

```sh
apk add util-linux-misc    # provides /usr/bin/script on Alpine
```

Without it `terat` still works — the prompt, ask mode, `!`, the transcript and
the answers are all fine — but captured output is empty, because there is no pty
to copy from. It fails quietly (verified: no error on the prompt), so on such a
machine capture is simply off rather than broken.

### As your shell

Capture is on in every interactive shell that loads `terat.zsh` — open a terminal
however you like and normal commands are already recorded, with no `!` and no
piping:

```
~/Projects/terat ❯ ls
README.md  archive  terat.lua  terat.zsh  terat
~/Projects/terat ❯ @which of those is a folder?
Pi: `archive` is the only one.
```

`terat` with no question is also a shell — the same zsh, unchanged — for when you
would rather open one by that name:

```sh
ln -sf $PWD/terat ~/.local/bin/terat
# then open `terat` where you would open `zsh`
```

`Ctrl-C` leaves asking and keeps you in the shell; `exit` closes it.

### In Rex

Rex takes a shortcut before the shell sees it, so it needs its own binding: add
one line to `~/.config/rex/init.lua` and reload.

```sh
echo 'dofile(os.getenv("HOME") .. "/Projects/terat/terat.lua")' >> ~/.config/rex/init.lua
rex config reload
```

`Cmd+Shift+I` (and `Ctrl+Shift+I`) toggles the focused pane: it enters ask mode,
and the same keypress leaves it again. The action writes two bytes, `Ctrl-X i`,
with Rex's terminal write method — a binding the shell acts on, not a command it
runs. So nothing is typed, no Return is needed, there is only one round trip, and
a line you had half-written is still there when you come back out. The same key
flips either way, so Rex never has to know which state the pane is in and the
shortcut and the shell cannot disagree.

`terat` alone at the prompt still flips it too, for panes where the shortcut is
not available. It is the same flip, just spelled out.

Rex can also be told about a broken config, which is worth knowing because a
single failing `dofile` silently drops every action and key below it:

```sh
rex config check            # bindings, actions, and any error
rex -C "$(rex client ls --json | jq -r '.clients[0].client_id')" keymap --json
```

## Entering the mode

The prefix is the whole interface: `@` at an empty prompt turns it into ask mode,
`@question` asks straight away, and `!` runs shell commands without leaving.

| Type | What happens |
| --- | --- |
| `@` + Return | prompt becomes `🟅`, nothing is sent |
| `@what is this?` | asks it now, and stays in the mode |
| `@shot.png what is this?` | attaches the file and asks |
| `!ls` | runs the command, stays in the mode |
| `#src` | attaches that folder's files to your question |
| `terat` | flips in place, either direction |
| `Ctrl+X t` | traces this session on or off, and says which |
| `Ctrl+C` / empty Return | leaves the mode |

Everything else is the shell you already had: same prompt, same path, same
colours, same scrollback. `Ctrl+X i` and `Option+i` still toggle the mode if you
prefer a key.

`Shift+Enter` starts a second line instead of asking, so a question can be a
paragraph:

```
~/Projects/terat 🟅 compare these two, one line each:
second line of the same question
Pi: ...
```

That needs a terminal that reports it — kitty keyboard protocol, xterm
modifyOtherKeys, or `Option+Enter` (which sends `ESC CR`). A terminal that sends
nothing distinguishable makes `Shift+Enter` identical to `Return`; then use the
`Option` one.

## Running a command without leaving

Start a line with `!` and it runs as a shell command instead of a question. It
runs in *this* shell, so `cd`, `export` and aliases stick, and you stay in the
mode:

```
~/Projects/terat 🟅 !cd /tmp
/tmp 🟅 !ls -la
total 0
/tmp 🟅 what is in here?
Pi: ...
```

The command is stored in history without the `!`, so up-arrow finds it later,
and it lands in the transcript so the next question can refer to it. What it
printed is recorded too — as long as it is a command that finishes. Anything
that takes over the screen (`vim`, `less`, `top`) goes in normal mode instead,
because copying its output would break the terminal it draws on.

## What stands down while asking

The line is a question, not a command, so both line-editing plugins are switched
off for the duration and restored exactly as they were on exit:

```zsh
ZSH_HIGHLIGHT_HIGHLIGHTERS=()   # no green/red "is this a command?"
ZSH_AUTOSUGGEST_STRATEGY=()     # no history ghost text
POSTDISPLAY=; region_highlight=()
```

## What the model can see

`terat` does not take the agent's hands away. It runs `pi` natively — the same
tools, the same permissions and the same default prompt as running `pi` in that
directory yourself — and only adds the transcript and the question to it. So a
question can be an instruction:

```
~/Projects/terat ❯ @create a file called hello.txt with "hi" in it
Pi: Created `hello.txt` (3 bytes).
~/Projects/terat ❯ @rename it to greeting.txt
Pi: Renamed `hello.txt` → `greeting.txt`.
```

The second question works because the first is in the same thread and the same
working directory. Nothing is sandboxed beyond what `pi` does itself, so treat a
question with the same care as typing the same words into `pi`.

Each shell gets its own transcript, `~/.terat/thread.$$`, and the commands you
run in that shell are appended to it as they happen:

```
cmd: ls -d ~/Projects/terat/archive
user: which command did I just run?
assistant: `ls -d ~/Projects/terat/archive`.

cmd: ls /definitely-not-here
exit: 1
user: did that work?
assistant: No - it exited 1, so that directory does not exist.
```

Only failures get an `exit:` line, so the transcript stays quiet.

So "what did I just do" works, and two terminals never mix into one
conversation — the thread is per shell, not per machine. `terat` works the name
out itself, from `TERAT_THREAD` or, when that is unset, from the pid of the shell
that started it, so a shell opened before this was installed still gets its own
transcript instead of sharing one.

Commands run with `!` also record what they printed:

```
cmd: ls -d ~/Projects/terat/archive
out:
  /home/dev/Projects/terat/archive
user: did that folder exist?
assistant: Yes - it printed the path.
```

A shell cannot read what a command printed; the text goes straight to the
terminal and never passes back through the shell. So `!` copies it on the way
past: the screen still shows everything as it runs — in its own colours — and
the answer builds in the background. Because it runs in this shell, `cd`,
`export` and aliases still change it as usual, and the command is recorded once,
not twice.

The same trick works for the whole shell. Loading `terat.zsh` puts one redirect
on the shell's own stdout, so *every* command's output is copied as you run it —
no `!`, no piping, no asking first:

```
~/Projects/terat ❯ ls
README.md  archive  terat.lua  terat.zsh  terat
~/Projects/terat ❯ @which of those is a folder?
Pi: `archive` is the only one.
```

That is the whole mechanism: one relay per shell and two `exec` lines that point
the shell's own fd 1 at it while a command runs. It is not a multiplexer and not a
wrapper — resize, paste, `Ctrl-C`, job control and `vim` are the shell's own,
because it *is* the shell. Each command's share of the file is the bytes after
the offset `preexec` recorded, so the transcript stays one command at a time,
capped at `TERAT_OUT` lines.

The copy is taken from a **pty**, not a pipe, and that distinction is the whole
reason the terminal still looks native. A pipe is not a terminal, so every
program that asks `isatty(1)` changes what it prints: `ls` drops both its colours
and its columns and prints one name per line, `git` stops colouring, `grep`
stops highlighting, `test -t 1` turns false. No environment variable brings that
back — BSD `ls` has no `CLICOLOR_FORCE` at all. So `terat.zsh` starts one
`script` per shell, opens the slave side of the pty it owns, and lets a `tee`
copy the master out to the screen and to the log. Programs see a terminal
because it *is* one.

```
~/Projects/terat ❯ ls
README.md   archive   terat.lua   terat.zsh   terat    # coloured, in columns
```

The redirect is deliberately *not* left on. With fd 1 redirected zsh block-buffers
the line editor's own output, so keystrokes do not appear until Return and the
whole line lands at once. So the pty is switched in by `preexec` for the moment
a command runs and switched back to the tty by `precmd`, before the prompt is
drawn. Typing stays instant, the spinner animates, and the copy still happens.

Full-screen programs are the exception: they are recognised and run straight to
the terminal instead of through the relay, because they need a tty they own
(see below). Set `TERAT_RAW=` empty before sourcing to opt out entirely.

### Why full-screen programs skip the relay

A pty can carry a `ls` perfectly well, but a full-screen program wants to *own*
its terminal: it reads the size, sets raw mode and expects to be the only writer.
Sharing a pty with a copier that is also reading it makes `pi` draw nothing and
makes `vim` refuse. So the relay is skipped for a short allowlist — `pi`, `vim`,
`nvim`, `less`, `man`, `top`, `htop`, `fzf`, `tmux`, `ssh` and friends — and
those run on the real terminal. Nothing is copied for them; their transcript
entry is the command line, which is the part a later question can usefully refer
to anyway. Everything else is copied normally.

This holds on every way in, including `!` inside the mode: `!vim` is the same
vim, on the same terminal, as `vim` from a normal prompt. It must be — given the
relay's pty instead, vim draws into a terminal nobody is driving, so `ESC` and
`:q` never reach it and it prints the escape sequences as text instead of
quitting.

The terminal is saved before the program runs and put back afterwards. A
full-screen program puts the terminal into raw mode and restores it on exit, but
that only works when it is the foreground process of a shell that is about to
read from the same terminal. Run from inside a zle widget there is no such
restore, and the shell was left with output post-processing and CR/NL
translation off — so every newline after it returned to the wrong column and
every answer came out as a staircase. `stty "$saved"` fixes it, and the prompt is
redrawn because the widget owns the line at that point.

A pipe is also the other way round: when you want the model to read output that
was never captured — a file, another machine — pipe it in:

```
ls -l | terat "which of these is the largest?"
```

Two cheap facts go along with every question, so questions about what is in
front of you work without attaching anything:

```
Where: /home/dev/Projects/terat
Here: README.md archive terat.lua terat.zsh terat
```

That is where the shell is and what sits there, capped at 20 names, so it stays
under a kilobyte even in a directory with hundreds of entries.

The question is sent **first**, and everything else follows under a line that
says it is context which has already happened:

```
Question: why did that fail?
--- context, for reference only; already true, do not act on it ---
Where: /home/dev/Projects/terat
Here: README.md terat
Shell history (commands already run, output already shown):
cmd: make
out:
  gcc: error: no such file
```

The order is load-bearing, not tidiness. A harness is an agent with a shell: a
transcript that *opens* with `cmd: rm -rf build` reads like the request, and
against `pi` a past command in that position was re-executed in about one run
in three. The question first, plus saying plainly that the rest already
happened, took that to zero. When the harness is `pi` — the default — one more
instruction is passed with `--append-system-prompt` saying the same, because
ordering alone is a strong hint rather than a guarantee. A `TERAT_CMD` of your
own never gets that flag: you chose a contract, and a flag appearing behind
your back would turn a working setup into `the harness exited 2`.

It lists what plain `ls` lists — not dotfiles — because that is what you see on
screen and so what "those folders" means. A directory holding nothing but
dotfiles still gets them, and a truncated list ends with `... (38 in all)` so
the model knows there is more rather than assuming it has seen everything.
Scrollback from before, other tabs, and file *contents* are still invisible
unless you `@`-mention a path.

Set `TERAT_THREAD` to opt out and keep one conversation everywhere:

```sh
export TERAT_THREAD=~/.terat/thread     # one shared thread for every shell
```

Sharing is the thing that went wrong by accident: one file for every shell made
the model answer about another tab's work. Set this only if you want that.

`terat "a question"` asks once and prints the answer without entering the mode,
which is also what works in bash, ssh and containers with no shell hook.

`Ctrl+I` is not usable as the key: it is Tab (0x09), the same byte Terminal.app
sends for `Ctrl+Shift+I`.

## Attaching files and folders

`@path` or `#path` puts a file in front of the model — images are sent as images,
text as text — and a folder is expanded to the files it holds, because pi cannot
read a directory:

```
~/Projects/terat 🟅 @shot.png what is wrong with this layout?
~/Projects/terat 🟅 #src/parser why is this slow?
~/Projects/terat 🟅 @package.json and #. compare these
```

Quotes are optional even when the path has spaces: a path that does not exist is
tried again with the next word, so `@My Latest Screenshot.png` works unquoted,
and a `@` or `#` that names nothing simply stays part of your question:

```
~/Projects/terat 🟅 @nobody is going to read this, right?
```

The same works outside the mode, and in bash or a container:

```sh
terat @shot.png "what is this?"
terat "#src" "summarise this folder"
```

## Unattended: a VPS, a container, a cron job

Everything above assumes someone is watching the screen. Nothing here needs one:
`terat` never passes an approval flag, never opens a pager, and asks its question
with stdin closed, which is the same code path as `terat q </dev/null`. The mode
is the only part that wants a terminal, so unattended use is the plain form:

```sh
terat 'why did the nightly build fail?'        # asks, prints, appends to the thread
```

Two things differ from the laptop, and both bite quietly.

**The agent's own sandbox is not terat's.** `terat` passes no autonomy or
permission flag — it invokes each agent the way that agent's help says to — so
whatever that agent does with no TTY is what you get. Measured on a fresh shell
with stdin closed, each asked to create a file:

| agent | asked to write, unattended | what it did |
| --- | --- | --- |
| `pi` | wrote it | content correct |
| `grok` | wrote it | content correct |
| `dsh` | wrote it | content correct |
| `codex` | **could not** | `codex exec` defaults to `read-only` and says so |
| `opencode` | **could not** | `permission requested …; auto-rejecting` |
| `claude` | **said it wrote it** | no file existed, and it reported success anyway |

The last row is the one to know about. `claude` reads files fine and writes
nothing, and the answer is a confident "the file has been created". A script that
checks exit status believes it. If a run has to change the machine, verify the
effect rather than the answer, or give the agent permission explicitly:

```sh
opencode run --auto                     # auto-approve what is not denied
codex exec --skip-git-repo-check -s workspace-write
claude -p --permission-mode acceptEdits  # accepted, but did not fix writes here
```

Those are the agents' flags, not terat's, so they go through `TERAT_CMD` — which
replaces the whole command, codex's generated `-c` overrides included. For codex
that means spelling out the router settings you want as well:

```sh
TERAT_CMD="codex exec --skip-git-repo-check -s workspace-write \
  -c model_providers.terat.base_url=$URL -c model=$MODEL \
  -c model_provider=terat -c model_providers.terat.name=terat \
  -c model_providers.terat.wire_api=responses \
  -c model_providers.terat.env_key=TERAT_KEY" \
  terat 'rebuild the index'
```

For `opencode` one flag is enough, and the generated config is still used:

```sh
TERAT_CMD='opencode run --auto' terat 'rebuild the index'
```

**Nothing is left running.** A question is one process tree that exits when the
answer does; there is no daemon, no socket, no state to clean up after a reboot.
The transcript is `~/.terat/thread.$$` — keyed on the parent shell, so a fresh
container or a cron run starts one and it accumulates there unless you set
`TERAT_THREAD`. Point it somewhere durable if the runs are supposed to remember
each other:

```sh
TERAT_THREAD=/var/lib/terat/thread terat 'what changed since yesterday?'
```

The config is read from `$XDG_CONFIG_HOME/terat/settings` (mode 600, key in plain
text), which is the only thing that has to persist. On a read-only container
filesystem, set `TERAT_CONFIG` to a writable path, or run `terat set` once at build
time and bake the file in — there is no separate environment interface for url,
key and model, so a "just export it" recipe does not exist.

## ACP: another program asks, instead of you

Everything above is one person typing. `terat acp` is the same engine with the
question coming from a program: an editor, a GUI, an agent framework. It speaks
[Agent Client Protocol](https://agentclientprotocol.com) v1 — JSON-RPC over stdio,
one message per line — so any ACP client can drive it without knowing terat exists.

```sh
terat acp     # JSON-RPC in, JSON-RPC out; configured by terat set url key model
```

The point is that it is **not a second program**. A turn is answered by this same
script in a subshell, so the terminal and the bridge cannot drift apart: same agent
table, same config, same trace, same answer. What the bridge adds is only what
JSON-RPC needs — ids, sessions, a stop reason.

| Method | What it does |
| --- | --- |
| `initialize` | answers protocol version 1, names this harness, advertises no optional capabilities |
| `session/new` | `cwd` becomes the working directory; `configOptions` offers the models `terat models` knows |
| `session/set_config_option` | switches the model for that session only |
| `session/prompt` | runs the turn: `user_message_chunk`, then `agent_message_chunk`, then `stopReason: end_turn` |
| `session/cancel` | stops the turn while it is still running, and ends it with `stopReason: cancelled` |
| anything else | `-32601 method not found`, with the method named |

Three decisions worth knowing, because each one is the opposite of the convenient
choice:

**No `fs/*` and no `terminal/*`.** Those are client capabilities an agent may call,
and implementing them means writing files on the client's behalf. terat's job is to
ask a question, so a method it does not implement says so by name rather than
answering `{}` — a silent success on `fs/write_text_file` would lose a client's edits.

**`loadSession: false`.** terat's thread is the terminal's scrollback. Claiming
replay would promise a store that does not exist.

**`set_config_option` writes nothing.** The model is an override for that session,
passed to the nested run as `TERAT_ACP_MODEL`, so a GUI switching models cannot
rewrite the saved default of whoever started it.

Three things it deliberately does not do yet, so nobody is surprised:

- **Sessions are in-memory.** A client restart gets a new `sess_N`; there is no
  `session/load` and no on-disk session store.
- **No MCP.** `session/new` accepts an `mcpServers` list and ignores it, because
  this bridge does not connect to MCP servers itself — it asks an agent, and the
  agent's own MCP configuration is what applies. The official conformance kit
  reports this as its one remaining advisory failure, which is the honest state.
- **`terat acp` must not be typed at a prompt.** Reading a terminal as JSON-RPC
  would eat keystrokes, so it refuses when stdin is a tty and points at
  `terat "what is acp"` instead. A client always arrives through a pipe.

The error codes are the spec's, not convenient approximations: `-32002` (Resource
not found) with the offending id in `data` for a session that does not exist,
`-32602` (Invalid params) for a `session/new` without `cwd` or a model value that
was never offered, and `-32600` (Invalid request) for anything arriving before
`initialize`. A client tells a stale session from its own mistake by those codes
alone, so getting one wrong is not cosmetic.

### Conformance

The protocol has an official test kit, and it found real bugs that no amount of
reading had. Run against this bridge:

```sh
uvx --from git+https://github.com/agentclientprotocol/acp-tck@v0.5.0 \
  acp-tck -- sh terat acp
```

**66 passed, 1 failed.** The failure is `ACP-SESSION-004`, the advisory MCP test
above. It started at 10 failures, and each one was a specific mistake worth
recording, because none of them were guessable:

| What the kit expected | What terat did |
| --- | --- |
| `session/new` without `cwd` → `-32602` | opened a session in the bridge's own directory |
| unknown session → `-32002` + `data.sessionId` | `-32602`, no data |
| any request before `initialize` → `-32600` | served it |
| unknown `configId`, unoffered value → `-32602` | accepted both |
| integer *and* string ids echoed with type | a string id came back **unquoted**, so the reply was not JSON |
| cancel mid-turn → `stopReason: cancelled` | answered `end_turn`, because the turn was synchronous |

A third bug was found by trying to use it rather than by testing it: `terat acp`
worked when run from the checkout and failed from `PATH` with "cannot find
terat-acp.awk". `terat` is normally installed as a **symlink** into a checkout, so
`$0` is the link and the helper is not beside it. The trace path had resolved this
for years; the bridge had not. The first claim written for it passed against the
broken build, because the `./terat-acp.awk` fallback means a cwd holding the helper
hides the bug — the claim now runs from a neutral directory.

The last two protocol failures were the instructive ones. The unquoted string id was a real bug in
a shipped code path, found only because a client sent `"id": "tck-string-id"`
instead of a number. And cancel was structurally impossible: the turn blocked, so
a stop button had nothing to reach. Making it interruptible needed the turn in the
background and a portable poll — `read -t` is not in dash at all and only takes
whole seconds in older bash, so the reader runs as its own process writing to a
file.

The bridge is about 340 lines in `terat`'s `acp)` branch — one `case` arm per
method — plus about 105 in `terat-acp.awk`, which does the only three things `sh`
cannot: read a field from a request, join the text of a prompt's content blocks,
and escape a string so it can sit inside JSON. No SDK, no Node, no jq: a machine
that can run `terat` can serve ACP.

Most of that length is the spec's error handling rather than the happy path, which
is the trade a bridge makes: the turn is a dozen lines, and telling a client
precisely what it did wrong is the rest.

## While it waits

A spinner turns on the line below the question and vanishes when the answer
arrives. pi sometimes prints its answer and then lingers instead of exiting,
so finishing cannot be inferred from the process ending.

To have the spinner sit on the question's line instead of the one below it:

```
export TERAT_SPIN=inline
```

It is drawn over the last cell of the question and erased before the answer, so
the question is never shortened; only the position of the frame changes. The
default is `below`, and unsetting the variable returns to it.

It also cannot be inferred from a pause in the output. `pi` is a coding agent:
asked to create a file, run a test or search a tree, it goes silent while the
tool works, and a file being created produces no output at all until the write
lands. Watching for a gap would kill exactly the runs worth waiting for. So
`terat` asks pi for `--mode json` and waits for the `agent_end` event it emits
when the agent is genuinely done.

There is no total time limit, because there cannot be a useful one. A tool call
is silent for as long as the tool runs — measured against `sleep 40`, the byte
count did not move at all between a `tool_execution_start` and its matching
`tool_execution_end`. Any ceiling short enough to rescue you from a wedged run
is therefore also short enough to kill a legitimate one. Two attempts to pick a
number proved it: 120 seconds killed a question that shelled out to a speedtest,
and 600 still killed a run asked to perform a half-hour soak test. Whatever
value is chosen, the next longer tool breaks it.

So the watchdog measures the right thing instead — **silence with no tool
running**:

- A `tool_execution_start` with no `tool_execution_end` after it means work is
  in progress. The clock is reset and the run may take as long as it needs.
- Otherwise, a few minutes without a single new byte means something is wrong,
  because pi streams deltas as the model generates: the longest real gap
  measured across a long generation was about five seconds.

`TERAT_MAX` is that quiet budget, in seconds — not a deadline. A 30-minute test
runs to completion; a wedged run returns the prompt. Ctrl-C cancels immediately
at any point.

The answer printed is the text of the last assistant message that spoke — a
turn that only called a tool has none, so its markup never reaches the prompt.

## Why answers are wrapped before printing

The model writes prose as one very long line — a single sentence can be 600
characters with no newline in it at all. A terminal does not wrap at word
boundaries; it breaks at the exact column, so that sentence arrived cut through
the middle of words (`serve` / `rs`, `aga` / `in`) with the left edge drifting.
`terat` now breaks the answer at spaces to the width of the terminal it is
printing to, taken from the terminal itself rather than `tput cols` — inside a
command substitution stdout is a pipe, so `tput` answers 80 whatever the window
really is. It stops one column short, because a line that fills the last column
leaves the terminal holding a pending wrap and the newline then opens a blank
line in the middle of the reply.

Only the printed answer is wrapped. Piped output stays exactly as it came, and
the transcript keeps the original line, so the context sent with the next
question is unaffected.

| Knob | Default | Effect |
| --- | --- | --- |
| `TERAT_CMD` | `pi -p --mode json` | the model command; stdin in, answer out |
| `TERAT_GRACE` | `40` | tenths of a quiet, used only for a plain-text command |
| `TERAT_MAX` | `180` | seconds of silence with no tool running before giving up — not a total limit |
| `TERAT_OUT` | `40` | how many lines of a command's output are kept |
| `TERAT_LIST` | `20` | how many names from the current directory are sent |
| `TERAT_THREAD` | `~/.terat/thread.$$` | transcript sent as context, one per shell |
| `TERAT_RAW` | `$TMPDIR/terat.$$.raw` | where `terat`-as-shell copies output; removed on exit |
| `TERAT_SHELL_BIN` | `/bin/zsh` | which shell `terat` starts in normal mode |
| `TERAT_AGENT` | `pi` | which agent answers; set by `terat set agent` or `terat <name>` |
| `TERAT_NAME` | the agent's name | label printed before an answer on a terminal |
| `TERAT_CONFIG` | `~/.config/terat/settings` | where `terat set` keeps url, key and model |
| `TERAT_SPIN` | `below` | `inline` puts the spinner on the question's line; `below` gives it its own |
| `TERAT_SYMBOL` | `🟅` | the glyph shown in ask mode |
| `TERAT_GLYPH` | `❯` | the prompt character it stands in for |
| `TERAT_OTLP` | unset | OTLP/HTTP JSON endpoint; unset means no tracing |
| `TERAT_OTLP_KEY` | unset | bearer token sent as `Authorization` |
| `TERAT_OTLP_DEBUG` | unset | `1` logs each post to `$TMPDIR/terat.otlp.log`; a path logs there |
| `TERAT_TRACE` | unset | `1` traces (ask mode's `Ctrl+X t` sets it); `0` turns tracing off for this shell |
| `TERAT_TRACE_ID` | minted by `--trace` | 32-hex trace id to propagate as `traceparent` |
| `TERAT_TRACE_PROVIDER` | `terat` for a generated config, else `router` | provider name `pi`'s extension registers the header against |

## Tracing

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

## Tests

`test/run.sh` installs terat into a container per distro — an empty home, no
`~/.zshrc`, nothing inherited — and asserts the claims that matter:

```sh
sh test/run.sh                # every distro
sh test/run.sh debian alpine  # a subset
```

bookworm, Ubuntu, Fedora, Alpine, Amazon Linux, bullseye (zsh 5.8) and Arch
(zsh 5.9.2, amd64 under emulation). Per distro: it parses under that `sh`,
`zsh` and `awk`; a question gets an answer; piped output stays raw; the prompt
becomes `🟅` through a real pty; the program's bare name typed at the prompt
flips the mode rather than being asked of the model; the transcript reaches the
question; and a missing agent is explained instead of relaying a shell error,
naming the agent that was actually asked.

The config layer is covered too, because a setting that only looks saved is
worse than none: `terat set` writes the file and reads it back, a refused agent
does not overwrite the saved one, a key is stored but never echoed, and `--`
keeps a question that begins with an agent name (`claude wrote this`) from being
taken as a request for that agent — including keeping the `--` out of the
question the model sees.

The suite is falsified on purpose: delete the transcript line or the glyph
fallback and it goes red, so a green run means something. Build failures are
printed rather than skipped, because a distro that never built otherwise looks
like a pass.

ACP has its own claims, and they follow the same rule — each was broken on purpose
and the suite went red. `initialize` answers version 1 and names terat; a full turn
streams `agent_message_chunk` and ends with `stopReason: end_turn`; every frame is
one whole JSON object and an answer holding a quote *and* a newline survives
escaping intact; an unknown session is an error rather than a silent success;
`fs/read_text_file` is refused by name; a numeric id comes back numeric, because a
client that sent `1` and got `"1"` cannot match the reply to its request; a model
switch does not touch the saved config; and `terat acp` refuses a terminal instead
of reading keystrokes as JSON-RPC.

Two of those claims were written wrong first and are worth remembering. The
escaping claim originally checked only that each line had both braces, which a
frame that drops what it cannot escape also satisfies — it passed against code with
the escaper removed, and had to be rewritten to assert the escaped content. The
model claim's first falsification attempt silently did not apply its edit, so the
"broken" build passed and proved nothing; the guard was real only once the edit was
verified to be in the file. A claim that cannot go red is not a claim.

`test/real-pi.md` covers running it against the real `pi` in a container.

The suite installs into `$HOME` and appends to `$HOME/.zshrc`, which is correct
in a throwaway container and destructive anywhere else: on a laptop that is the
real zshrc, once per run, and the `/tmp` copies it sources then shadow the real
install in every new shell. So it refuses to start when the home already holds a
zshrc it did not write, and `TERAT_TEST_HOME` points it at a scratch directory
for a host run:

```sh
TERAT_TEST_HOME=/tmp/terat_home sh test/check.sh
```

## Rules



- A failed call prints to stderr and exits non-zero; nothing is written to the
  thread and nothing pretends to be an answer.
- Answers are labelled `Pi:` on a terminal and left raw when piped, so
  `printf 'why?\n' | terat` stays scriptable.
- Questions are not shell commands and never reach your history.
