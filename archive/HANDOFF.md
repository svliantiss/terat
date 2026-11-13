# terat — handoff

Status: **works in Rex and any shell. Terminal.app Service loads; assign the
shortcut to finish.**
Last verified: Rex, end to end. Terminal.app: Service loads without crashing.

## What terat is

Ask an AI a question at your shell prompt. The prompt becomes `🟅`, you ask,
read the answer, ask again. Your terminal is the thread. Empty line or Ctrl-C
returns you to `❯`. Nothing opens in a new tab.

```
❯ terat-ask
🟅 why did that build fail?
The missing semicolon on line 42...
🟅 and how do I fix it?
🟅                     ← empty line, back to ❯
```

## Files

All in `~/Projects/terat`, symlinked into `~/.local/bin`.

| File | Role | State |
| --- | --- | --- |
| `terat` | Engine. Question on stdin → answer on stdout. Context in `~/.terat/thread`. | Works |
| `terat-curl` | The model call. stdin → OpenAI-compatible endpoint → stdout. | Works |
| `terat-ask` | Runs the prompt loop as a command. What the Rex key types. | Works |
| `terat.zsh` | The `vared` widget + `_terat_loop` for zsh. | Works |
| `terat.lua` | Rex action + key binding. | Works |
| `terat.conf` | Harness map: `name = command`. | Works |
| `~/Library/Services/terat - ask.workflow` | Terminal.app Service. | Loads; shortcut not yet assigned |

Credentials in `~/.config/terat/env` (chmod 600):
`TERAT_URL` (router.example.com:443), `TERAT_KEY`, `TERAT_MODEL`.

## The one insight that matters

`terat` as a **foreground command can never replace `❯`**. starship draws the
prompt *before* the command runs, so the shell shows `❯` then terat prints its
own line below it. That is why earlier attempts "worked like a TUI".

The fix is **`vared`** — zsh's nested line editor. It owns the prompt while it
reads, so `🟅` genuinely replaces `❯`, and it stays inside ZLE, so there is no
mode to exit. This is the whole reason the current design works.

```zsh
vared -c -p '🟅 ' q     # -c creates $q; without it: "no such variable"
```

## Working: Rex

`terat.lua` binds `Ctrl+Shift+I` and `Cmd+Shift+I`. The action types `terat-ask`
into the focused pane via `block.event` (paste + key enter).

Rex claims the key before the shell sees it, so the shell-side `bindkey` never
fires there. Verified: `🟅` appears, answers, empty line returns to the shell.

Rebind or inspect:

```sh
rex config reload
rex keymap 2>&1 | grep terat
```

## Working: any shell

`terat.zsh` is sourced from `~/.zshrc` (line ~325). It binds:

| Key | Note |
| --- | --- |
| `Ctrl+X i` | two keys, works everywhere |
| `Option+i` | sends `ESC i` |

And `terat-ask` runs the same loop as a plain command.

## Terminal.app: fixed, needs the key assigned

`Ctrl+Shift+I` is **impossible** in Terminal.app. It sends `TAB` (0x09) for any
ctrl+i and has no way to represent the shift. No `bindkey` can fix this. There
is no kitty keyboard protocol support either (checked: no such settings in
`defaults read com.apple.Terminal`).

So the key must be a macOS Service. `~/Library/Services/terat - ask.workflow`
does that, and it now loads without crashing.

**What was wrong:** the first version was a hand-written `document.wflow`,
which made Automator throw `NSNull domain`. Fixed by taking Automator's own
output for `Claude - ask.workflow` and changing only the command — this
guarantees every key Automator expects is present. Two traps found:

- The action's parameters are at `actions[0].action.ActionParameters`, not
  `actions[0].ActionParameters`.
- `workflowMetaData` should use `inputTypeIdentifier` /
  `serviceInputTypeIdentifier`, not `serviceInputTypeIdentifier` alone.

Check it still loads (a crash prints `NSNull domain`; success prints `("")`):

```sh
plutil -lint ~/Library/Services/"terat - ask.workflow"/Contents/document.wflow
automator ~/Library/Services/"terat - ask.workflow"
/System/Library/CoreServices/pbs -update
/System/Library/CoreServices/pbs -dump_pboard | grep -A8 'terat - ask'
```

**Remaining step (manual, GUI):** assign the shortcut. System Settings →
Keyboard → Keyboard Shortcuts → Services → **terat - ask** → record
`Cmd+Shift+I`.

The Service runs `terat-ask` detached with `nohup`. It opens the prompt in a
new Terminal tab rather than the current one, because Services cannot write
into the calling terminal's input. If in-place behaviour matters, that needs a
Terminal.app profile with a startup command, or a different terminal.

## Not verified / open questions

- The Service loads, but the shortcut has not been assigned or tried.
- `terat.lua`'s `rex.exec` path was replaced by `block.event`; the `rex.exec`
  version failed with "rex: executable file not found in PATH" **only when run
  as a loaded action** (`rex do terat`), never when run as a file
  (`rex do ~/Projects/terat/terat.lua --action terat`). Root cause unknown.
  Not needed by the current design.
- `~/.config/starship.toml` was created to draw `🟅` via `TERAT_ON`. The
  current design does not use it (terat draws its own prompt). Harmless, but
  either delete it or wire `TERAT_ON` back in.

## Testing

Engine:

```sh
printf 'reply with exactly: OK\n' | ~/Projects/terat/terat
```

Prompt loop (needs a pty; `vared` only runs in a real terminal):

```sh
python3 - <<'PY'
import pty, os, select, time
pid, fd = pty.fork()
if pid == 0:
    os.execv("/bin/zsh", ["/bin/zsh","-i","-c",
      r'''source ~/Projects/terat/terat.zsh
q=""; vared -c -p $'\U0001F7C5 ' q </dev/tty; print "GOT=[$q]"'''])
out=b""; time.sleep(1.2); os.write(fd, b"hello\n")
t=time.time()
while time.time()-t<4:
    r,_,_=select.select([fd],[],[],0.3)
    if r:
        try: d=os.read(fd,4096)
        except OSError: break
        if not d: break
        out+=d
print(out.decode(errors="replace")[-400:])
PY
```

Ad-hoc Lua (no config reload needed):

```sh
rex do ~/Projects/terat/terat.lua --action terat --json
```

## Security

A router router key was pasted in plain text in an earlier session and reached
the transcript and `~/.pi/agent/extensions/remote-control/live-state.json`.
Redacted here so this note does not keep the leak alive. **Rotate it.**
