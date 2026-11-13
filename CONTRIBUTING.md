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

A **platform-inherent** gap (a Windows-only code path on macOS/Linux) is
different: checks report it as `NOT-covered`, counted on their own
`NOT-covered:` line instead of triggering `NOT A FULL PASS` — it is a property
of the platform, not a run someone could have made better. CI still pins it:
every name on that line must be in a known set (a subset test -- a NEW name, a
check claiming a gap nobody has seen before, is red; a known name dropping out
means the platform covered more, which is fine). Details:
[`docs/verification-status.md`](docs/verification-status.md).

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
- **Do not change the committed file modes under `skill/assets/`.** The modes
  are deliberate per file (verified against `git ls-files -s`, 2026-10-13):
  `install-agentq.sh` is 644 (invoked as `sh ./install-agentq.sh`, no execute
  bit needed), as are the PowerShell/CMD assets, the service units and the
  `.yml` files; the POSIX clients (`agentq`, `sshp`, `install-client.sh`), the
  two `.bash` bridges, the unix wrapper, and the three server copies
  (`agentq-server` / two `agentq`) are 755 — `install-client.sh` REFUSES to run
  when its source assets are not executable.  Clearing an executable bit breaks
  the installer; adding one where there was none changes the deployment unit.
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
| [`CLAUDE.md`](CLAUDE.md) | Development order: the entry point — what is verified, what is not, and the boundaries that are not todos |
| [`docs/PLAN.md`](docs/PLAN.md) | **The only authoritative list of open work**; A/B entry records live in `docs/plan/` |
| [`docs/HANDOFF.md`](docs/HANDOFF.md) | Operating rules and limits |
| [`docs/verification-status.md`](docs/verification-status.md) | What is verified and what is not: the per-check coverage table, the false-green guards, the sandbox how-to |
| [`docs/performance.md`](docs/performance.md) | Subprocess and timing facts for `status` — read before touching a hot path |
| [`CHANGELOG.md`](CHANGELOG.md) | One line per change, each with its verification result |

A todo anywhere else — in a `docs/HANDOFF.md` history section, in a `CHANGELOG.md`
process note — is history, not a task. `docs/PLAN.md` is the list.

## Versioning and releases

AgentQ carries its own version, separate from Pueue's. The value is recorded in
**seven** places: the two installers, the server and its canonical twin (both
under `skill/assets/`, and `doctor` reports it as `agentq=`), the two clients, and
`README.md`. Check `01` compares **six** of them — the server twin is covered by
the byte-parity assertion instead, which requires the two server files to be
identical, so the twin cannot carry a different value from the server. The
release gate (`release.yml`) reads all seven, including the twin, because a tag
push does not run check `01`. Both installers' success messages must print the
AgentQ version rather than Pueue's. The two client constants joined on
2026-10-21 after a one-sided client bump left every check green — the deployment
unit is all 23 assets, so a version recorded in only some of them is not a
version at all.

The record set is **derived from the tree**, never hand-listed: the release gate
enumerates every file under `skill/assets/` that declares one of the constant
shapes, so a new record cannot leave the gate behind — check `01` fails until the
new file is also read by `release.yml`, on the same line as its own constant name.

- The version denotes **the deployment unit**: any change to the bytes under
  `skill/assets/` bumps it; documentation-only changes do not.
- **Releases are annotated tags.** `git tag -a vX.Y.Z -m "..."`, then push. A
  lightweight tag still passes the `release.yml` gate (it compares the name, not
  the object type), but the annotation carries the release note that links back
  to the `CHANGELOG.md` entry, and this repository has been inconsistent about
  that: seven of the first thirty-one tags were lightweight. New tags are
  annotated.
- **At most three tags per push.** Pushing more than three in one `push` does
  not trigger `release.yml` for the rest; they arrive silently ungated. Push in
  batches of three or fewer and check that the gate ran for each.
- A release updates **all three layers** together: tag → version-index line at
  the top of `CHANGELOG.md` → log entry. Check `31` fails when an index line
  names a tag that does not exist, when a tag has no index line, or when the
  index is not strictly descending. It reads the tags in the checkout, so a
  shallow clone reports `NOT-covered(no-tags-in-checkout)` instead of passing;
  CI checks out with `fetch-depth: 0` so the rule always runs there.
- There are no build artifacts to publish — the deployment unit is the `skill/`
  directory itself.
- Semver: a change to the protocol contract (exit codes, JSON fields, accepted
  arguments) is a minor or major bump; a fix that does not alter it is a patch.

## The changelog format

One entry per change, newest first, under `### 变更日志（2026-09-29 纳入 git 起 · 降序）`:

```
YYYY-MM-DD  what changed and what it does to behaviour
  |  ./run-tests.sh → exit 0 (counts)
```

- The first line states the change and its behavioural effect in one or two
  sentences. Investigation narrative, mutation proofs and lessons belong in
  `docs/PLAN.md`, not here.
- The `|` line is the change's **measured** verification — the exit code and the
  counts actually observed, never an expectation.
- **Every new entry carries a `|` line.** Check `31` fails when the newest entry
  does not. It does not scan older entries: entries written before this
  convention (short format from 2026-10-15; 137 of 227 in the descending section
  as of 2026-11-14) legitimately end without one, and rewriting history is not
  something this repository does. Rule `31` protects the next entry, not the
  archive; it prints the historical count instead of failing on it.
- Entries are newest first by the first line's date; `31` fails if a back-dated
  entry is inserted above the newest.

## Pull requests

- One change per commit, with its `CHANGELOG.md` line in the same commit.
- State the test result in the description: the `./run-tests.sh` summary line,
  and which checks were skipped and why. "Tests pass" without the summary line
  is not a result.
- If part of the change could not be verified on your machine, say so and put
  the unverified part in `docs/PLAN.md`. This project would rather record a boundary
  than claim coverage it does not have.

## Language

Outward-facing files (`README.md`, `CONTRIBUTING.md`, `LICENSE`) are English.
The internal working documents (`CLAUDE.md`, `docs/PLAN.md`, `docs/HANDOFF.md`,
`docs/verification-status.md`, `docs/performance.md`, `docs/plan/`, `CHANGELOG.md`,
`SKILL.md`) and the smoke checks' output are Chinese; that is
deliberate, not a translation backlog.
