#!/usr/bin/env node
// agentq-skill: copy this package's `skill/` directory to where a Skill loader
// expects it.  It is a COPIER, not an installer.
//
// The distinction is the whole point.  AgentQ deploys by staging the platform
// directory on the target host and running that platform's installer
// (`sh install-agentq.sh`, or `install-agentq.ps1 -StageDirectory <dir>`).  This
// command does none of that: it moves 30 files on the machine you are sitting
// at, and the deployment step still has to happen afterwards, on the target.
// Anything that claimed otherwise would be the "npm installed it, so it must be
// deployed" mistake this repository exists to avoid.
//
// No dependencies and no postinstall: a network-installed package that runs
// arbitrary code at install time is refused by npm's own `strict-allow-scripts`
// in recent versions, and it is a security review flag everywhere else.
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const os = require('node:os');

const PROGRAM = 'agentq-skill';

// The eight files that must be executable after a copy.  `npm install` applies
// the caller's umask to the modes recorded in the tarball (measured: 0755 -> 0700
// under umask 077, and even a 0700 source lands as 0744), so the mode CANNOT be
// carried by the package -- it has to be re-applied here.
//
// This list is deliberately a copy of `skill_modes_expected_exec` in
// smoke/01-syntax-and-parity.sh, and smoke/01 asserts the two agree.  A second
// list is a liability; a second list that a check compares is a detection.
const EXECUTABLE = [
  'skill/assets/client/unix/agentq',
  'skill/assets/client/unix/install-client.sh',
  'skill/assets/client/unix/sshp',
  'skill/assets/client/windows/agentq.bash',
  'skill/assets/client/windows/sshp.bash',
  'skill/assets/unix/agentq',
  'skill/assets/unix/agentq-server',
  'skill/assets/windows-git-bash/agentq',
];

function usage(out) {
  const lines = [
    'Usage: agentq-skill [--dest <dir>] [--check] [--list] [--quiet]',
    '',
    'Copies this package\'s skill/ directory (30 files) to a destination,',
    'default ' + defaultDestination() + '.',
    '',
    '  --dest <dir>   where to copy to (created if absent)',
    '  --check        do not write; report whether the destination matches',
    '                 the packaged bytes and the eight executable modes',
    '  --list         print the packaged file list and exit',
    '  --quiet        only report failures',
    '',
    'Exit codes: 0 ok / match, 1 drift (--check only), 2 usage or unsafe path.',
    '',
    'This copies files.  It does not deploy AgentQ: after this, stage the',
    'platform directory on the target host and run that host\'s installer',
    '(see skill/references/install.md).',
  ];
  out.write(lines.join('\n') + '\n');
}

function defaultDestination() {
  const home = process.env.HOME || process.env.USERPROFILE;
  if (!home) return path.join('~', '.agents', 'skills', 'agentq');
  return path.join(home, '.agents', 'skills', 'agentq');
}

function fail(message) {
  process.stderr.write(PROGRAM + ': ' + message + '\n');
  process.exit(2);
}

// Every file under `skill/`, as repo-relative POSIX paths, sorted.  Sorting with
// a byte comparison keeps the list stable across hosts whose locale would order
// `SKILL.md` differently.
function listSkillFiles(packageRoot) {
  const out = [];
  const walk = (relative) => {
    const absolute = path.join(packageRoot, relative);
    let entries;
    try {
      entries = fs.readdirSync(absolute, { withFileTypes: true });
    } catch (error) {
      fail('cannot read ' + relative + ': ' + error.message);
    }
    for (const entry of entries) {
      const child = relative + '/' + entry.name;
      if (entry.isDirectory()) walk(child);
      else if (entry.isFile()) out.push(child);
      // A symlink inside skill/ would be a deployment hazard (the installers
      // refuse unsafe path chains); report it rather than silently skipping.
      else if (entry.isSymbolicLink()) fail('refusing a symlink inside the Skill: ' + child);
    }
  };
  walk('skill');
  out.sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
  return out;
}

function sha256(file) {
  return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
}

