# AgentQ

Remote task queue over SSH, backed by [Pueue](https://github.com/Nukesor/pueue) 4.0.4.

**Version:** 0.1.51 — the deployment unit (`skill/assets/`, 23 files) ships as one
version; releases are tagged in git, indexed at the top of [`CHANGELOG.md`](CHANGELOG.md),
and verified by the [`release.yml`](.github/workflows/release.yml) tag/version gate.

Submit a command to a remote host and keep tracking it after your terminal closes.
Tasks live in the remote queue, so a dropped connection does not kill them.

```
agentq --host <host> submit --workdir /srv --label build --request-id nightly-build-01 -- make all
agentq --host <host> wait 7
agentq --host <host> logs 7 --tail 50
```

`sshp` is a separate, human-facing path: it attaches to a remote `tmux`, `screen`
or Zellij session and reconnects when the OpenSSH transport drops. Do not use
`sshp` to carry AgentQ tasks, and do not use AgentQ as an interactive terminal.

## What is in this repository

Everything that actually runs lives in `skill/` — one complete Skill, 30 files:

```
skill/
  SKILL.md             protocol contract and operating instructions (the operating summary)
  references/          the details behind it: contract, clients, install, doctor,
                       and the Windows installer path invariants
  agents/openai.yaml   Skill metadata
  assets/              the deployment unit — 23 files
    client/unix/       POSIX agentq, sshp, install-client.sh
    client/windows/    PowerShell / CMD / Git Bash clients and installer
    unix/              agentq (the 60-byte exec wrapper), agentq-server,
                       install-agentq.sh, pueue.yml, systemd/launchd units
    windows-git-bash/  agentq (the server, byte-identical to the unix copy),
                       durable-move, launcher, start-daemon, installer, pueue.yml
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
installed clients match the canonical assets **and are executable**, `1` on drift
(missing, different bytes, or a lost execute bit), `2` on an unsafe path — and
never writes anything. On a host that also runs the *server*, `~/.local/bin/agentq`
is a 60-byte wrapper and this installer refuses to write over it — use
`--bin-dir <dir>` there.

Both POSIX installers answer `--help` even when `HOME` is unset, and refuse to
*install* without it: exit `2`, one message, nothing written. The PowerShell
installers have no help switch at all — `-Help` fails parameter binding, so read
the comment block at the top of each file instead.

**Client** (Windows): `skill/assets/client/windows/install-client.ps1`, with the same
`-Check` contract.

**Server**: stage the platform directory to the target host, then run the platform
installer: `sh skill/assets/unix/install-agentq.sh` on Linux/macOS, or

```powershell
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File install-agentq.ps1 -StageDirectory <staged-platform-directory>
```

on Windows Git Bash targets. `-StageDirectory` is **mandatory** and must already hold
the five server assets (`agentq`, `agentq-launcher.ps1`, `agentq-start-daemon.ps1`,
`agentq-durable-move.ps1`, `pueue.yml`); adding `pueue-x86_64-pc-windows-msvc.exe` and
`pueued-x86_64-pc-windows-msvc.exe` selects the same-SHA-256 offline binary path.
The installer refuses to update while the queue has active or non-terminal tasks.

`install-agentq.sh` takes **no arguments**: `--help` prints its usage (and works
without `HOME` set), and anything else — including `--check`, which belongs to
the *client* installer above — is refused with exit `2` rather than ignored. It
used to ignore argv entirely, so `--check` performed a full, irreversible install.

### npm (getting the files for a version, not installing AgentQ)

`agentq-skill` on npm carries the same 30 files plus a copier:

```sh
npx agentq-skill@<version> --dest ~/.agents/skills/agentq
npx agentq-skill@<version> --dest ~/.agents/skills/agentq --check
```

`<version>` is this release's version, `0.1.51`. (Written as a placeholder on
purpose: a literal `<package>@<digits>` reads as an SSH `user@host` to the
host-identifier check, which is fail-closed and stays that way.)

**That is a file copy, not a deployment.** It writes on the machine you are
sitting at and nothing else; the target host is still reached by staging a
platform directory and running that host's installer, exactly as above. The
command says so on its own success line so the distinction does not depend on
reading this paragraph.

Pin the version: a bare `npx agentq-skill` takes whatever is latest, and the
deployment unit is one version across clients and server. The package needs no
`node` on the target host — only on the machine doing the copying.

Why a package at all: it is a versioned, content-addressed way to obtain the
files, and it is what a CI job or a colleague without this repository can pin.
It is not a substitute for any installer, and publishing is gated by
`scripts/verify-pack.js`, which refuses a tarball whose file set, bytes, modes or
canonical pair differ from the committed tree.

## Development

Three steps, and nothing else:

1. Change something under `skill/`.
2. Run `./run-tests.sh`.
3. Append a line to `CHANGELOG.md`.

```sh
./run-tests.sh          # all smoke checks; non-zero exit on failure
./run-tests.sh --quick  # only check 01 (syntax, byte-parity, PowerShell parse)
```

Step 3 has one hard requirement: every new log entry ends with a
`|  <measured verification>` line. Check `31` fails when the newest entry omits
it. The same check ties `CHANGELOG.md`'s version index to the tags in the
checkout: an index line with no tag, a tag with no index line, or an index out
of descending order all fail. See
[`CONTRIBUTING.md`](CONTRIBUTING.md#the-changelog-format) for the format and
[`CONTRIBUTING.md`](CONTRIBUTING.md#versioning-and-releases) for the release
ritual (annotated tags, three per push, all three layers updated together).

Some checks need a real runtime and skip without one. To run everything:

```sh
./sandbox.sh up
AGENTQ_SMOKE_HOME=/tmp/aqsb/home/.agentq ./run-tests.sh
./sandbox.sh down
```

**A skip is not a pass.** `run-tests.sh` prints `NOT A FULL PASS` when anything
skipped, and check `01` reports `ps1=skipped(...)` rather than a green light when
`pwsh` is unavailable or unusable. Checks that admit a **platform-inherent** gap
(a Windows-only code path on macOS/Linux) say so with `NOT-covered` and are
reported on their own `NOT-covered:` line rather than folded into the pass — CI
asserts every name on that line is in a known set (a subset test: a known name
dropping out is better coverage, an unknown name — a check newly claiming a gap
nobody has seen before — is red), so a new gap cannot hide as a green check.
The gate is by check name: a known check adding a further token is not
distinguished.

**A green CI run is not a gate on the tag.** `ci.yml` publishes only on
`push` to `main`/`pull_request`, and GitHub skips branch-filtered runs for tag
pushes, so pushing a tag starts `release` and `npm` immediately while the suite
for that same commit may still be running — or may already be red. Measured
2026-11-26: on v0.1.45 the three workflows started within five seconds of each
other, and `ci` needs ~13 minutes. Both tag workflows do their own cheap
checks (annotated tag, tag against every version constant, tarball against the
index), and `npm.yml` refuses to publish without `NPM_TOKEN`, so nothing ships
by accident — but "the suite was green" is a property of the COMMIT, and you
have to look at it yourself before pushing the tag. Making the tag wait would
mean triggering `release`/`npm` from `workflow_run` instead of `push`; that has
not been done and is not claimed.

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
| [`skill/SKILL.md`](skill/SKILL.md) | Operating summary: command surface, exit-code table, hard rules, workflow — with `skill/references/` holding the full contract, client and installer details behind it |
| [`CONTRIBUTING.md`](CONTRIBUTING.md) | How to contribute: the development loop, the load-bearing rules, and the full documentation map |
| [`CHANGELOG.md`](CHANGELOG.md) | One line per change, each with its verification result |

The maintainer documents — [`CLAUDE.md`](CLAUDE.md), [`docs/PLAN.md`](docs/PLAN.md),
[`docs/HANDOFF.md`](docs/HANDOFF.md), [`docs/verification-status.md`](docs/verification-status.md)
and [`docs/performance.md`](docs/performance.md) — serve this repository's own maintenance
workflow. [`CONTRIBUTING.md`](CONTRIBUTING.md#documentation-map) is the authority
map: it lists every document, what each is authoritative for, and which one wins
when two disagree.

## Verification status

This is a working tool, not a finished product. Read `docs/verification-status.md`'s coverage
table before trusting any claim about it — it records, per check, what is
proven and what is not. In particular:

- The smoke suite proves that the assets parse, that the two canonical copies
  agree, that bad arguments are rejected, and that the command surface has not
  drifted. It *does* also exercise real behaviour, but only where a check says
  so: `docs/verification-status.md` lists, per check, which branches run against
  a real runtime and which are only parsed or pattern-matched. Read that column
  rather than assuming either way — `agentq-server` is untyped shell with no
  compiler and no type system, so "it parsed" and "it works" are different
  claims, and the table keeps them apart.
- **Dedicated test machines are verified; production is not.** Real remote
  service has been exercised end to end on machines named by the user for that
  purpose — a Linux server (install/upgrade, `status`/`submit`/`lookup`/`wait`/
  `logs`/`remove`) and a Windows 10 client — most recently at 0.1.42, with the
  queue surviving the upgrade. That is the whole of the claim. Production hosts,
  production credentials, TLS/shared-key setups, cross-host concurrency and
  behaviour under real operational interruption are **not** verified; neither is
  a Windows *server* install, GBK hosts, or .NET 4.5.2. Do not claim otherwise —
  `docs/verification-status.md` keeps the itemised version of this boundary.
- `doctor` is **not** read-only: it starts the daemon if it is not running, which
  on macOS means `launchctl kickstart` and on Linux `systemctl --user start`.

## License

MIT — see [`LICENSE`](LICENSE).

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md). In short: change something under
`skill/`, run `./run-tests.sh`, and append a line to `CHANGELOG.md`.
