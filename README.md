# tert

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
| `tert` | asks pi one question, prints the answer, remembers it |
| `terat.zsh` | the ask mode: glyph, Enter, `!`, Ctrl-C, plugins off |
| `terat.lua` | optional: the same thing under a Rex shortcut |

Shell only: `sh`, `sleep`, and `pi`. No python, no jq, no curl — pi does the
network.

## Install

```sh
ln -sf $PWD/tert ~/.local/bin/tert   # optional: for typing `tert` yourself
echo "source $PWD/terat.zsh" >> ~/.zshrc   # zsh ask mode
```

Sourcing `terat.zsh` is the whole install for ask mode: it runs the `tert` that
sits beside it, so the symlink is only needed if you want to type `tert` at the
prompt yourself.

### As your shell

Capture is on in every interactive shell that loads `terat.zsh` — open a terminal
however you like and normal commands are already recorded, with no `!` and no
piping:

```
~/Projects/terat ❯ ls
README.md  archive  terat.lua  terat.zsh  tert
~/Projects/terat ❯ @which of those is a folder?
Pi: `archive` is the only one.
```

`tert` with no question is also a shell — the same zsh, unchanged — for when you
would rather open one by that name:

```sh
ln -sf $PWD/tert ~/.local/bin/tert
# then open `tert` where you would open `zsh`
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

`tert` alone at the prompt still flips it too, for panes where the shortcut is
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
| `tert` | flips in place, either direction |
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

`tert` does not take the agent's hands away. It runs `pi` natively — the same
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
conversation — the thread is per shell, not per machine. `tert` works the name
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
README.md  archive  terat.lua  terat.zsh  tert
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
README.md   archive   terat.lua   terat.zsh   tert     # coloured, in columns
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
ls -l | tert "which of these is the largest?"
```

Two cheap facts go along with every question, so questions about what is in
front of you work without attaching anything:

```
Where: /home/dev/Projects/terat
Here: README.md archive terat.lua terat.zsh tert
```

That is where the shell is and what sits there, capped at 20 names, so it stays
under a kilobyte even in a directory with hundreds of entries. It lists what
plain `ls` lists — not dotfiles — because that is what you see on screen and so
what "those folders" means. A directory holding nothing but dotfiles still gets
them, and a truncated list ends with `... (38 in all)` so the model knows there
is more rather than assuming it has seen everything. Scrollback from before,
other tabs, and file *contents* are still invisible unless you `@`-mention a
path.

Set `TERAT_THREAD` to opt out and keep one conversation everywhere:

```sh
export TERAT_THREAD=~/.terat/thread     # one shared thread for every shell
```

Sharing is the thing that went wrong by accident: one file for every shell made
the model answer about another tab's work. Set this only if you want that.

`tert "a question"` asks once and prints the answer without entering the mode,
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
tert @shot.png "what is this?"
tert "#src" "summarise this folder"
```

## While it waits

A spinner turns on the line below the question and vanishes when the answer
arrives. pi sometimes prints its answer and then lingers instead of exiting,
so finishing cannot be inferred from the process ending.

It also cannot be inferred from a pause in the output. `pi` is a coding agent:
asked to create a file, run a test or search a tree, it goes silent while the
tool works, and a file being created produces no output at all until the write
lands. Watching for a gap would kill exactly the runs worth waiting for. So
`tert` asks pi for `--mode json` and waits for the `agent_end` event it emits
when the agent is genuinely done. A silent minute is then just work in
progress, and `TERAT_MAX` is only a backstop.

That last word is load-bearing, so the number has to match it. The stream goes
completely quiet while a tool runs — measured against `sleep 40`, the byte count
did not move once between the tool starting and finishing — so a timeout fires
mid-task rather than during a stall, and no smaller value is safe.

At 120 seconds that happened during real work: a question that shelled out to a
speedtest was killed while still thinking, lost its answer, and reported a
failure that read like the model's fault. The default is now 600.

Be aware that 600 is not a guarantee either. That same question took 125s on an
idle machine and over 420s when three ran back to back, because it calls
`networkQuality` twice at roughly 50 seconds a go and the tool time, not the
model, sets the duration. A question whose tools take longer than `TERAT_MAX`
will still be cut off, and the fix there is to raise `TERAT_MAX` for that
question — the error now says so instead of claiming the run ended without a
reply. Long tool calls are the one thing a fixed ceiling cannot accommodate;
what it should never do is fire on an ordinary question, which is what 120 did.

The answer printed is the text of the last assistant message that spoke — a
turn that only called a tool has none, so its markup never reaches the prompt.

## Why answers are wrapped before printing

The model writes prose as one very long line — a single sentence can be 600
characters with no newline in it at all. A terminal does not wrap at word
boundaries; it breaks at the exact column, so that sentence arrived cut through
the middle of words (`serve` / `rs`, `aga` / `in`) with the left edge drifting.
`tert` now breaks the answer at spaces to the width of the terminal it is
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
| `TERAT_MAX` | `600` | give up after this many seconds — a backstop, not a deadline |
| `TERAT_OUT` | `40` | how many lines of a command's output are kept |
| `TERAT_LIST` | `20` | how many names from the current directory are sent |
| `TERAT_THREAD` | `~/.terat/thread.$$` | transcript sent as context, one per shell |
| `TERAT_RAW` | `$TMPDIR/terat.$$.raw` | where `tert`-as-shell copies output; removed on exit |
| `TERAT_SHELL_BIN` | `/bin/zsh` | which shell `tert` starts in normal mode |
| `TERAT_NAME` | `Pi` | label printed before an answer on a terminal |
| `TERAT_SYMBOL` | `🟅` | the glyph shown in ask mode |
| `TERAT_GLYPH` | `❯` | the prompt character it stands in for |
| `TERAT_OTLP` | unset | OTLP/HTTP JSON endpoint; unset means no tracing |
| `TERAT_OTLP_KEY` | unset | bearer token sent as `Authorization` |
| `TERAT_OTLP_DEBUG` | unset | `1` logs each post to `$TMPDIR/terat.otlp.log`; a path logs there |
| `TERAT_TRACE_ID` | unset | 32-hex trace id to propagate as `traceparent` |
| `TERAT_TRACE_PROVIDER` | `router` | provider that carries the `traceparent` header |

## Tracing

Set `TERAT_OTLP` and each question is sent as one OpenTelemetry trace. It is off
until you do, and there is nothing to run alongside it — no collector, no agent,
no background process:

```sh
export TERAT_OTLP=https://api.lmnr.ai:443/v1/traces     # Laminar, OTLP/HTTP/json
export TERAT_OTLP_KEY=pk_...                            # project API key
```

Both can live in a `.env` next to `terat.zsh` instead of in `~/.zshrc`.
`terat.zsh` reads that file on load, taking only `TERAT_OTLP` and
`TERAT_OTLP_KEY` and ignoring everything else in it. It is parsed rather than
sourced: a file kept for one secret should not be able to run commands in every
shell. A value already set in the environment wins, so a one-off
`TERAT_OTLP=... tert` still overrides the file. Keep `.env` out of git — the repo
gitignores it.

Self-hosted Laminar here is `https://otlp.example.com/v1/traces`, and its UI lives
at `https://lm.example.com` behind HTTP basic auth.

