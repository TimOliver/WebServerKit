#!/usr/bin/env node
// Real Chromium, disposable owned servers, and deliberate transport interruptions.
// No server URL is accepted: this runner launches and owns every contacted server.
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { EventEmitter } from 'node:events';
import fs from 'node:fs/promises';
import http from 'node:http';
import { isIP } from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { createInterface } from 'node:readline';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const CHROME = process.env.WSK_CHROME_EXECUTABLE || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const MIB = 1024 * 1024;
const sleep = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));
const digest = bytes => createHash('sha256').update(bytes).digest('hex');

function argumentsFor(argv) {
  const result = { baseline: false, listenAddress: '127.0.0.1' };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--baseline') result.baseline = true;
    else if (argv[i] === '--listen-address' && argv[i + 1]) result.listenAddress = argv[++i];
    else if (['--host', '--report', '--temporary-library'].includes(argv[i]) && argv[i + 1]) {
      result[argv[i].slice(2)] = path.resolve(argv[++i]);
    } else throw new Error('Usage: browser-probe.mjs --host PATH --report PATH [--temporary-library PATH] [--listen-address IPv4] [--baseline]');
  }
  assert(result.host && result.report, '--host and --report are required');
  assert(isIP(result.listenAddress) === 4 && result.listenAddress !== '0.0.0.0',
    '--listen-address must be one specific local IPv4 address, not a wildcard');
  result.temporaryLibrary = result['temporary-library'] || path.join(path.dirname(result.host), 'EnduranceTemporaryDirectory.dylib');
  return result;
}

async function eventually(description, check, timeout = 20000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    const result = await check();
    if (result) return result;
    await sleep(50);
  }
  throw new Error(`Timed out: ${description}`);
}

function fixture(name, size, salt = 0) {
  const bytes = Buffer.alloc(size);
  for (let i = 0; i < size; i++) bytes[i] = (i * 31 + salt) % 251;
  return { name, mimeType: 'application/octet-stream', buffer: bytes, sha256: digest(bytes) };
}

async function filesBelow(directory) {
  const result = [];
  async function visit(current, prefix) {
    for (const entry of await fs.readdir(current, { withFileTypes: true }).catch(error => {
      if (error.code === 'ENOENT') return [];
      throw error;
    })) {
      const relative = path.join(prefix, entry.name);
      if (entry.isDirectory()) await visit(path.join(current, entry.name), relative);
      else result.push(relative);
    }
  }
  await visit(directory, '');
  return result.sort();
}

class Host {
  constructor(options, root, report, log) {
    this.options = options;
    this.root = root;
    this.report = report;
    this.log = log;
    this.replies = [];
    this.waiters = [];
  }

  async start() {
    this.replies = [];
    this.child = spawn(this.options.host, [path.join(this.root, 'share'), path.join(this.root, 'dav')], {
      env: { ...process.env, TMPDIR: path.join(this.root, 'tmp') + '/',
        DYLD_INSERT_LIBRARIES: this.options.temporaryLibrary,
        WSK_ENDURANCE_RESUMABLE_DIRECTORY: path.join(this.root, 'sessions') },
      stdio: ['pipe', 'pipe', this.log.fd]
    });
    this.child.on('error', error => this.rejectWaiters(error));
    this.child.on('exit', (code, signal) => {
      this.report.host_exits.push({ pid: this.child.pid, code, signal });
      this.rejectWaiters(new Error(`Owned host exited: code=${code}, signal=${signal}`));
    });
    this.lines = createInterface({ input: this.child.stdout });
    this.lines.on('line', line => {
      try {
        const reply = JSON.parse(line);
        const waiter = this.waiters.shift();
        if (waiter) waiter.resolve(reply);
        else this.replies.push(reply);
      } catch (error) { this.rejectWaiters(error); }
    });
    const ready = await this.read();
    assert.equal(ready.ready, true);
    assert.equal(ready.pid, this.child.pid);
    assert.equal(await fs.realpath(ready.temporary_directory), await fs.realpath(path.join(this.root, 'tmp')));
    this.port = ready.uploader_port;
    this.report.host_starts.push(ready);
    return ready;
  }

