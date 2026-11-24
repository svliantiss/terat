# Contributing

The whole program is one POSIX shell script (`terat`), one zsh file
(`terat.zsh`), and two awk files. There is no build step and no runtime
dependency beyond `sh`, `awk`, `grep`, `sed`, `od` and the agent itself.

That is the constraint worth protecting. A change that needs `node`, `python`,
`jq` or a package manager is a change that stops terat working in a bare
container, which is the main reason it exists in this form.

## Running the tests

```sh
TERAT_TEST_HOME=/tmp/terat_test sh test/check.sh
```

It prints `RESULT=PASS`, or `RESULT=FAIL` with the one claim that broke. It needs
`zsh`; the pty claims also need `tmux`. `TERAT_TEST_HOME` matters: the suite
installs itself into that home and appends to its `.zshrc`, so without it the
suite refuses to run rather than touching yours.

The suite is the documentation of behaviour. Each claim states a fact and is
written so it **fails when the code is wrong** — see the rule below.

## The rule

**Falsify before you trust.** A claim that passes is worth nothing until you have
watched it fail against broken code:

1. Make the change.
2. Break the code on purpose — delete the guard, restore the old behaviour.
3. Confirm the claim fails and names the real problem.
4. Restore, and confirm green twice in a row.

Nearly every bug in this project that survived a "passing" test was a test that
could not fail. If a claim cannot be made to fail, it is not testing anything.

## Adding an agent

Three edits in `terat`, and no ACP changes — the bridge asks `terat`, so it
learns the new agent on its own:

```sh
agents='pi claude codex opencode grok dsh newthing'   # 1. the list

agent_cmd() {                                          # 2. how to ask it
	case $1 in
	newthing) echo 'newthing --prompt {}' ;;   # {} = question in argv
	esac
}

agent_name() {                                         # 3. display name
	case $1 in
	newthing) echo Newthing ;;
	esac
}
```

Leave `{}` out if the harness reads the question on stdin. Then add a claim in
`test/check.sh` that runs it with `TERAT_CMD` stubbed, and add a row to the table
in `README.md`.

An agent you add also reaches `terat attach` and `terat models` without further
work; if its image handling differs from the others, say so in the `attach)`
arm so the matrix stays honest.

## Adding an ACP method

`terat acp` is a `case` with one arm per method. Add an arm, reply with
`acp_reply` or `acp_error` using the spec's error codes, and run the conformance
suite:

```sh
uvx --from git+https://github.com/agentclientprotocol/acp-tck@v0.5.0 \
  acp-tck -- sh terat acp
```

That needs `uv` and network. It is a development tool only; nothing shipped
depends on it.

## What not to do

- Do not add a runtime. If something needs a real language, it is probably the
  wrong shape for this tool.
- Do not make an advertised ACP capability a lie. If it is not implemented, do
  not advertise it — the conformance suite skips what you do not claim.
- Do not put a comment in that explains which bug was fixed. Say what the code
  does; git already remembers the archaeology.
- Do not silence an error to make a claim pass.

## Licence

MIT. By contributing you agree your work is released under it.
