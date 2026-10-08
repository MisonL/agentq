# Security policy

## Reporting a vulnerability

Use GitHub's private vulnerability reporting on this repository
(**Security → Report a vulnerability**). Please do not open a public issue for
a security problem.

Include what you have: the version the installer printed, the platform, how the
host is reached (key, ssh-agent, `AGENTQ_ASKPASS`), and the smallest
reproduction. Do not include passwords, private keys, or real hostnames.

## What to expect

This is a small project maintained on a best-effort basis. You will get an
acknowledgement, and credit in the `CHANGELOG.md` line of the fix unless you ask
otherwise.

## Scope notes

- The product is the 23 files under `skill/assets/`. The smoke checks in
  `smoke/` are the test suite, not the product — reports about them are still
  welcome, but say so.
- `doctor` starts the queue daemon when it is not running and rewrites request
  records on its success path. That is documented behaviour, not a
  vulnerability.
- Credentials are never supposed to touch this repository; if you find one that
  did, report it here rather than opening an issue.