  rejectWaiters(error) {
    for (const waiter of this.waiters.splice(0)) waiter.reject(error);
  }

  async read() {
    if (this.replies.length) return this.validate(this.replies.shift());
    let timer;
    const reply = await new Promise((resolve, reject) => {
      const waiter = { resolve, reject };
      this.waiters.push(waiter);
      timer = setTimeout(() => {
        this.waiters = this.waiters.filter(item => item !== waiter);
        reject(new Error('Owned host control deadline exceeded'));
      }, 10000);
    }).finally(() => clearTimeout(timer));
    return this.validate(reply);
  }

  validate(reply) {
    assert(!reply.error, JSON.stringify(reply));
    assert(!reply.resources?.error, JSON.stringify(reply));
    return reply;
  }

  async command(command) {
    this.child.stdin.write(JSON.stringify({ command }) + '\n');
    return this.read();
  }

  async stop(force = false) {
    const child = this.child;
    if (!child || child.exitCode !== null || child.signalCode !== null) return;
    const exit = new Promise(resolve => child.once('exit', resolve));
    if (force) child.kill('SIGKILL');
    else child.stdin.end();
    const timer = setTimeout(() => child.kill('SIGKILL'), 5000);
    await exit;
    clearTimeout(timer);
    this.lines.close();
  }

  async idle(baseline = null) {
    let clean = 0;
    return eventually('three clean idle samples', async () => {
      const { resources } = await this.command('stats');
      const temporary = await filesBelow(path.join(this.root, 'tmp'));
      this.report.samples.push({ at: Date.now(), pid: this.child.pid, ...resources, temporary });
      const okay = resources.connections === 0 && resources.accepted === resources.closed &&
        resources.uploads === 0 && resources.downloads === 0 && resources.reserved_bytes === 0 &&
        temporary.length === 0 && (!baseline || resources.descriptors <= baseline.descriptors);
      clean = okay ? clean + 1 : 0;
      return clean >= 3 ? resources : false;
    }, 20000);
  }
}

class Proxy extends EventEmitter {
  constructor(report, listenAddress) {
    super();
    this.report = report;
    this.listenAddress = listenAddress;
    this.target = null;
    this.sessions = new Map();
    this.gates = new Set();
    this.sockets = new Set();
    this.held = 0;
    this.maxHeld = 0;
    this.mode = null;
    this.serial = 0;
  }

  async start() {
    this.server = http.createServer((request, response) => {
      this.handle(request, response).catch(error => {
        this.report.proxy_errors.push(error.stack || String(error));
        response.destroy();
      });
    });
    this.server.on('connection', socket => {
      this.sockets.add(socket);
      socket.on('close', () => this.sockets.delete(socket));
    });
    await new Promise((resolve, reject) => {
      this.server.once('error', reject);
      this.server.listen(0, this.listenAddress, () => {
        this.server.off('error', reject);
        resolve();
      });
    });
    this.origin = `http://${this.listenAddress}:${this.server.address().port}`;
  }

  setMode(mode) { this.mode = mode; }

  release() {
    for (const release of this.gates) release();
    this.gates.clear();
  }

  async hold(response) {
    this.held++;
    this.maxHeld = Math.max(this.maxHeld, this.held);
    await new Promise(resolve => {
      const release = () => {
        response.off('close', release);
        this.gates.delete(release);
        resolve();
      };
      this.gates.add(release);
      response.once('close', release);
    });
    this.held--;
  }