### When a trace does not arrive

The post is fire-and-forget by default, on purpose: a collector being down must
never delay a prompt. The cost is that a wrong key is silent. Turn on the log
when you need to know:

```sh
TERAT_OTLP_DEBUG=1 tert 'why is the build failing?'
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
- **Failures are traced too.** A run that errored, or that hit `TERAT_MAX`
  before the model finished, still posts what it has: the question, the turns
  and tool calls that did happen, and no invented completion. These were the one
  class of run that produced no trace at all, which is backwards — a question
  that failed is the one worth looking at. A run that produced no events
  whatsoever has nothing to build a span from, and is still silent.
- **Silent when it cannot work.** No `curl`, no `awk`, an unwritable temp
  directory or an empty event stream all mean no trace, never a broken prompt.
- **A real `/v1/traces` path.** Unlike the OTel HTTP exporters, the path is not
  appended for you — put it in `TERAT_OTLP`, as above.

`terat-trace.awk` is the only file that knows what a span is. `tert` just runs
it and posts the result, so tracing can be deleted without touching the answer
path, and the answer path can be changed without touching tracing.

### Joining a trace to the router's ledger

The gateway already records every call it makes — model, tokens, cost, latency,
in `requests` and `agent_messages`. What it cannot record is the part that never
leaves the machine: which tools ran, in what order, from which directory, and
what was actually asked. Both halves are useful, and by default they share no
identifier.

A W3C `traceparent` fixes that. router reads `traceparent` and stores its trace
id as `requests.trace_id`; `tert` also uses that id for the OTLP spans. One
value then finds the same work in Laminar and in the router:

```sh
export TERAT_TRACE_ID=$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')
```

Make it one command per question, not per shell — the id should identify a
question, not a session. A loop or wrapper that sets it per call is enough.

`terat-trace.js` does the propagation. It is loaded with `pi -e`, so it exists
only for that run, and it returns immediately when `TERAT_TRACE_ID` is unset.

That indirection is deliberate. pi resolves provider headers strictly: a header
value that works out to nothing is a fatal error, not a skipped header. So the
obvious implementation — a `traceparent` entry in `models.json` — breaks every
plain `pi` on any machine where `TERAT_TRACE_ID` is not exported, which is every
machine but yours, and contradicts the point of installing one package.
Measured, with the variable absent:

```
API key auth failed for provider router: Failed to resolve provider
header "traceparent" from environment variables: TERAT_TRACE_ID
```

Loading it per run means there is no state to forget. `models.json` is never
edited and `pi` on its own stays exactly as it was. Confirmed both ways: with the
variables set the id reaches the router, and with them absent `pi` runs normally
and sends no `traceparent` at all.

This is optional in the same sense as `TERAT_OTLP`: nothing is propagated unless
you set an id, and setting one without `TERAT_OTLP` is still useful, because the
join lives in router's own database rather than in a trace backend.


### Which model answers

`tert` runs whatever `pi -p` resolves to, so the model is pi's business, not
terat's. On a machine where Passy Me is running, its local router is the route
that uses a subscription rather than a metered key:

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

Then `pi -p` routes there by default and `tert` needs no change. Check it with
`pi --list-models`, or ask `tert` and watch which route is used in the pi log.
A metered key (`api.passy.ai`) answers as the same model family but bills per
token; the subscription ids end in `-subscription` and only exist on the router.

### Other harnesses

`TERAT_CMD` takes any command that reads the question on stdin and writes the
answer on stdout, so a harness that works that way needs nothing else:

```sh
TERAT_CMD='some-agent -p' tert 'why is the build failing?'
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
  `tert` prints the first non-empty line the command wrote to stderr, so a
  missing key or a bad flag is visible instead of appearing as an empty answer.

Only `pi` is exercised by this project's own tests. The others are supported in
the sense that the contract is plain and the failure modes are visible, not in
the sense that each one has been verified end to end here.

## Rules

- A failed call prints to stderr and exits non-zero; nothing is written to the
  thread and nothing pretends to be an answer.
- Answers are labelled `Pi:` on a terminal and left raw when piped, so
  `printf 'why?\n' | tert` stays scriptable.
- Questions are not shell commands and never reach your history.
