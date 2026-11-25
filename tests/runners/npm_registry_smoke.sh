#!/usr/bin/env bash
set -euo pipefail

# The release workflow publishes stable versions. Require an exact one so a
# previous release under the latest tag cannot satisfy this check.
number='(0|[1-9][0-9]*)'
if [[ $# != 1 || ! ${1:-} =~ ^$number\.$number\.$number$ ]]; then
  echo 'Usage: task test:npm:registry -- MAJOR.MINOR.PATCH' >&2
  exit 2
fi
version=$1
if [[ -n ${KESSEL_PACKAGE_BINARY:-} ]]; then
  KESSEL_PACKAGE_BINARY=$(node -p 'require("node:path").resolve(process.env.KESSEL_PACKAGE_BINARY)')
fi
consumer=$(mktemp -d "${TMPDIR:-/tmp}/kessel-registry.XXXXXX")
trap 'rm -rf -- "$consumer"' EXIT
cd "$consumer"
printf '{"name":"kessel-registry-smoke","private":true}\n' > package.json
unset NODE_PATH
npm install --registry=https://registry.npmjs.org --cache ./npm-cache \
  --include=optional --package-lock=true --no-audit --no-fund --save-exact "@dvrdlibs/kessel@$version"

node --input-type=module - "$version" <<'NODE'
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const version = process.argv[2];
const sdk = '@dvrdlibs/kessel';
const scope = 'node_modules/@dvrdlibs';
const main = require(`./${scope}/kessel/package.json`);
assert.equal(main.version, version);
const targets = ['darwin-arm64', 'darwin-x64', 'linux-arm64', 'linux-x64', 'win32-x64'];
assert.deepEqual(Object.keys(main.optionalDependencies).sort(), targets.map(target => `${sdk}-${target}`));
const { packages } = require('./package-lock.json');
for (const target of targets) {
  const name = `${sdk}-${target}`;
  assert.equal(main.optionalDependencies[name], version, name);
  const metadata = packages[`node_modules/${name}`];
  assert.ok(metadata, `Missing registry package ${name}@${version}`);
  assert.equal(metadata.version, version, name);
  const [os, cpu] = target.split('-');
  assert.deepEqual(metadata.os, [os], name);
  assert.deepEqual(metadata.cpu, [cpu], name);
  assert.equal(new URL(metadata.resolved).origin, 'https://registry.npmjs.org', name);
  assert.ok(metadata.integrity, name);
}

const target = `${process.platform}-${process.arch}`;
assert.deepEqual(fs.readdirSync(scope).sort(), ['kessel', `kessel-${target}`]);
assert.equal(require(`./${scope}/kessel-${target}/package.json`).version, version);
const native = require(`${sdk}-${target}`);
assert.ok(fs.statSync(native).isFile());
if (process.env.KESSEL_PACKAGE_BINARY) {
  const digest = file => createHash('sha256').update(fs.readFileSync(file)).digest('hex');
  assert.equal(digest(native), digest(process.env.KESSEL_PACKAGE_BINARY), 'Published native binary differs from the release artifact');
}
const { parseSync } = require(sdk);
const { parseAsync } = await import(sdk);
const source = 'const view: JSX.Element = <main />;';
const sync = parseSync('view.tsx', source);
assert.deepEqual(sync.errors, []);
assert.equal(sync.program.body[0].declarations[0].init.type, 'JSXElement');
assert.deepEqual(await parseAsync('view.tsx', source), sync);
assert.ok(parseSync('invalid.js', 'const = ;').errors.length > 0);
console.log(`Registry install passed for ${sdk}@${version} on ${target}, Node ${process.versions.node}`);
NODE
