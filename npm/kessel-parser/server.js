/**
 * kessel-parser server pool — long-lived subprocess bridge (ASYNC).
 *
 * Spawns a single `kessel server` child and multiplexes async parse
 * requests over its stdin / stdout. Replaces the spawn-per-call path
 * for throughput-sensitive consumers — startup cost amortises across
 * requests.
 *
 * Sync NAPI bindings remain the long-term goal for `parseSync`;
 * this module ships the intermediate async API that eliminates the
 * spawn-per-call overhead without a native addon.
 *
 * Protocol (see src/main.odin run_server_mode):
 *   Request:  '<path>\n'
 *   Response: '<json body>\n<stats+errors>\n@@KESSEL_END\n'
 *
 * The server process inherits the flags it was spawned with, so this
 * module caches one server per distinct flag set. Most callers use a
 * single flag set; the cache grows at most O(distinct-opt-combinations).
 *
 * Usage:
 *   const { parse } = require('kessel-parser/server');
 *   const { program, errors } = await parse('foo.js', source, opts);
 *   // Or with a pre-written file on disk:
 *   const { program, errors } = await parseFile('/abs/path.js', opts);
 */

'use strict';

const { spawn } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const SENTINEL = '@@KESSEL_END';

// One server instance per distinct (binary, flags) combination.
const servers = new Map();

class Server {
  constructor(binary, flags) {
    this.binary = binary;
    this.flags = flags;
    this.child = null;
    this.queue = [];       // [{resolve, reject, deadline}]
    this.buffer = '';
    this.stderrBuf = '';
    this.start();
  }

  start() {
    this.child = spawn(this.binary, ['server', ...this.flags], {
      stdio: ['pipe', 'pipe', 'pipe'],
      windowsHide: true,
    });
    this.child.stdout.setEncoding('utf8');
    this.child.stderr.setEncoding('utf8');

    this.child.stdout.on('data', (chunk) => {
      this.buffer += chunk;
      this.drain();
    });
    this.child.stderr.on('data', (chunk) => {
      this.stderrBuf += chunk;
    });
    this.child.on('exit', (code, sig) => {
      // Drain pending requests with an error.
      for (const req of this.queue) {
        req.reject(new Error(`kessel server exited code=${code} signal=${sig}; stderr: ${this.stderrBuf.slice(-500)}`));
      }
      this.queue = [];
      this.child = null;
    });
  }

  // Pull one complete response from the buffer if the sentinel is present.
  drain() {
    const sentinelLine = '\n' + SENTINEL + '\n';
    while (this.queue.length > 0) {
      const idx = this.buffer.indexOf(sentinelLine);
      if (idx < 0) return;
      const body = this.buffer.slice(0, idx);
      this.buffer = this.buffer.slice(idx + sentinelLine.length);
      const req = this.queue.shift();
      req.resolve(body);
    }
  }

  parseAsync(absPath) {
    return new Promise((resolve, reject) => {
      if (!this.child || this.child.exitCode !== null) this.start();
      const req = { resolve, reject };
      this.queue.push(req);
      try {
        this.child.stdin.write(absPath + '\n');
      } catch (e) {
        // Write failed; remove from queue and reject.
        const ix = this.queue.indexOf(req);
        if (ix >= 0) this.queue.splice(ix, 1);
        reject(e);
      }
    });
  }

  shutdown() {
    if (this.child) {
      try { this.child.stdin.end(); } catch (_) {}
      try { this.child.kill(); } catch (_) {}
      this.child = null;
    }
  }
}

function findBinary() {
  const localBin = path.resolve(__dirname, '../../bin/kessel');
  if (fs.existsSync(localBin)) return localBin;
  const platform = process.platform;
  const arch     = process.arch;
  const bundled  = path.join(__dirname, 'bin', `kessel-${platform}-${arch}`);
  if (fs.existsSync(bundled)) return bundled;
  throw new Error(`kessel-parser: cannot locate Kessel binary (tried ${localBin} and ${bundled}).`);
}

function flagsFromOpts(opts = {}) {
  const flags = ['--compact'];
  if (opts.sourceType && opts.sourceType !== 'unambiguous') flags.push(`--source-type=${opts.sourceType}`);
  if (opts.preserveParens) flags.push('--preserve-parens');
  if (opts.loc)   flags.push('--loc');
  if (opts.range) flags.push('--range');
  if (opts.showSemanticErrors) flags.push('--show-semantic-errors');
  if (opts.strictSourceType)   flags.push('--strict-source-type');
  return flags;
}

function getServer(opts = {}) {
  const binary = opts.binary || findBinary();
  const flags = flagsFromOpts(opts);
  const key = [binary, ...flags].join('\x1f');
  let srv = servers.get(key);
  if (!srv || !srv.child || srv.child.exitCode !== null) {
    if (srv) srv.shutdown();
    srv = new Server(binary, flags);
    servers.set(key, srv);
  }
  return srv;
}

// Parse source text. Writes source to a temp file on each call
// (kessel server reads file paths, not raw bodies) then parses.
async function parse(filename, source, opts = {}) {
  const ext = path.extname(filename) || '.js';
  const tmp = path.join(os.tmpdir(), `kessel_${process.pid}_${Date.now()}_${Math.random().toString(36).slice(2)}${ext}`);
  fs.writeFileSync(tmp, source, 'utf8');
  try {
    const body = await getServer(opts).parseAsync(tmp);
    return shapeResponse(body);
  } finally {
    try { fs.unlinkSync(tmp); } catch (_) {}
  }
}

// Parse a file already on disk. No temp file; avoids the fs.writeFileSync
// on hot-loop callers that already have their content on disk.
async function parseFile(absPath, opts = {}) {
  const body = await getServer(opts).parseAsync(absPath);
  return shapeResponse(body);
}

function shapeResponse(body) {
  // Strip the statistics block that parse_file appends after the JSON.
  const statsIdx = body.indexOf('\n--- Statistics ---');
  const jsonPart = statsIdx >= 0 ? body.slice(0, statsIdx) : body;
  const ast = JSON.parse(jsonPart);
  return {
    program:  ast,
    comments: ast.comments || [],
    errors:   ast.errors || [],
  };
}

function shutdownAll() {
  for (const srv of servers.values()) srv.shutdown();
  servers.clear();
}

// Clean up on process exit so stray subprocesses don't linger.
process.on('exit', shutdownAll);

module.exports = { parse, parseFile, getServer, shutdownAll };
