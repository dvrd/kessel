'use strict';

const { execFileSync, spawnSync } = require('node:child_process');
const { appendFileSync } = require('node:fs');

const packageName = '@dvrdlibs/kessel';

function registryVersion(result) {
  if (result.error) throw result.error;
  if (result.signal) throw new Error('npm version lookup was interrupted by ' + result.signal);
  let response;
  try {
    response = JSON.parse(result.stdout);
  } catch {
    throw new Error('npm returned no readable version for ' + packageName + ' (exit ' + result.status + ')');
  }
  if (result.status !== 0) {
    const code = response?.error?.code;
    if (code === 'E404') return '0.1.0';
    throw new Error('Could not read the published version of ' + packageName + ' (' + (code || result.status) + ')');
  }
  if (typeof response !== 'string' || !/^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/.test(response)) {
    throw new Error('Expected a stable major.minor.patch version from npm');
  }
  return response;
}

function releaseBump(cwd) {
  const git = args => execFileSync('git', args, { cwd, encoding: 'utf8' });
  // With no reachable v* tag, --always returns the commit hash.
  const tag = git(['describe', '--tags', '--match', 'v*', '--abbrev=0', '--always', 'HEAD']).trim();
  const range = tag.startsWith('v') ? tag + '..HEAD' : 'HEAD';
  const fields = git(['log', '-z', '--format=%s%x00%b', range]).split('\0');
  let bump = 'patch';
  for (let i = 0; i + 1 < fields.length; i += 2) {
    const subject = fields[i];
    const body = fields[i + 1];
    if (/^(feat|refactor)(\([^)]+\))?!:|BREAKING CHANGE/.test(subject) ||
        /^BREAKING[ -]CHANGE:[ \t]*\S/m.test(body)) return 'major';
    if (/^(feat|refactor)(\([^)]+\))?:/.test(subject)) bump = 'minor';
  }
  return bump;
}

// Before 1.0.0 the public API is not yet declared stable (SemVer item 4), so
// a breaking change raises the minor version and anything else the patch:
// 0.21.0 becomes 0.22.0 for both a breaking change and a feature. Going to
// 1.0.0 is a deliberate decision, made by bumping the version by hand.
function nextVersion(current, bump) {
  const [major, minor, patch] = current.split('.').map(BigInt);
  if (major === 0n) {
    if (bump === 'major' || bump === 'minor') return [0, minor + 1n, 0].join('.');
    return [0, minor, patch + 1n].join('.');
  }
  if (bump === 'major') return [major + 1n, 0, 0].join('.');
  if (bump === 'minor') return [major, minor + 1n, 0].join('.');
  return [major, minor, patch + 1n].join('.');
}

if (require.main === module) {
  try {
    const current = registryVersion(spawnSync('npm', ['view', packageName, 'version', '--json', '--prefer-online'], { encoding: 'utf8' }));
    const bump = releaseBump(process.cwd());
    const version = nextVersion(current, bump);
    if (process.env.GITHUB_OUTPUT) appendFileSync(process.env.GITHUB_OUTPUT, 'version=' + version + '\nbump=' + bump + '\n');
    console.log(current + ' → ' + version + ' (' + bump + ')');
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}

module.exports = { registryVersion, releaseBump, nextVersion };