  async handle(request, response) {
    const record = { id: ++this.serial, method: request.method, url: request.url, at: Date.now(),
      key: request.headers['upload-key'] || request.url.match(/^\/uploads\/([^/?]+)/)?.[1],
      offset: request.headers['upload-offset'] === undefined ? null : Number(request.headers['upload-offset']) };
    this.report.requests.push(record);
    const chunks = [];
    let received = 0;
    for await (const chunk of request) {
      received += chunk.length;
      assert(received <= 8 * MIB, 'Test proxy fixture body exceeded its own 8MiB limit');
      chunks.push(chunk);
    }
    const body = Buffer.concat(chunks);
    record.request_bytes = body.length;
    if (record.method === 'POST' && record.url === '/uploads') {
      this.sessions.set(record.key, { length: Number(request.headers['upload-length']) });
    }
    if (!this.target) {
      response.writeHead(503, { Connection: 'close' });
      response.end();
      record.status = 503;
      return;
    }
    const mode = this.mode;
    const isBody = record.method === 'PATCH' || (record.method === 'POST' && record.url === '/upload');
    const wantsHold = isBody && mode?.type === 'hold' && (mode.offset === undefined || mode.offset === record.offset);
    const wantsAbort = isBody && mode?.type === 'abort-body' && !mode.used &&
      (mode.offset === undefined || mode.offset === record.offset);
    if (wantsAbort) mode.used = true;
    let upstreamResponse;
    const upstream = http.request({ host: '127.0.0.1', port: this.target, path: request.url,
      method: request.method, headers: { ...request.headers, connection: 'close' }, agent: false });
    record.target_port = this.target;
    upstream.setTimeout(45000, () => upstream.destroy(new Error('Owned upstream deadline exceeded')));
    response.once('close', () => {
      if (!response.writableEnded) {
        upstream.destroy();
        upstreamResponse?.destroy();
      }
    });
    upstream.on('error', error => {
      record.transport_error = error.code || error.message;
      if (!response.destroyed) response.destroy();
    });
    upstream.on('response', reply => {
      upstreamResponse = reply;
      record.status = reply.statusCode;
      record.response_offset = reply.headers['upload-offset'] === undefined ? null : Number(reply.headers['upload-offset']);
      record.response_length = reply.headers['upload-length'] === undefined ? null : Number(reply.headers['upload-length']);
      const dropCreate = mode?.type === 'drop-create' && !mode.used && record.method === 'POST' &&
        record.url === '/uploads' && reply.statusCode === 201;
      const dropFinal = mode?.type === 'drop-final' && !mode.used && record.method === 'PATCH' &&
        reply.statusCode === 204 && record.response_offset === this.sessions.get(record.key)?.length;
      if (dropCreate || dropFinal) {
        mode.used = true;
        reply.resume();
        reply.once('end', () => {
          record.fault = dropCreate ? 'lost-creation-response' : 'lost-final-response';
          record.finished_at = Date.now();
          response.destroy();
          this.emit('fault', record);
        });
      } else {
        response.writeHead(reply.statusCode, reply.headers);
        reply.pipe(response);
        reply.once('end', () => { record.finished_at = Date.now(); });
      }
    });
    if (isBody && body.length > 65536) {
      upstream.write(body.subarray(0, 65536));
      record.prefix_forwarded_at = Date.now();
      if (wantsAbort) {
        // Give the owned server a chance to create/write its request temporary file.
        await sleep(80);
        record.fault = 'interrupted-request-body';
        record.finished_at = Date.now();
        upstream.destroy();
        response.destroy();
        this.emit('fault', record);
        return;
      }
      if (wantsHold) await this.hold(response);
      if (!upstream.destroyed && !response.destroyed) upstream.end(body.subarray(65536));
    } else upstream.end(body);
  }

  async stop() {
    this.release();
    for (const socket of this.sockets) socket.destroy();
    if (this.server) await new Promise(resolve => this.server.close(resolve));
  }
}

async function getOwned(origin, relative) {
  return new Promise((resolve, reject) => {
    const request = http.get(new URL(relative, origin), { agent: false, headers: { Connection: 'close' } }, response => {
      const pieces = [];
      response.on('data', chunk => pieces.push(chunk));
      response.on('end', () => resolve({ status: response.statusCode, body: Buffer.concat(pieces) }));
      response.on('error', reject);
    });
    request.on('error', reject);
    request.setTimeout(15000, () => request.destroy(new Error('Owned download deadline exceeded')));
  });
}

