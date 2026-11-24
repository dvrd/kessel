'use strict';

const { linkSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } = require('node:fs');
const path = require('node:path');
const { setTimeout: delay } = require('node:timers/promises');
const { readChecksums, checksum, verifyCorpus } = require('../verifiers/verify_real_world_inputs');

const root = path.resolve(__dirname, '../..');
const corpus = path.resolve(root, process.argv[2] || 'bench/real_world');

function readSources() {
  const checksums = readChecksums();
  const manifest = readFileSync(path.join(root, 'tests/baselines/real_world.sources'), 'utf8');
  const sources = [];
  const pinned = /^(?:@[\w.-]+\/)?[\w.-]+@\d+\.\d+\.\d+(?:-[\w.-]+)?\/[\w.@/-]+$/;
  for (const line of manifest.trimEnd().split('\n')) {
    const [file, source] = line.split('  ');
    const digest = checksums.get(file);
    if (!digest || !pinned.test(source) || source.split('/').includes('..')) {
      throw new Error(`Invalid or duplicate corpus source: ${line}`);
    }
    checksums.delete(file);
    sources.push({ file, source, digest });
  }
  if (checksums.size) throw new Error(`Missing package source: ${checksums.keys().next().value}`);
  return sources;
}

function alreadyPresent(target, digest) {
  try {
    if (checksum(readFileSync(target)) !== digest) throw new Error(`Fixture checksum mismatch: ${target}`);
    return true;
  } catch (error) {
    if (error.code === 'ENOENT') return false;
    throw error;
  }
}

async function download(source, digest) {
  // Both CDNs serve individual files from the same versioned npm tarball.
  let lastError;
  for (const base of ['https://cdn.jsdelivr.net/npm/', 'https://unpkg.com/', 'https://cdn.jsdelivr.net/npm/']) {
    try {
      const response = await fetch(base + source, { signal: AbortSignal.timeout(45000) });
      if (!response.ok) {
        await response.body?.cancel();
        throw new Error(`HTTP ${response.status}`);
      }
      const bytes = Buffer.from(await response.arrayBuffer());
      if (checksum(bytes) !== digest) throw new Error('downloaded checksum mismatch');
      return bytes;
    } catch (error) {
      lastError = error;
      await delay(500);
    }
  }
  throw new Error(`${source}: ${lastError.message}`);
}

async function fetchCorpus() {
  const sources = readSources();
  mkdirSync(corpus, { recursive: true });
  const staging = mkdtempSync(path.join(corpus, '.download-'));
  const entries = sources.entries();
  const errors = [];
  let fetched = 0;
  async function worker() {
    for (const [index, { file, source, digest }] of entries) {
      try {
        const target = path.join(corpus, file);
        if (alreadyPresent(target, digest)) continue;
        const bytes = await download(source, digest);
        mkdirSync(path.dirname(target), { recursive: true });
        const temporary = path.join(staging, String(index));
        writeFileSync(temporary, bytes);
        // Another fetch can finish first. Publish only complete files and preserve existing data.
        try {
          linkSync(temporary, target);
          fetched++;
        } catch (error) {
          if (error.code !== 'EEXIST' || !alreadyPresent(target, digest)) throw error;
        }
        rmSync(temporary);
      } catch (error) {
        errors.push(`${file}: ${error.message}`);
      }
    }
  }
  try {
    await Promise.all(Array.from({ length: 6 }, worker));
  } finally {
    rmSync(staging, { recursive: true, force: true });
  }
  if (errors.length) throw new Error(errors.join('\n'));
  verifyCorpus(corpus);
  console.log(`Fetched ${fetched} of ${sources.length} pinned fixtures.`);
}

fetchCorpus().catch(error => {
  console.error(error.message);
  process.exitCode = 1;
});
