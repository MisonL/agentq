## What changed

<!-- One or two sentences: which files moved, and why. -->

## Verification

<!-- Paste the summary line from ./run-tests.sh, verbatim. "Tests pass" without
     that line is not a result, and this repository is explicit about why: the
     line says how many checks ran, how many skipped, and how many were only
     partially verified. -->

```
PASS checks: N ran, N skipped, N partial, N failed (Ns)
```

- Checks skipped, and why:
- Anything that could not be verified on this machine (if it stays open, it
  belongs in PLAN.md):

## Checklist

- [ ] `./run-tests.sh` ran; its summary line is pasted above
- [ ] `CHANGELOG.md` has a line for this change, in this commit
- [ ] Nothing under `skill/assets/` had its line endings or execute bits
      changed (`.gitattributes` is `* -text`; the installers stay 644)
- [ ] If `skill/` changed: the whole directory was synced and `diff -rq` prints
      nothing; `cmp` on the two canonical server assets returns 0
- [ ] No credentials and no host identifiers in the diff
