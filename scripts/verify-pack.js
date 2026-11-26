#!/usr/bin/env node
// Verify that what `npm pack` would publish is exactly what the repository
// holds: same file set, same bytes, same executable modes.
//
// Why this exists rather than trusting `npm pack`:
//   * `npm pack` reads the modes from DISK, not from the git index.  Measured
//     2026-11-24: a working tree whose three assets were chmod'ed to 0700 packs
//     to a tarball with a different SHA-256 than the same commit checked out
//     cleanly.  So the check has to compare modes, not just contents.
//   * `files: ["skill"]` is a whitelist that the root `.gitignore` does NOT
//     filter (measured: a planted `skill/assets/secret.key` was packed even with
//     `*.key` in .gitignore).  The repository's credential line of defence is
//     that ignore file, so the published file list must be pinned here.
//   * `npm publish` cannot be undone after 72 hours.  A file that should not be
//     public cannot be un-published, only deprecated.
//
// Usage: node scripts/verify-pack.js [--keep]
// Exit: 0 the tarball matches the tree, 1 it does not, 2 the checker itself
// could not run (missing npm, no tarball produced, ...).
'use strict';

const { execFileSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');

const PROGRAM = 'verify-pack';
// Files npm adds to every tarball beside the whitelist.  README/LICENSE are
// always included, package.json is mandatory, and every path named in `bin` is
// pulled in regardless of `files` -- measured 2026-11-24: the first version of
// this check reported bin/agentq-skill.js as an unexpected file, i.e. the check
// was wrong about npm and the tarball was right.  Derived from package.json so
// renaming the bin cannot silently exempt a stale entry.
function alwaysIncluded(root) {
  const manifest = JSON.parse(fs.readFileSync(path.join(root, 'package.json'), 'utf8'));
  const bins = typeof manifest.bin === 'string' ? [manifest.bin] : Object.values(manifest.bin || {});
  return ['package.json', 'README.md', 'LICENSE', ...bins.map((entry) => String(entry).replace(/^\.\//, ''))];
}

function fail(message) {
  process.stderr.write(PROGRAM + ': ' + message + '\n');
  process.exit(1);
}

function abort(message) {
  process.stderr.write(PROGRAM + ': cannot run the check: ' + message + '\n');
  process.exit(2);
}

function sha256(file) {
  return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
}

// The bytes the COMMIT holds, not the bytes on disk.
//
// Measured 2026-11-26: appending a line to skill/SKILL.md without staging it
// still printed `bytes identical`, because `npm pack` reads the working tree and
// the comparison read the same working tree -- both sides came from the dirty
// source, so the assertion could never fail.  The file-set check two screens up
// already compared against the INDEX for exactly this reason (the planted.key
// incident); the byte check never got the same treatment.  `git cat-file blob
// :<path>` is the index copy, so an unstaged or half-staged edit is caught.
function sha256Index(root, file) {
  return crypto
    .createHash('sha256')
    .update(execFileSync('git', ['cat-file', 'blob', ':' + file], { cwd: root }))
    .digest('hex');
}

function walk(absolute, relative, out) {
  for (const entry of fs.readdirSync(absolute, { withFileTypes: true })) {
    const childRelative = relative === '' ? entry.name : relative + '/' + entry.name;
    const childAbsolute = path.join(absolute, entry.name);
    if (entry.isDirectory()) walk(childAbsolute, childRelative, out);
    else if (entry.isFile()) out.push(childRelative);
    else fail('the tree contains a non-regular entry: ' + childRelative);
  }
  return out;
}

function main() {
  const root = path.resolve(__dirname, '..');
  const keep = process.argv.includes('--keep');
  const destination = fs.mkdtempSync(path.join(os.tmpdir(), 'agentq-pack-'));

  let packOutput;
  try {
    packOutput = execFileSync('npm', ['pack', '--pack-destination', destination, '--json'], {
      cwd: root,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
    });
  } catch (error) {
    abort('npm pack failed: ' + (error.stderr || error.message));
  }

  // `npm pack --json` answers an object keyed by package NAME (npm >= 7); older
  // versions answer an array.  Reading only one shape reports "cannot read the
  // report" against a perfectly good tarball -- measured 2026-11-24 with npm
  // 12.2.3, whose output is `{"agentq-skill": {...}}`.
  let tarball;
  try {
    const parsed = JSON.parse(packOutput);
    const entry = Array.isArray(parsed) ? parsed[0] : parsed[Object.keys(parsed)[0]];
    if (!entry || typeof entry.filename !== 'string') throw new Error('no filename in the report');
    tarball = path.join(destination, entry.filename);
  } catch (error) {
    abort('cannot read the npm pack report: ' + error.message);
  }
  if (!fs.existsSync(tarball)) abort('npm reported a tarball that does not exist: ' + tarball);

  // Extract with the system tar: this is what a user's `npm install` would
  // unpack, so verifying through it means verifying the real artifact rather
  // than a second implementation's idea of one.
  const unpacked = path.join(destination, 'unpacked');
  fs.mkdirSync(unpacked);
  try {
    // `-p`: preserve the archive's modes.  Without it tar masks them with the
    // caller's umask, and the mode comparison below would then be comparing the
    // umask rather than the tarball (measured: umask 077 turned a 0755 entry
    // into 0700 at extraction time).
    execFileSync('tar', ['-xzf', tarball, '-C', unpacked, '-p'], { stdio: 'pipe' });
  } catch (error) {
    abort('cannot extract the tarball: ' + (error.stderr || error.message));
  }
  const packageRoot = path.join(unpacked, 'package');
  if (!fs.existsSync(packageRoot)) abort('the tarball has no package/ root');

  // Two independent lists: what the repository tracks under skill/, and what the
  // tarball actually contains.  A whitelist that silently stopped matching would
  // produce an empty (and therefore trivially equal) comparison.
  const repoFiles = Array.from(
    execFileSync('git', ['ls-files', 'skill'], { cwd: root, encoding: 'utf8' })
      .split('\n')
      .filter((line) => line.length > 0)
  ).sort();
  if (repoFiles.length < 20) {
    abort('the repository enumeration found only ' + repoFiles.length + ' files under skill/');
  }
  const packedFiles = walk(packageRoot, '', [])
    .filter((file) => file === 'skill' || file.startsWith('skill/'))
    .sort();
  if (packedFiles.length === 0) abort('the tarball contains no skill/ files at all');

  let failures = 0;

  const missing = repoFiles.filter((file) => !packedFiles.includes(file));
  const extra = packedFiles.filter((file) => !repoFiles.includes(file));
  for (const file of missing) {
    process.stderr.write(PROGRAM + ': missing from the tarball: ' + file + '\n');
    failures += 1;
  }
  for (const file of extra) {
    process.stderr.write(PROGRAM + ': present in the tarball but not in the repository: ' + file + '\n');
    failures += 1;
  }

  // Nothing outside the whitelist plus the three files npm always adds.  This is
  // the credential guard: `.gitignore` does not filter a `files:` whitelist, so
  // a key or a scratch file under skill/ would be published silently.
  const allPacked = walk(packageRoot, '', []);
  const alwaysIncludedFiles = alwaysIncluded(root);
  // `git ls-files` -- not the working-tree walk -- is what "should be published"
  // means.  `files: ["skill"]` makes npm read the DIRECTORY, so an untracked file
  // sitting in it is packed even though `.gitignore` would keep it out of the
  // repository; measured 2026-11-24, a planted `skill/assets/planted.key` was
  // packed and the first version of this check called it consistent because it
  // was comparing the disk against the tarball.  Comparing against the INDEX is
  // the comparison that has a meaning.
  const tracked = new Set(
    execFileSync('git', ['ls-files', 'skill'], { cwd: root, encoding: 'utf8' })
      .split('\n')
      .filter((line) => line.length > 0)
  );
  for (const file of allPacked) {
    if (file.startsWith('skill/')) {
      if (!tracked.has(file)) {
        process.stderr.write(PROGRAM + ': untracked file would be published (files: is a directory whitelist, so .gitignore does not filter it): ' + file + '\n');
        failures += 1;
      }
      continue;
    }
    if (alwaysIncludedFiles.includes(file)) continue;
    process.stderr.write(PROGRAM + ': unexpected file in the tarball: ' + file + '\n');
    failures += 1;
  }

  // The manifest is the other half of what a consumer receives, and the file-set
  // check exempts it by NAME.  Measured 2026-11-26: `version: "9.9.9"` and a
  // `bin` pointing at a file that does not exist both passed, because nothing
  // read them.  A version that disagrees with the deployed assets publishes a
  // package that lies about what it carries; a bin that points nowhere ships a
  // package with no CLI at all.  npm.yml compares the version against the TAG,
  // but that only runs in CI on a tag push -- not on a local `npm run verify:pack`.
  const manifestRaw = JSON.parse(fs.readFileSync(path.join(packageRoot, 'package.json'), 'utf8'));
  const serverVersion = /^agentq_version='([^']+)'$/m.exec(
    fs.readFileSync(path.join(packageRoot, 'skill/assets/unix/agentq-server'), 'utf8')
  );
  if (!serverVersion) {
    process.stderr.write(PROGRAM + ': the tarball\'s agentq-server has no agentq_version line; the manifest version cannot be cross-checked\n');
    failures += 1;
  } else if (manifestRaw.version !== serverVersion[1]) {
    process.stderr.write(
      PROGRAM + ': package.json version ' + JSON.stringify(manifestRaw.version) +
      ' does not match the deployed assets (' + JSON.stringify(serverVersion[1]) + '); a consumer would get files of another version\n'
    );
    failures += 1;
  }
  const manifestBins = typeof manifestRaw.bin === 'string' ? [manifestRaw.bin] : Object.values(manifestRaw.bin || {});
  if (manifestBins.length === 0) {
    process.stderr.write(PROGRAM + ': package.json declares no bin; the package would ship without a CLI\n');
    failures += 1;
  }
  for (const entry of manifestBins) {
    const cleaned = String(entry).replace(/^\.\//, '');
    if (!fs.existsSync(path.join(packageRoot, cleaned))) {
      process.stderr.write(PROGRAM + ': package.json bin points at ' + JSON.stringify(cleaned) + ', which is not in the tarball\n');
      failures += 1;
    }
  }

  for (const file of repoFiles) {
    if (!packedFiles.includes(file)) continue;
    if (sha256Index(root, file) !== sha256(path.join(packageRoot, file))) {
      process.stderr.write(PROGRAM + ': bytes differ from the COMMITTED copy (the tarball carries the working tree, so an unstaged edit ships silently): ' + file + '\n');
      failures += 1;
    }
  }

  // Modes: stat the files extracted with `-p`, so the value is the archive's own
  // mode rather than the umask's idea of one.  The authority for the repository
  // is `git ls-files -s`.
  //
  // The first version parsed `tar -tvzf` with a six-field regex.  On this host
  // bsdtar prints `mode uname gname size date time name`, so the regex bound the
  // NAME field to "26 1985 package/..." -- every lookup then missed, and a
  // mismatch was silently skipped (`packed === undefined` -> continue).  Measured
  // 2026-11-24: `chmod 700` on an asset changed the tarball and the check stayed
  // green.  A comparison whose key never matches is not a comparison.
  const indexModes = new Map(
    execFileSync('git', ['ls-files', '-s', 'skill'], { cwd: root, encoding: 'utf8' })
      .split('\n')
      .filter((line) => line.length > 0)
      .map((line) => {
        const [mode, , , file] = line.split(/\s+/);
        return [file, mode === '100755' ? 0o755 : 0o644];
      })
  );
  let modesCompared = 0;
  for (const [file, mode] of indexModes) {
    const extracted = path.join(packageRoot, file);
    if (!fs.existsSync(extracted)) continue; // already reported as missing
    const packedMode = fs.statSync(extracted).mode & 0o777;
    modesCompared += 1;
    if (packedMode !== mode) {
      process.stderr.write(
        PROGRAM + ': mode ' + mode.toString(8) + ' in the index but ' + packedMode.toString(8) +
        ' in the tarball: ' + file + ' (npm pack reads the WORKING TREE, so a chmod in the checkout changes what is published)\n'
      );
      failures += 1;
    }
  }
  // Blind-counter guard: the loop above deciding nothing is indistinguishable
  // from it deciding everything was fine.
  if (modesCompared < 20) {
    abort('the mode comparison only reached ' + modesCompared + ' files; it is no longer reading the index');
  }

  // The package's own hard invariant, checked on the packed bytes.
  const left = path.join(packageRoot, 'skill/assets/unix/agentq-server');
  const right = path.join(packageRoot, 'skill/assets/windows-git-bash/agentq');
  if (fs.existsSync(left) && fs.existsSync(right) && !fs.readFileSync(left).equals(fs.readFileSync(right))) {
    process.stderr.write(PROGRAM + ': the two canonical server copies differ in the tarball\n');
    failures += 1;
  }

  // Read the size BEFORE removing the scratch directory: the first version did
  // it after, and reported ENOENT on its own success line.
  const size = fs.statSync(tarball).size;
  if (!keep) fs.rmSync(destination, { recursive: true, force: true });

  if (failures !== 0) {
    process.stderr.write(PROGRAM + ': ' + failures + ' problem(s); refusing to treat this tarball as publishable\n');
    return 1;
  }
  process.stdout.write(
    PROGRAM + ': ' + repoFiles.length + ' files, bytes identical, modes identical, ' +
    allPacked.length + ' entries, ' + size + ' bytes packed\n'
  );
  return 0;
}

process.exitCode = main();