// The destination leaf must not be a symlink: writing through one would put the
// files somewhere the caller did not name, and the caller would then stage the
// wrong directory on the target host.
//
// Existing ANCESTORS are allowed to be symlinks.  They have to be: on macOS both
// `/var` and `/tmp` are symlinks, so refusing them would refuse every temporary
// destination -- measured 2026-11-24, the first version of this guard failed on
// its own test directory with `/var is a symlink`.  What matters is the leaf,
// which is the path this command creates or overwrites.
function assertSafeDestination(destination) {
  const resolved = path.resolve(destination);
  let stat;
  try {
    stat = fs.lstatSync(resolved);
  } catch (error) {
    if (error.code === 'ENOENT') return; // does not exist yet: this command creates it
    fail('cannot inspect ' + resolved + ': ' + error.message);
  }
  if (stat.isSymbolicLink()) fail('destination is a symlink: ' + resolved);
  if (!stat.isDirectory()) fail('destination exists and is not a directory: ' + resolved);
}

function main(argv) {
  let destination = defaultDestination();
  let destinationGiven = false;
  let check = false;
  let list = false;
  let quiet = false;

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    switch (arg) {
      case '-h':
      case '--help':
        usage(process.stdout);
        return 0;
      case '--dest': {
        const value = argv[index + 1];
        if (value === undefined || value === '') fail('--dest requires a directory');
        destination = value;
        destinationGiven = true;
        index += 1;
        break;
      }
      case '--check':
        check = true;
        break;
      case '--list':
        list = true;
        break;
      case '--quiet':
        quiet = true;
        break;
      default:
        // An unknown flag is a refusal, not something to ignore: `--dest=/x`
        // (with an equals sign) is a plausible typo, and treating it as "no
        // arguments" would copy to the default location instead.
        fail('unknown argument: ' + arg + ' (try --help)');
    }
  }
  if (!destinationGiven && destination.startsWith('~')) {
    fail('HOME is not set; export HOME or pass --dest <directory>');
  }

  const packageRoot = path.resolve(__dirname, '..');
  const files = listSkillFiles(packageRoot);

  if (list) {
    for (const file of files) process.stdout.write(file + '\n');
    return 0;
  }

  assertSafeDestination(destination);

  if (check) {
    let drifted = 0;
    for (const file of files) {
      const target = path.join(destination, file);
      let same = false;
      try {
        same = sha256(path.join(packageRoot, file)) === sha256(target);
      } catch (error) {
        same = false;
      }
      if (!same) {
        drifted += 1;
        process.stderr.write(PROGRAM + ': missing or different: ' + target + '\n');
      }
    }
    for (const file of EXECUTABLE) {
      const target = path.join(destination, file);
      let mode = 0;
      try {
        mode = fs.statSync(target).mode;
      } catch (error) {
        continue; // already reported as missing above
      }
      if ((mode & 0o111) === 0) {
        drifted += 1;
        process.stderr.write(PROGRAM + ': not executable: ' + target + '\n');
      }
    }
    if (drifted === 0) {
      if (!quiet) process.stdout.write(PROGRAM + ': ' + destination + ' matches (' + files.length + ' files)\n');
      return 0;
    }
    return 1;
  }

  for (const file of files) {
    const target = path.join(destination, file);
    fs.mkdirSync(path.dirname(target), { recursive: true });
    // `fs.copyFileSync` copies bytes only -- no newline or encoding conversion
    // happens here, which is what keeps the two canonical server copies
    // byte-identical after a copy.
    fs.copyFileSync(path.join(packageRoot, file), target);
  }
  for (const file of EXECUTABLE) fs.chmodSync(path.join(destination, file), 0o755);

  // The canonical pair is the package's own hard invariant; re-checking it here
  // costs one comparison and turns a corrupted copy or a mangled tarball into a
  // loud failure at the moment it happens.
  const left = path.join(destination, 'skill/assets/unix/agentq-server');
  const right = path.join(destination, 'skill/assets/windows-git-bash/agentq');
  if (!fs.readFileSync(left).equals(fs.readFileSync(right))) {
    fail('the two canonical server copies differ after the copy: ' + destination);
  }

  if (!quiet) {
    process.stdout.write(
      PROGRAM + ': copied ' + files.length + ' files to ' + destination + '\n' +
      PROGRAM + ': this is not a deployment. Stage the platform directory on the target host and run its installer.\n'
    );
  }
  return 0;
}

process.exitCode = main(process.argv.slice(2));
