# terat

Ask an AI questions in your terminal, at the prompt itself.

```
❯ (press Ctrl+Shift+I)
🟅 why did that build fail?
The missing semicolon on line 42...
🟅 and how do I fix it?
🟅                      ← empty line returns you to ❯
❯
```

The prompt becomes `🟅`. You ask, read the answer, ask again. Your terminal is
the thread — each question and answer is remembered. An empty line or Ctrl-C
puts your ordinary `❯` back. Nothing opens in a new tab.

Works in **Rex** and **Terminal.app**. Plain `sh` + `curl` inside, so it works
over ssh too.

## Files

| File | What |
| --- | --- |
| `terat` | The engine. Question on stdin, answer on stdout, context in `~/.terat/thread`. |
| `terat-curl` | The model call: stdin -> OpenAI-compatible endpoint -> stdout. |
| `terat.conf` | Harness map: `name = command`. |
| `terat.zsh` | The prompt loop for zsh: a `vared` widget bound to a key. |
| `terat.lua` | Rex binding, because Rex claims the key before the shell sees it. |

## Install

```sh
ln -sf ~/Projects/terat/terat      ~/.local/bin/terat
ln -sf ~/Projects/terat/terat-curl ~/.local/bin/terat-curl
echo "source ~/Projects/terat/terat.zsh" >> ~/.zshrc          # shells
echo 'dofile(os.getenv("HOME").."/Projects/terat/terat.lua")' >> ~/.config/rex/init.lua
rex config reload

mkdir -p ~/.config/terat && cat > ~/.config/terat/env <<'ENV'
export TERAT_URL=https://router.example.com/v1/chat/completions
export TERAT_KEY=...
export TERAT_MODEL=some/model
ENV
```

## The key

| App | Key | How |
| --- | --- | --- |
| Rex | `Ctrl+Shift+I` | `terat.lua` types the key into the pane |
| Any shell | `Ctrl+X i` or `Option+i` | `bindkey` in `terat.zsh` |
| Terminal.app | `Cmd+Shift+I` | the **terat - ask** Service, below |

Terminal.app cannot send `Ctrl+Shift+I`: it sends `TAB` for any ctrl+i, with no
way to represent the shift. Use the Service instead — System Settings →
Keyboard → Keyboard Shortcuts → Services → **terat - ask**, and record
`Cmd+Shift+I` there. (The Service file lives in `~/Library/Services`.)

## Engines

`terat` uses `terat-curl` by default. Name another, or add one to `terat.conf`:

```sh
printf 'why is the sky blue\n' | terat claude    # claude -p
printf 'why is the sky blue\n' | terat pi        # pi -p --no-tools
```

Any program that reads a prompt on stdin and writes an answer on stdout works.

## Environment

| Variable | Default |
| --- | --- |
| `TERAT_URL` | `https://router.example.com/v1/chat/completions` |
| `TERAT_KEY` | from `~/.config/terat/env` |
| `TERAT_MODEL` | `some/model` |
| `TERAT_DIR` | `~/.terat` — holds `thread` |
