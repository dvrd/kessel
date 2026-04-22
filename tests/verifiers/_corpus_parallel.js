// Parallel corpus parser: spawn kessel processes with bounded concurrency,
// collect and parse results, invoke callbacks in original file order.
//
// This module replaces the serial `execSync` loop pattern with a worker pool
// that launches up to N workers in parallel (capped at min(cpus, 16)).
// Results are guaranteed to be processed in original file order for
// deterministic sample output.

'use strict';
const { spawn } = require('child_process');
const os = require('os');

// Parse every file in `files` with kessel (in parallel, bounded concurrency),
// call `onFile(tree, file)` for each successful parse. Returns once all files
// are done.
//
// Parallelism cap: min(os.cpus().length, 16). We cap at 16 because spawning
// 100+ kessel processes concurrently has no throughput upside (kessel is
// single-threaded-per-file and IO is cheap) and costs file descriptors.
//
// The file-order contract: `onFile` is called IN the original file order
// (even though parses happen concurrently). This keeps sample output
// deterministic across runs.
//
// Options:
//   kesselBin  (required) : absolute path to the kessel binary
//   onFile     (required) : function(tree, file) -> void, called per success
//   onError    (optional) : function(err, file) -> void, called per parse fail
//
// Returns: { parsed: number, parseFails: number }.
async function parseCorpusParallel(files, options) {
  const { kesselBin, onFile, onError } = options;

  // Concurrency limit: min(CPU count, 16).
  const concurrency = Math.min(os.cpus().length, 16);

  // Results array: store { ok: boolean, tree: ...*, error: ...* } by index.
  const results = new Array(files.length);

  let parsed = 0;
  let parseFails = 0;

  return new Promise((resolve) => {
    let nextCallbackIndex = 0;  // Next file to invoke onFile for
    let completed = 0;           // Number of files fully parsed

    // Attempt to invoke callbacks for any files that are ready (in order).
    function processReadyCallbacks() {
      while (nextCallbackIndex < files.length && results[nextCallbackIndex]) {
        const r = results[nextCallbackIndex];
        if (r.ok) {
          onFile(r.tree, files[nextCallbackIndex]);
          parsed++;
        } else {
          if (onError) onError(r.error, files[nextCallbackIndex]);
          parseFails++;
        }
        nextCallbackIndex++;
      }

      // Check if all files have been processed.
      if (completed === files.length && nextCallbackIndex === files.length) {
        resolve({ parsed, parseFails });
      }
    }

    // Spawn files with limited concurrency.
    let nextFileIndex = 0;
    let activeWorkers = 0;

    function spawnNextBatch() {
      while (nextFileIndex < files.length && activeWorkers < concurrency) {
        activeWorkers++;
        const fileIndex = nextFileIndex++;
        const file = files[fileIndex];

        // Spawn kessel parse process.
        const proc = spawn(kesselBin, ['parse', file, '--compact'], {
          stdio: ['ignore', 'pipe', 'ignore'],
        });

        const chunks = [];
        proc.stdout.on('data', (chunk) => {
          chunks.push(chunk);
        });

        proc.on('close', (code) => {
          if (code === 0 && chunks.length > 0) {
            try {
              // Concat all chunks and extract first line.
              const fullBuffer = Buffer.concat(chunks);
              const nlIndex = fullBuffer.indexOf('\n');
              const firstLineBuffer = nlIndex >= 0
                ? fullBuffer.slice(0, nlIndex)
                : fullBuffer;
              const firstLine = firstLineBuffer.toString('utf8');
              const tree = JSON.parse(firstLine);
              results[fileIndex] = { ok: true, tree };
            } catch (err) {
              // JSON parse error.
              results[fileIndex] = {
                ok: false,
                error: new Error(`Parse error: ${err.message}`),
              };
            }
          } else {
            // Process exited non-zero or no output.
            results[fileIndex] = {
              ok: false,
              error: new Error(`kessel exit code ${code}`),
            };
          }

          activeWorkers--;
          completed++;
          processReadyCallbacks();
          spawnNextBatch();
        });
      }
    }

    // Kick off initial batch of spawns.
    spawnNextBatch();
  });
}

module.exports = { parseCorpusParallel };
