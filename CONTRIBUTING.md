# Contributing

AgentQ is a remote task queue over SSH, backed by
[Pueue](https://github.com/Nukesor/pueue). Everything that actually runs lives
in `skill/` — one complete Skill, 25 files (`SKILL.md` + `agents/` + the 23
assets under `assets/`). Everything else in this repository — the tests, the
documentation, the sandbox script — exists to protect those files.

## The development loop

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
skipped or was only partially verified, and check `01` reports
`ps1=skipped(...)` instead of a green light when `pwsh` is unavailable or
unusable. Read the summary line before claiming a run succeeded.

## Rules that are not style preferences

These are load-bearing. A change that breaks one of them is a defect even if
every check still passes.

- **The deployment unit is all 23 assets at one version.** Never upgrade the
  server alone, or a client alone. There is no protocol version negotiation
  field: `doctor`'s `agentq=` line is informational (it says which AgentQ
  version is deployed, so a one-sided upgrade is visible) and `pueue=`/`pueued=`
  is the queue implementation's version. Neither negotiates anything.
- **`skill/assets/unix/agentq-server` and `skill/assets/windows-git-bash/agentq`
  must stay byte-identical.** `cmp` must return 0 at all times; check `01`
  enforces it.
- **Never convert line endings under `skill/assets/`.** That is why
  `.gitattributes` uses `* -text`: the assets are deployed as they are stored,
  and one conversion breaks the byte-parity above.
- **Do not set the execute bit on files under `skill/assets/`.** The installers
  are invoked as `sh ./install-agentq.sh`; the mode is deliberate.
- **After changing anything under `skill/`, sync the whole directory.** It is
  the install source, and nothing keeps the two copies in step automatically:

  ```sh
  SKILL_DIR="${SKILL_DIR:-$HOME/.agents/skills/agentq}"
  rsync -a --delete skill/ "$SKILL_DIR/"
  diff -rq skill "$SKILL_DIR"   # must print nothing
  ```

- **Credentials never enter the repository, a script, or a log.** No passwords,
  no askpass helpers, no keys. If reaching a host needs a password, say so in
  the pull request; do not commit one.
- **No host identifiers.** Hostnames, IP addresses, account names and machine
  names stay out of the repository. Check `16` enforces seven shapes of them
  and scans the whole tree.
- **`doctor` is not read-only.** It starts the queue daemon when it is not
  running (`launchctl kickstart` on macOS, `systemctl --user start` on Linux),
  and its success path rewrites request records. Do not run it against a host
  you are not authorized to change.

## Documentation map

Each document has one job. Where two disagree, the one whose job it is wins.

| File | Authoritative for |
| --- | --- |
| [`skill/SKILL.md`](skill/SKILL.md) | The protocol contract: exit codes, `cancel` semantics, Windows terminal behaviour, installation steps |
| [`README.md`](README.md) | The front door: what this is, how to install it, how to run the tests |
| [`CLAUDE.md`](CLAUDE.md) | Development order: what is verified, what is not, and each check's coverage boundary |
| [`PLAN.md`](PLAN.md) | **The only authoritative list of open work** |
| [`HANDOFF.md`](HANDOFF.md) | Operating rules and limits |
| [`CHANGELOG.md`](CHANGELOG.md) | One line per change, each with its verification result |

A todo anywhere else — in a `HANDOFF.md` history section, in a `CHANGELOG.md`
process note — is history, not a task. `PLAN.md` is the list.

## Versioning and releases

AgentQ carries its own version, separate from Pueue's. The value is recorded in
the two installers, in the server (which `doctor` reports as `agentq=`) and in
`README.md`; check `01` asserts those copies agree and that both installers'
success messages print the AgentQ version rather than Pueue's.

- The version denotes **the deployment unit**: any change to the bytes under
  `skill/assets/` bumps it; documentation-only changes do not.
- Releases are git tags (`vX.Y.Z`), with release notes pointing at the matching
  `CHANGELOG.md` entries. There are no build artifacts to publish — the
  deployment unit is the `skill/` directory itself.
- Semver: a change to the protocol contract (exit codes, JSON fields, accepted
  arguments) is a minor or major bump; a fix that does not alter it is a patch.

## Pull requests

- One change per commit, with its `CHANGELOG.md` line in the same commit.
- State the test result in the description: the `./run-tests.sh` summary line,
  and which checks were skipped and why. "Tests pass" without the summary line
  is not a result.
- If part of the change could not be verified on your machine, say so and put
  the unverified part in `PLAN.md`. This project would rather record a boundary
  than claim coverage it does not have.

## Language

Outward-facing files (`README.md`, `CONTRIBUTING.md`, `LICENSE`) are English.
The internal working documents (`CLAUDE.md`, `PLAN.md`, `HANDOFF.md`,
`CHANGELOG.md`, `SKILL.md`) and the smoke checks' output are Chinese; that is
deliberate, not a translation backlog.
