# AgentQ

Remote task queue over SSH, backed by [Pueue](https://github.com/Nukesor/pueue) 4.0.4.

**Version:** 0.1.0 — the deployment unit (`skill/assets/`, 23 files) ships as one
version; releases are tagged in git and recorded in `CHANGELOG.md`.

Submit a command to a remote host and keep tracking it after your terminal closes.
Tasks live in the remote queue, so a dropped connection does not kill them.

```
agentq --host <host> submit --workdir /srv --label build --request-id nightly-01 -- make all
agentq --host <host> wait 7
agentq --host <host> logs 7 --tail 50
```

`sshp` is a separate, human-facing path: it attaches to a remote `tmux`, `screen`
or Zellij session and reconnects when the OpenSSH transport drops. Do not use
`sshp` to carry AgentQ tasks, and do not use AgentQ as an interactive terminal.

## What is in this repository

Everything that actually runs lives in `skill/` — one complete Skill, 25 files:

```
skill/
  SKILL.md             protocol contract and operating instructions
  agents/openai.yaml   Skill metadata
  assets/              the deployment unit — 23 files
    client/unix/       POSIX agentq, sshp, install-client.sh
    client/windows/    PowerShell / CMD / Git Bash clients and installer
    unix/              agentq-server, install-agentq.sh, pueue.yml, systemd/launchd units
    windows-git-bash/  agentq (the server, byte-identical to the unix copy),
                       durable-move, launcher, start-daemon, installer
```

`skill/` mirrors `~/.agents/skills/agentq/` one for one, so installing is a
single `rsync` of that directory. Everything else — the tests, the docs, the
sandbox script — exists to protect those files.

**Hard constraint:** `skill/assets/unix/agentq-server` and
`skill/assets/windows-git-bash/agentq` must stay byte-identical. `cmp` must return 0 at
all times; check `01` enforces it.

## Requirements

- **Local:** OpenSSH client. The POSIX client also needs `jq` (or `AGENTQ_JQ`
  pointing at an executable parser) — without it the client fails explicitly
  rather than treating unvalidated stdout as success.
- **Remote:** a POSIX shell, or Git Bash on Windows. The installer fetches the
  Pueue 4.0.4 binary and verifies it against a SHA-256 built into the installer
  before enabling it.

## Install

**Client** (macOS, Linux, WSL):

```sh
sh skill/assets/client/unix/install-client.sh
sh skill/assets/client/unix/install-client.sh --check          # read-only drift check
```

Installs `agentq` and `sshp` into `~/.local/bin`. `--check` reports `0` when the
installed clients match the canonical assets, `1` on drift, `2` on an unsafe
path — and never writes anything.

**Client** (Windows): `skill/assets/client/windows/install-client.ps1`, with the same
`-Check` contract.

**Server**: stage the platform directory to the target host, then run
`skill/assets/unix/install-agentq.sh` (or `skill/assets/windows-git-bash/install-agentq.ps1`).
The installer refuses to update while the queue has active or non-terminal tasks.

## Development

Three steps, and nothing else:

1. Change something under `skill/`.
2. Run `./run-tests.sh`.
3. Append a line to `CHANGELOG.md`.

```sh
./run-tests.sh          # all smoke checks; non-zero exit on failure
./run-tests.sh --quick  # only check 01 (syntax, byte-parity, PowerShell parse)
```

Some checks need a real runtime and skip without one. To run everything:

```sh
./sandbox.sh up
AGENTQ_SMOKE_HOME=/tmp/aqsb/home/.agentq ./run-tests.sh
./sandbox.sh down
```

**A skip is not a pass.** `run-tests.sh` prints `NOT A FULL PASS` when anything
skipped, and check `01` reports `ps1=skipped(...)` rather than a green light when
`pwsh` is unavailable or unusable.

**After changing anything under `skill/`, sync the whole directory** — it is the
install source, and nothing keeps the two in step automatically:

```sh
SKILL_DIR="${SKILL_DIR:-$HOME/.agents/skills/agentq}"
rsync -a --delete skill/ "$SKILL_DIR/"
diff -rq skill "$SKILL_DIR"   # must print nothing
```

Sync the *whole* directory, not just `assets/`: the previous rule synced only
`assets/`, which left `SKILL.md` free to drift — and it had, silently.

## Documentation

Start here:

| File | What it is |
| --- | --- |
| [`skill/SKILL.md`](skill/SKILL.md) | Protocol contract and operating instructions — the authoritative reference for exit codes, `cancel` semantics, and Windows terminal behaviour |
| [`CONTRIBUTING.md`](CONTRIBUTING.md) | How to contribute: the development loop, the load-bearing rules, and the full documentation map |
| [`CHANGELOG.md`](CHANGELOG.md) | One line per change, each with its verification result |

The maintainer documents — [`CLAUDE.md`](CLAUDE.md), [`docs/PLAN.md`](docs/PLAN.md)
and [`docs/HANDOFF.md`](docs/HANDOFF.md) — serve this repository's own maintenance
workflow. [`CONTRIBUTING.md`](CONTRIBUTING.md#documentation-map) is the authority
map: it lists every document, what each is authoritative for, and which one wins
when two disagree.

## Verification status

This is a working tool, not a finished product. Read `docs/验证状态与测试覆盖边界.md`'s coverage
table before trusting any claim about it — it records, per check, what is
proven and what is not. In particular:

- The smoke suite proves that the assets parse, that the two canonical copies
  agree, that bad arguments are rejected, and that the command surface has not
  drifted. **It does not prove that any branch behaves correctly.**
  `agentq-server` is untyped shell with no compiler and no type system.
- Real remote services, TLS/shared-key setups, and production credentials are
  **not** verified. Do not claim otherwise.
- `doctor` is **not** read-only: it starts the daemon if it is not running, which
  on macOS means `launchctl kickstart` and on Linux `systemctl --user start`.

## License

MIT — see [`LICENSE`](LICENSE).

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md). In short: change something under
`skill/`, run `./run-tests.sh`, and append a line to `CHANGELOG.md`.