async function verifyFile(root, item) {
  await eventually(`publication of ${item.name}`, async () => {
    try {
      const bytes = await fs.readFile(path.join(root, 'share', item.name));
      if (bytes.length !== item.buffer.length) return false;
      assert.equal(digest(bytes), item.sha256, `Published bytes differ for ${item.name}`);
      return true;
    } catch (error) {
      if (error.code === 'ENOENT') return false;
      throw error;
    }
  }, 45000);
}

async function uploadFinished(page, root, items) {
  for (const item of items) await verifyFile(root, item);
  await eventually('browser upload rows removed', () => page.locator('#uploads > tr').count().then(count => count === 0), 45000);
  assert.equal(await page.locator('.alert-danger').count(), 0, 'Browser showed an upload error');
  if (await page.evaluate(() => typeof window.WSKUploadQueue === 'function')) {
    await eventually('acknowledged session cleanup', () => page.evaluate(() =>
      Object.keys(localStorage).filter(key => key.startsWith('wsk-upload-v1:')).length === 0));
  }
}

async function selectFiles(page, items) {
  // DOMContentLoaded can precede jQuery's deferred ready callback. Wait for the
  // actual picker binding, not merely the statically rendered input element.
  await page.waitForFunction(() => window.jQuery && window.jQuery('#fileupload').data('blueimp-fileupload'));
  await page.locator('#fileupload').setInputFiles(items.map(({ name, mimeType, buffer }) => ({ name, mimeType, buffer })));
}

async function waitForFault(proxy, type, after = 0) {
  return eventually(type, () => proxy.report.requests.find(record => record.id > after && record.fault === type), 45000);
}

async function normalFour(page, proxy, host, root, report, baseline) {
  const items = [0, 1, 2, 3].map(index => fixture(`parallel-${index}.bin`, 2 * MIB + index, index));
  proxy.setMode({ type: 'hold', ...(baseline ? {} : { offset: 0 }) });
  const start = Date.now();
  await selectFiles(page, items);
  await eventually('four simultaneous request bodies in the owned server', async () => {
    if (proxy.held !== 4) return false;
    const snapshot = await host.command('stats');
    const temporary = await filesBelow(path.join(root, 'tmp'));
    if (temporary.length < 4 || snapshot.resources.uploads < 4) return false;
    report.concurrent_resources = { ...snapshot.resources, temporary };
    return true;
  }, 45000);
  const asset = await getOwned(proxy.origin, '/download?path=%2Fasset.bin');
  assert.equal(asset.status, 200);
  assert.equal(digest(asset.body), report.asset_sha256);
  const listing = await getOwned(proxy.origin, '/list?path=%2F');
  assert.equal(listing.status, 200);
  assert(Array.isArray(JSON.parse(listing.body.toString())));
  assert.equal(proxy.held, 4, 'Body transfers ended before the simultaneous reads completed');
  if (!baseline) assert.equal(await page.locator('#uploads .button-retry:visible').count(), 0,
    'Retry must be hidden while uploads are active');
  await page.screenshot({ path: report.screenshots.concurrent, fullPage: true });
  proxy.setMode(null);
  proxy.release();
  await uploadFinished(page, root, items);
  report.scenarios.push({ name: 'four concurrent uploads with download and listing', passed: true,
    elapsed_ms: Date.now() - start, files: items.map(item => ({ name: item.name, sha256: item.sha256, size: item.buffer.length })) });
}

async function runBaseline(page, proxy, root, report) {
  const item = fixture('baseline-interrupted.bin', 3 * MIB + 7, 19);
  const after = proxy.serial;
  proxy.setMode({ type: 'abort-body' });
  await selectFiles(page, [item]);
  const fault = await waitForFault(proxy, 'interrupted-request-body', after);
  await eventually('legacy upload reports interruption', () => page.locator('.alert-danger').count().then(count => count > 0));
  await sleep(2500);
  assert.equal((await filesBelow(path.join(root, 'share'))).includes(item.name), false);
  const attempts = report.requests.filter(record => record.id > after && record.method === 'POST' && record.url === '/upload');
  assert.equal(attempts.length, 1, 'Baseline unexpectedly retried a failed multipart upload');
  await page.screenshot({ path: report.screenshots.waiting, fullPage: true });
  report.scenarios.push({ name: 'baseline interrupted upload needs manual restart', passed: true,
    fault_request: fault.id, attempts: attempts.length, automatic_resume: false });
}

