# Running terat against the real pi in a container

The stub harness proves terat's own plumbing. This proves the whole thing:
real `pi`, a real model, a real answer, inside Docker.

pi is a Node application — its payload is JavaScript, and it ships Linux
prebuilds (`native/linux/prebuilds/linux-arm64` and `linux-x64`), so the release
tree runs on Linux unmodified. It needs Node >= 22.19.

## What to mount

| Path | Why |
|---|---|
| `~/.pi/agent/install/releases/<version>` | pi's code. Read-only is fine. |
| a models config | pointed at a reachable endpoint |

**Never copy `auth.json` or `~/.pi/agent/models.json` into an image.** They hold
live keys. Mount a generated config at run time, copy it into a writable home,
`chmod 600`, and delete it afterwards. If the model router runs on the host, its
address inside a container is `host.docker.internal`, not `localhost`.

pi also needs a writable `~/.pi/agent/sessions`, or it dies with EACCES before
answering anything.

## Verified result

```
pi:   /pi/node_modules/.bin/pi        node: v22.20.0
real pi, piped:  [STILL_REAL_OK]      (5s)
🟅 Reply with exactly: TTY_REAL_OK
Pi: TTY_REAL_OK
```

Tracing from inside the container also returns `200` from the collector.

## Note

The first EACCES is not a terat finding — it is pi needing a writable sessions
directory, and the fix is to create it, not to change terat.
