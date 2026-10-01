/* Run with: node Scripts/test_resumable_upload.js */
'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const SHA256 = require('../Sources/WebServerKitUploader/WSKWebUploader.bundle/Contents/Resources/js/sha256.js');

// Independent platform oracle, including padding boundaries and arbitrary input
// partitioning. File reads and upload chunks need not align to SHA-256 blocks.
for (const length of [0, 1, 55, 56, 63, 64, 65, 119, 120, 127, 128, 129, 1000000]) {
  const input = Buffer.alloc(length);
  for (let i = 0; i < length; i++) input[i] = (i * 13 + (i >>> 8)) & 255;
  const expected = crypto.createHash('sha256').update(input).digest('hex');
  for (const chunkSize of [1, 7, 55, 64, 65, 4093, 1024 * 1024]) {
    const hash = new SHA256();
    for (let at = 0; at < length; at += chunkSize) hash.update(input.subarray(at, at + chunkSize));
    assert.equal(hash.hex(), expected, `length=${length}, partition=${chunkSize}`);
    assert.equal(hash.hex(), expected, 'digest reads are stable');
    assert.throws(() => hash.update(new Uint8Array(0)), /finished/);
  }
}
assert.equal(new SHA256().update(Buffer.from('abc')).hex(),
  'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
console.log('Incremental SHA-256 matches the platform oracle across file and block boundaries.');

const fs = require('node:fs');
const vm = require('node:vm');
const clientSource = fs.readFileSync(require.resolve('../Sources/WebServerKitUploader/WSKWebUploader.bundle/Contents/Resources/js/resumable-upload.js'), 'utf8');
const CHUNK = 1024 * 1024;

class Storage {
  constructor() { this.items = new Map(); }
  get length() { return this.items.size; }
  key(i) { return [...this.items.keys()][i]; }
  getItem(key) { return this.items.get(key) || null; }
  setItem(key, value) { this.items.set(key, value); }
  removeItem(key) { this.items.delete(key); }
}

function file(name, length, fill = 37) {
  const bytes = Buffer.alloc(length, fill);
  return { name, size: length, bytes, slice: (start, end) => ({ bytes: bytes.subarray(start, end), size: end - start }) };
}

class Server {
  constructor() { this.sessions = new Map(); this.requests = []; this.completed = []; this.created = 0; }
  respond(request) {
    this.requests.push(request);
    const id = request.url.split('/').pop();
    let session = this.sessions.get(id);
    let status;
    let headers = { 'Tus-Resumable': '1.0.0' };
    if (request.method === 'POST') {
      const key = request.headers['Upload-Key'];
      session = this.sessions.get(key);
      if (!session) {
        this.created++;
        session = { key, offset: 0, length: Number(request.headers['Upload-Length']), data: [], metadata: request.headers['Upload-Metadata'] };
        this.sessions.set(key, session);
      }
      status = session.metadata === request.headers['Upload-Metadata'] ? 201 : 409;
      headers.Location = '/uploads/' + key;
      if (session.length === 0 && !session.published) { this.completed.push(Buffer.alloc(0)); session.published = true; }
    } else if (!session) status = 404;
    else if (request.method === 'DELETE') { this.sessions.delete(id); status = 204; }
    else if (request.method === 'HEAD') status = 200;
    else if (request.method === 'PATCH') {
      if (Number(request.headers['Upload-Offset']) !== session.offset) status = 409;
      else {
        assert.ok(request.body.size <= CHUNK);
        session.data.push(request.body.bytes);
        session.offset += request.body.bytes.length;
        status = 204;
        if (session.offset === session.length) {
          assert.equal(session.published, undefined, 'publish happens only once');
          const bytes = Buffer.concat(session.data);
          const expectedHash = Buffer.from(session.metadata.match(/sha256 ([^,]+)/)[1], 'base64').toString();
          assert.equal(crypto.createHash('sha256').update(bytes).digest('hex'), expectedHash);
          session.published = true;
          this.completed.push(bytes);
        }
      }
    } else throw new Error('Unexpected method: ' + request.method);
    if (session) {
      headers['Upload-Offset'] = String(session.offset);
      headers['Upload-Length'] = String(session.length);
      headers['Upload-Expires'] = new Date(Date.now() + 23 * 60 * 60 * 1000).toUTCString();
    }
    return { status, headers };
  }
}

function browser(server, storage = new Storage(), intercept) {
  let clock = 0, nextId = 0, active = 0, maximum = 0;
  const timers = new Map();
  const states = [], errors = [], done = [];
  function schedule(callback, delay) { const id = ++nextId; timers.set(id, { at: clock + delay, callback }); return id; }
  function step() {
    if (!timers.size) return false;
    const [id, timer] = [...timers.entries()].sort((a, b) => a[1].at - b[1].at || a[0] - b[0])[0];
    timers.delete(id);
    clock = timer.at;
    timer.callback();
    return true;
  }
  class XHR {
    constructor() { this.headers = {}; this.responseHeaders = {}; this.upload = {}; this.status = 0; this.live = false; }
    open(method, url) { this.method = method; this.url = url; }
    setRequestHeader(name, value) { this.headers[name] = value; }
    getResponseHeader(name) { return this.responseHeaders[name] || null; }
    send(body) {
      this.live = true;
      active++;
      maximum = Math.max(maximum, active);
      const request = { method: this.method, url: this.url, headers: this.headers, body };
      this.timer = schedule(() => {
        if (!this.live) return;
        const response = intercept ? intercept(request, server) : server.respond(request);
        this.status = response.status;
        this.responseHeaders = response.headers || {};
        this.live = false;
        active--;
        if (response.status === 0) this.onerror(); else this.onload();
      }, 1);
    }
    abort() { if (this.live) { this.live = false; active--; timers.delete(this.timer); if (this.onabort) this.onabort(); } }
  }
  class Reader {
    constructor() { this.readyState = 0; }
    readAsArrayBuffer(blob) {
      this.readyState = 1;
      this.timer = schedule(() => { this.readyState = 2; this.result = Uint8Array.from(blob.bytes).buffer; this.onload(); }, 1);
    }
    abort() { this.readyState = 2; timers.delete(this.timer); }
  }
  const root = {
    FileReader: Reader, Blob: function() {}, Uint8Array, WSKSHA256: SHA256,
    crypto: crypto.webcrypto, btoa, XMLHttpRequest: XHR, URL,
    location: { href: 'http://192.0.2.1:8080/', origin: 'http://192.0.2.1:8080' },
    localStorage: storage, setTimeout: schedule, clearTimeout: id => timers.delete(id)
  };
  root.Blob.prototype.slice = function() {};
  vm.runInNewContext(clientSource, { window: root, Uint8Array, Number, Date, Math, Object, Array, String, JSON, encodeURIComponent, unescape });
  const queue = new root.WSKUploadQueue({
    onstate: job => states.push({ label: job.label, progress: job.progress }),
    onfinish: (job, error) => { if (error) errors.push(error); },
    ondone: job => done.push(job)
  });
  return {
    queue, root, storage, states, errors, done,
    get active() { return active; }, get maximum() { return maximum; }, get pendingTimers() { return timers.size; },
    step,
    run(until = () => false, limit = 10000) {
      let count = 0;
      while (!until() && step()) if (++count > limit) throw new Error('Client did not settle');
    }
  };
}

// Independent files overlap, but file reads and cleanup requests obey the same
// four-slot budget. File bytes round-trip, including empty files and Unicode.
{
  const server = new Server(), b = browser(server);
  for (let i = 0; i < 7; i++) b.queue.add(file('選択-' + i + '.bin', i === 6 ? 0 : CHUNK + 31, i), '/Folder/');
  b.run();
  assert.equal(b.done.length, 7);
  assert.equal(server.completed.length, 7);
  assert.equal(b.maximum, 4);
  assert.equal(b.active, 0);
  assert.equal(b.pendingTimers, 0);
  assert.equal(b.storage.length, 0);
  assert.equal(server.sessions.size, 0);
  assert.equal(b.errors.length, 0);
}

// A lost creation response cannot create a second session, and ambiguous PATCH
// completion must be reconciled by HEAD before another body is sent.
for (const lostMethod of ['POST', 'PATCH']) {
  const server = new Server();
  let lost = false;
  const b = browser(server, undefined, (request, actual) => {
    const response = actual.respond(request);
    if (!lost && request.method === lostMethod) { lost = true; return { status: 0 }; }
    return response;
  });
  b.queue.add(file('recover.bin', CHUNK * 2 + 5), '/');
  b.run();
  assert.equal(server.created, 1);
  assert.equal(b.done.length, 1);
  const patchOffsets = server.requests.filter(r => r.method === 'PATCH').map(r => Number(r.headers['Upload-Offset']));
  assert.deepEqual(patchOffsets, [0, CHUNK, CHUNK * 2]);
  if (lostMethod === 'PATCH') assert.ok(server.requests.some(r => r.method === 'HEAD'));
  assert.equal(b.active, 0);
}

// Losing the final publication response is also recovery, never a duplicate file.
{
  const server = new Server();
  let lost = false;
  const b = browser(server, undefined, (request, actual) => {
    const result = actual.respond(request);
    if (!lost && request.method === 'PATCH') { lost = true; return { status: 0 }; }
    return result;
  });
  b.queue.add(file('final-response.bin', 200), '/'); b.run();
  assert.equal(server.completed.length, 1);
  assert.equal(server.requests.filter(r => r.method === 'PATCH').length, 1);
  assert.equal(b.done.length, 1);
}

// Reload/reselection recomputes whole-file identity. Same name and length with
// different bytes must create a new session, never append to the saved file.
{
  const server = new Server(), storage = new Storage(), first = browser(server, storage);
  const original = file('same-name.bin', CHUNK * 2 + 1, 21);
  first.queue.add(original, '/');
  first.run(() => [...server.sessions.values()].some(s => s.offset === CHUNK));
  first.queue.suspend();
  assert.equal(first.active, 0);
  assert.equal(first.pendingTimers, 0);
  const second = browser(server, storage);
  second.queue.add(file('same-name.bin', original.size, 22), '/'); second.run();
  assert.equal(server.created, 2);
  assert.equal([...server.sessions.values()][0].offset, CHUNK);
  second.queue.add(original, '/'); second.run();
  assert.equal(server.created, 2);
  assert.equal(server.completed.length, 2);
  assert.equal(second.storage.length, 0);
}

// BFCache-style pagehide closes in-flight requests and drops all timers; restore
// reconciles the retained file session before continuing.
{
  const server = new Server(), b = browser(server);
  b.queue.add(file('bfcache.bin', CHUNK * 2 + 7), '/');
  b.run(() => [...server.sessions.values()].some(s => s.offset === CHUNK));
  b.queue.suspend();
  assert.equal(b.active, 0); assert.equal(b.pendingTimers, 0);
  b.queue.resume(); b.run();
  assert.equal(b.done.length, 1);
  assert.ok(server.requests.some(r => r.method === 'HEAD'));
}

// Cancel after an ambiguous create rediscovers the same key then deletes it. A
// failed cancellation persists only cleanup work and cannot send file bytes.
{
  const server = new Server();
  let drop = true;
  const b = browser(server, undefined, (request, actual) => {
    const response = actual.respond(request);
    if (drop && request.method === 'POST') return { status: 0 };
    return response;
  });
  const job = b.queue.add(file('cancel.bin', CHUNK + 7), '/');
  b.run(() => server.created === 1);
  job.cancel(); b.run();
  assert.equal(b.storage.length, 1);
  assert.equal(server.requests.filter(r => r.method === 'PATCH').length, 0);
  drop = false;
  const restored = browser(server, b.storage); restored.run();
  assert.equal(restored.storage.length, 0);
  assert.equal(server.sessions.size, 0);
  assert.equal(server.created, 1);
}

// Authentication pauses after one request; retries are explicit. Repeated
// disconnects eventually stop rather than retaining sockets/timers forever.
for (const status of [0, 401, 403, 413, 501]) {
  const server = new Server();
  let count = 0;
  const b = browser(server, undefined, () => { count++; return { status }; });
  const job = b.queue.add(file('paused.bin', 5), '/'); b.run();
  assert.equal(job.paused, true);
  assert.equal(count, status === 0 ? 120 : 1);
  if (status === 501) assert.match(job.label, /destination filesystem/);
  assert.equal(b.active, 0); assert.equal(b.pendingTimers, 0);
  job.cancel(); b.run();
  assert.equal(b.queue.jobs.length, 0);
}

// A definitely refused creation has no uncertain predecessor to discover. DELETE
// can confirm absence directly; repeatedly POSTing a refused request would strand
// cleanup records and eventually exhaust the browser's saved-session allowance.
for (const status of [413, 501]) {
  const server = new Server();
  let posts = 0, deletes = 0;
  const b = browser(server, undefined, (request, actual) => {
    if (request.method === 'POST') { posts++; return { status }; }
    if (request.method === 'DELETE') deletes++;
    return actual.respond(request);
  });
  const job = b.queue.add(file('refused.bin', 5), '/'); b.run();
  assert.equal(job.paused, true);
  job.cancel(); b.run();
  assert.equal(posts, 1);
  assert.equal(deletes, 1);
  assert.equal(b.storage.length, 0);
  assert.equal(b.queue.jobs.length, 0);
}

// A later definite refusal must not erase an earlier lost creation response.
// Cancellation still uses the idempotent POST barrier in that case, even after
// reload, and never sends any file bytes while cleaning the session up.
{
  const server = new Server();
  let posts = 0, deletes = 0;
  const b = browser(server, undefined, (request, actual) => {
    if (request.method === 'POST') {
      posts++;
      if (posts === 1) { actual.respond(request); return { status: 0 }; }
      return { status: 501 };
    }
    if (request.method === 'DELETE') deletes++;
    return actual.respond(request);
  });
  const job = b.queue.add(file('previously-uncertain.bin', 5), '/'); b.run();
  assert.equal(job.paused, true);
  job.cancel(); b.run();
  assert.equal(posts, 3);
  assert.equal(deletes, 0);
  assert.equal(b.storage.length, 1);
  const restored = browser(server, b.storage); restored.run();
  assert.equal(server.created, 1);
  assert.equal(server.sessions.size, 0);
  assert.equal(restored.storage.length, 0);
  assert.equal(server.requests.filter(request => request.method === 'PATCH').length, 0);
}

// If a volume could not report its capability during creation, a definitive
// unsupported publication result must still pause immediately at the last PATCH.
{
  const server = new Server();
  let patchCount = 0;
  const b = browser(server, undefined, (request, actual) => {
    if (request.method === 'PATCH') { patchCount++; return { status: 501 }; }
    return actual.respond(request);
  });
  const job = b.queue.add(file('unsupported-volume.bin', 5), '/'); b.run();
  assert.equal(job.paused, true);
  assert.match(job.label, /destination filesystem/);
  assert.equal(patchCount, 1);
  assert.equal(b.active, 0); assert.equal(b.pendingTimers, 0);
  job.cancel(); b.run();
  assert.equal(server.sessions.size, 0);
  assert.equal(server.completed.length, 0);
}

// Even a corrupt/stale stored URL cannot redirect file bytes away from the
// current origin and validated upload UUID.
{
  const server = new Server(), storage = new Storage(), first = browser(server, storage);
  const original = file('origin.bin', CHUNK + 1);
  first.queue.add(original, '/');
  first.run(() => server.created === 1); first.queue.suspend();
  const key = storage.key(0), record = JSON.parse(storage.getItem(key));
  record.url = 'https://example.invalid/collect'; storage.setItem(key, JSON.stringify(record));
  const second = browser(server, storage); second.queue.add(original, '/'); second.run();
  assert.ok(server.requests.every(request => /^\/uploads(?:\/[0-9a-f-]+)?$/.test(request.url)));
  assert.equal(second.done.length, 1);
}

// Other tabs can race the local admission limit. Never hide their saved records
// when looking up an exact file; only admission of a new session is capped.
{
  const server = new Server(), storage = new Storage();
  const original = file('last-record.bin', 200);
  const digest = crypto.createHash('sha256').update(original.bytes).digest('hex');
  let last;
  for (let i = 0; i < 33; i++) {
    const record = { key: crypto.randomUUID(), name: i === 32 ? original.name : 'other-' + i,
      path: '/', size: original.size, sha256: digest, expires: Date.now() + 600000,
      created: true, started: true };
    storage.setItem('wsk-upload-v1:' + record.key, JSON.stringify(record));
    last = record;
  }
  server.sessions.set(last.key, { key: last.key, offset: 0, length: original.size, data: [],
    metadata: 'sha256 ' + Buffer.from(digest).toString('base64') });
  const b = browser(server, storage);
  b.queue.add(original, '/'); b.run();
  assert.equal(b.done.length, 1);
  assert.equal(server.created, 0);
  const newJob = b.queue.add(file('new-file.bin', 1), '/'); b.run();
  assert.equal(newJob.paused, true);
  assert.equal(server.created, 0);
  newJob.cancel();
}

console.log('Resumable client recovery, identity, cancellation, concurrency, and lifecycle tests passed.');