async function runRecovery(page, proxy, host, root, report) {
  const item = fixture('creation-and-chunk.bin', 3 * MIB + 13, 31);
  const after = proxy.serial;
  proxy.setMode({ type: 'drop-create' });
  await selectFiles(page, [item]);
  const creation = await waitForFault(proxy, 'lost-creation-response', after);
  assert.equal(await page.locator('#uploads .button-retry:visible').count(), 0,
    'Retry must be hidden during automatic reconnect');
  await page.screenshot({ path: report.screenshots.waiting, fullPage: true });
  proxy.setMode({ type: 'abort-body', offset: MIB });
  const interrupted = await waitForFault(proxy, 'interrupted-request-body', after);
  assert.equal(interrupted.key, creation.key);
  await uploadFinished(page, root, [item]);
  const creations = report.requests.filter(record => record.id > after && record.method === 'POST' && record.url === '/uploads');
  assert(creations.length >= 2, 'Creation reply loss did not exercise idempotent POST retry');
  assert(creations.every(record => record.key === creation.key), 'POST retry changed its persisted upload key');
  const reconciled = report.requests.find(record => record.id > interrupted.id && record.method === 'HEAD' &&
    record.key === creation.key && record.status === 200 && record.response_offset === MIB);
  assert(reconciled, 'Interrupted chunk did not reconcile the last confirmed 1MiB offset');
  report.scenarios.push({ name: 'lost creation acknowledgement and interrupted chunk', passed: true,
    key: creation.key, creation_attempts: creations.length, recovered_offset: reconciled.response_offset, sha256: item.sha256 });

  const finalItem = fixture('final-restart.bin', MIB + 23, 41);
  const finalStart = proxy.serial;
  proxy.setMode({ type: 'drop-final' });
  await selectFiles(page, [finalItem]);
  const finalFault = await waitForFault(proxy, 'lost-final-response', finalStart);
  await verifyFile(root, finalItem);
  const previousPID = host.child.pid;
  proxy.target = null;
  await host.stop(true);
  await host.start();
  proxy.target = host.port;
  proxy.setMode(null);
  await uploadFinished(page, root, [finalItem]);
  const completedHead = report.requests.find(record => record.id > finalFault.id && record.method === 'HEAD' &&
    record.key === finalFault.key && record.response_offset === finalItem.buffer.length && record.status === 200);
  assert(completedHead, 'Final reply loss did not recover the completed receipt after process restart');
  const duplicates = (await filesBelow(path.join(root, 'share'))).filter(name => name.startsWith('final-restart'));
  assert.deepEqual(duplicates, [finalItem.name]);
  assert.equal(report.requests.filter(record => record.id > finalFault.id && record.method === 'PATCH' && record.key === finalFault.key).length, 0);
  report.scenarios.push({ name: 'lost final acknowledgement survives host process restart', passed: true,
    key: finalFault.key, old_pid: previousPID, new_pid: host.child.pid, recovered_offset: completedHead.response_offset, sha256: finalItem.sha256 });

  const reloadItem = fixture('reload-reselect.bin', 3 * MIB + 29, 59);
  const reloadStart = proxy.serial;
  proxy.setMode({ type: 'hold', offset: MIB });
  await selectFiles(page, [reloadItem]);
  await eventually('second chunk held before reload', () => proxy.held === 1, 45000);
  const creationForReload = report.requests.find(record => record.id > reloadStart && record.method === 'POST' && record.url === '/uploads');
  assert(creationForReload);
  await page.reload({ waitUntil: 'domcontentloaded' });
  await eventually('reloading page aborts its held request', () => proxy.held === 0);
  proxy.setMode(null);
  proxy.release();
  await page.locator('#fileupload').waitFor();
  await selectFiles(page, [reloadItem]);
  await uploadFinished(page, root, [reloadItem]);
  const reloadHead = report.requests.find(record => record.id > creationForReload.id && record.method === 'HEAD' &&
    record.key === creationForReload.key && record.response_offset === MIB);
  assert(reloadHead, 'Reload/reselection did not resume the saved file from the server offset');
  assert.equal(report.requests.filter(record => record.id > reloadStart && record.method === 'POST' && record.url === '/uploads').length, 1);
  report.scenarios.push({ name: 'reload and same-file reselection', passed: true, key: creationForReload.key,
    recovered_offset: reloadHead.response_offset, sha256: reloadItem.sha256 });

  const cancelItem = fixture('cancelled.bin', 2 * MIB + 37, 67);
  const cancelStart = proxy.serial;
  proxy.setMode({ type: 'hold', offset: 0 });
  await selectFiles(page, [cancelItem]);
  await eventually('cancellable first chunk held', () => proxy.held === 1, 45000);
  await page.locator('#uploads .button-cancel').click();
  proxy.setMode(null);
  proxy.release();
  await eventually('cancelled row removed', () => page.locator('#uploads > tr').count().then(count => count === 0));
  const deleted = await eventually('cancelled session deletion acknowledged', () => report.requests.find(record =>
    record.id > cancelStart && record.method === 'DELETE' && record.status === 204));
  assert.equal((await filesBelow(path.join(root, 'share'))).includes(cancelItem.name), false);
  await eventually('browser session records cleaned', () => page.evaluate(() =>
    Object.keys(localStorage).filter(key => key.startsWith('wsk-upload-v1:')).length === 0));
  report.scenarios.push({ name: 'cancellation removes the saved session', passed: true, key: deleted.key });
}

