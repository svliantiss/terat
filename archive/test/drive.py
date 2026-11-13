#!/bin/sh
# test/pty.py - drive a real terminal the way a person would, and print what
# the terminal received. Used to verify the in-place prompt without a human.
#
#   python3 test/pty.py --shell zsh --keys 'tert|what is 2+2|' 
#   python3 test/pty.py --shell bash --keys '^Xi|hello|'    (^X = ctrl-x)
#
# The environment is inherited, so TERAT_DIR / TERAT_BIN isolate a run.
import argparse, os, pty, select, sys, time

def pump(fd, seconds, sink):
    end = time.time() + seconds
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.05)
        if not r:
            continue
        try:
            d = os.read(fd, 65536)
        except OSError:
            return
        if not d:
            return
        sink.append(d.decode("utf-8", "replace"))

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--shell", default="/bin/zsh")
    ap.add_argument("--rc", default="")
    ap.add_argument("--prompt", default="❯ ")
    ap.add_argument("--keys", default="", help="|-separated; ^X = ctrl-x, \\n appended per field")
    ap.add_argument("--wait", type=float, default=1.5)
    ap.add_argument("--quiet", action="store_true")
    a = ap.parse_args()

    env = dict(os.environ)
    env.setdefault("TERM", "xterm-256color")
    env["PS1"] = a.prompt
    argv = [a.shell]
    if a.shell.endswith("zsh"):
        argv += ["-f", "-i"]
        if a.rc:
            argv += ["-c", f"source {a.rc}; exec zsh -f -i"]
    elif a.shell.endswith("bash"):
        argv += ["--norc", "--noprofile", "-i"]
        if a.rc:
            argv = [a.shell, "--norc", "--noprofile", "-c", f"source {a.rc}; exec bash --norc --noprofile -i"]
    else:
        argv += ["-i"]

    pid, fd = pty.fork()
    if pid == 0:
        try:
            os.execvpe(a.shell, argv, env)
        except OSError as e:
            print(f"exec failed: {e}", file=sys.stderr)
            os._exit(127)

    out = []
    time.sleep(0.7)
    pump(fd, 0.4, out)
    for field in a.keys.split("|"):
        if not field:
            continue
        newline = True
        if field.endswith("@"):
            field = field[:-1]
            newline = False
        seq = b""
        i = 0
        while i < len(field):
            if field[i] == "^" and i + 1 < len(field):
                seq += bytes([ord(field[i + 1].upper()) - 64])
                i += 2
            else:
                seq += field[i].encode()
                i += 1
        os.write(fd, seq + (b"\n" if newline else b""))
        pump(fd, a.wait, out)
    pump(fd, 0.8, out)
    text = "".join(out)
    if not a.quiet:
        print("----- raw -----")
        print(repr(text))
        print("----- as seen -----")
        sys.stdout.write(text)
        print("----- end -----")

if __name__ == "__main__":
    main()