if (process.argv.includes('--help')) {
  console.log('Usage: browser-probe.mjs --host PATH --report PATH [--temporary-library PATH] [--listen-address IPv4] [--baseline]\n' +
    'Launches an owned EnduranceHost and Chrome against disposable synthetic-data directories.\n' +
    'The temporary-directory dylib defaults to EnduranceTemporaryDirectory.dylib beside the host.\n' +
    '--listen-address defaults to 127.0.0.1; a specific LAN IPv4 tests an ordinary HTTP origin.\n' +
    'A non-loopback bind exposes only this synthetic fixture for the duration of the run.\n' +
    'The upstream EnduranceHost always remains bound to loopback.\n' +
    'Requires the playwright Node module; WSK_PLAYWRIGHT_MODULE may name another installed module path.\n' +
    'WSK_CHROME_EXECUTABLE may override the default macOS Google Chrome path.\n' +
    '--baseline checks four legacy multipart uploads, then confirms interrupted uploads cannot resume.');
  process.exit(0);
}

const options = argumentsFor(process.argv.slice(2));
const report = { passed: false, baseline: options.baseline, started_at: new Date().toISOString(),
  host_binary: options.host, listen_address: options.listenAddress, host_starts: [], host_exits: [], samples: [], requests: [],
  scenarios: [], proxy_errors: [], browser_errors: [], cleanup_errors: [], screenshots: {
    concurrent: options.report.replace(/\.json$/, '') + '.concurrent.png',
    waiting: options.report.replace(/\.json$/, '') + '.waiting.png',
    final: options.report.replace(/\.json$/, '') + '.final.png' } };
let root, log, host, proxy, browser;
try {
  const { chromium } = require(process.env.WSK_PLAYWRIGHT_MODULE || 'playwright');
  report.probe_sha256 = digest(await fs.readFile(new URL(import.meta.url)));
  await fs.access(options.host);
  await fs.access(options.temporaryLibrary);
  await fs.mkdir(path.dirname(options.report), { recursive: true });
  root = await fs.mkdtemp(path.join(os.tmpdir(), 'wsk-browser-resume-'));
  report.temporary_root = root;
  for (const directory of ['share', 'dav', 'tmp', 'sessions']) await fs.mkdir(path.join(root, directory));
  const asset = fixture('asset.bin', 256 * 1024, 83);
  report.asset_sha256 = asset.sha256;
  await fs.writeFile(path.join(root, 'share', asset.name), asset.buffer);
  log = await fs.open(options.report.replace(/\.json$/, '') + '.host.log', 'w');
  host = new Host(options, root, report, log);
  await host.start();
  proxy = new Proxy(report, options.listenAddress);
  await proxy.start();
  proxy.target = host.port;
  report.origin = proxy.origin;
  browser = await chromium.launch({ executablePath: CHROME, headless: true });
  const context = await browser.newContext({ viewport: { width: 1100, height: 800 } });
  let page = await context.newPage();
  page.on('pageerror', error => report.browser_errors.push(error.stack || String(error)));
  await page.goto(proxy.origin, { waitUntil: 'domcontentloaded' });
  await page.locator('#fileupload').waitFor();
  report.browser_environment = await page.evaluate(() => ({
    isSecureContext: window.isSecureContext,
    cryptoSubtle: Boolean(window.crypto && window.crypto.subtle),
    cryptoGetRandomValues: Boolean(window.crypto && window.crypto.getRandomValues),
    file: typeof window.File === 'function',
    fileReader: typeof window.FileReader === 'function',
    blobSlice: Boolean(window.Blob && window.Blob.prototype.slice),
    uint8Array: typeof window.Uint8Array === 'function',
    webLocks: Boolean(navigator.locks),
    broadcastChannel: typeof window.BroadcastChannel === 'function'
  }));
  const warmup = fixture('warmup.bin', 128 * 1024, 7);
  await selectFiles(page, [warmup]);
  await uploadFinished(page, root, [warmup]);
  await page.close();
  const baseline = await host.idle();
  report.fixed_idle_baseline = baseline;
  page = await context.newPage();
  page.on('pageerror', error => report.browser_errors.push(error.stack || String(error)));
  await page.goto(proxy.origin, { waitUntil: 'domcontentloaded' });
  await page.locator('#fileupload').waitFor();
  await normalFour(page, proxy, host, root, report, options.baseline);
  if (options.baseline) await runBaseline(page, proxy, root, report);
  else await runRecovery(page, proxy, host, root, report);
  await page.screenshot({ path: report.screenshots.final, fullPage: true });
  await browser.close();
  browser = null;
  report.final_idle = await host.idle(baseline);
  report.final_session_files = await filesBelow(path.join(root, 'sessions'));
  if (!options.baseline) assert.deepEqual(report.final_session_files.filter(name => name !== '.lock'), [],
    'Browser acknowledgement/cancellation left session files');
  report.final_share_files = await filesBelow(path.join(root, 'share'));
  assert.equal(report.browser_errors.length, 0, report.browser_errors.join('\n'));
  report.workload_passed = true;
} catch (error) {
  report.error = error.stack || String(error);
  process.exitCode = 1;
} finally {
  for (const [name, cleanup] of [
    ['browser', () => browser?.close()],
    ['proxy', () => proxy?.stop()],
    ['host', () => host?.stop()],
    ['log', () => log?.close()],
    ['temporary directory', () => root ? fs.rm(root, { recursive: true, force: true }) : undefined]
  ]) {
    try { await cleanup(); } catch (error) { report.cleanup_errors.push(`${name}: ${error.stack || error}`); }
  }
  report.passed = Boolean(report.workload_passed && !report.cleanup_errors.length);
  report.finished_at = new Date().toISOString();
  if (!report.passed) process.exitCode = 1;
  await fs.mkdir(path.dirname(options.report), { recursive: true });
  await fs.writeFile(options.report, JSON.stringify(report, null, 2) + '\n');
  console.log(JSON.stringify({ passed: report.passed, report: options.report, error: report.error || null, cleanup_errors: report.cleanup_errors }));
}
