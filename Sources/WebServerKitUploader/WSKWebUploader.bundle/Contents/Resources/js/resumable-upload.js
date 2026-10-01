/* Resumable uploader: bounded file reads, four files, and authoritative offsets. */
(function(root) {
  'use strict';

  var PREFIX = 'wsk-upload-v1:';
  var UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
  var CHUNK = 1024 * 1024;
  var MAX_FILE = 8 * 1024 * 1024 * 1024;
  var LIFETIME = 24 * 60 * 60 * 1000;

  function uuid() {
    var bytes = new Uint8Array(16);
    // getRandomValues is available on HTTP origins, unlike crypto.subtle.
    root.crypto.getRandomValues(bytes);
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    var hex = Array.prototype.map.call(bytes, function(b) { return ('0' + b.toString(16)).slice(-2); }).join('');
    return hex.slice(0, 8) + '-' + hex.slice(8, 12) + '-' + hex.slice(12, 16) + '-' + hex.slice(16, 20) + '-' + hex.slice(20);
  }

  function integer(value) {
    if (!/^(0|[1-9][0-9]*)$/.test(value || '')) return null;
    var result = Number(value);
    return result <= 9007199254740991 ? result : null;
  }

  function metadata(record) {
    function value(text) { return root.btoa(unescape(encodeURIComponent(text))); }
    return 'filename ' + value(record.name) + ',path ' + value(record.path) + ',sha256 ' + value(record.sha256);
  }

  function Queue(options) {
    this.options = options || {};
    this.jobs = [];
    this.active = 0;
    this.suspended = false;
    this.memory = {};
    this.storage = null;
    try { this.storage = root.localStorage; } catch (e) { /* Private mode may refuse storage. */ }
    var self = this;
    this.records().forEach(function(record) {
      if (record.cancelled) self.cleanup(record);
    });
  }

  Queue.supported = function() {
    return !!(root.FileReader && root.Blob && root.Blob.prototype.slice && root.Uint8Array &&
      root.crypto && root.crypto.getRandomValues && root.WSKSHA256);
  };

  Queue.prototype.records = function() {
    var self = this;
    var records = {};
    try {
      if (this.storage) {
        // Never inspect, clear, or replace another feature's storage keys.
        for (var i = 0; i < this.storage.length; i++) {
          var key = this.storage.key(i);
          if (key && key.indexOf(PREFIX) === 0) {
            try { records[key.slice(PREFIX.length)] = JSON.parse(this.storage.getItem(key)); } catch (e) { /* Ignore invalid records. */ }
          }
        }
      }
    } catch (e) { /* In-memory recovery remains available. */ }
    // An update refused by storage (quota/private mode) must still take effect
    // in this page, particularly a cancellation that must never upload again.
    Object.keys(this.memory).forEach(function(key) { records[key] = self.memory[key]; });
    return Object.keys(records).map(function(key) {
      var record = records[key];
      if (!record || record.key !== key || !UUID.test(key) || typeof record.name !== 'string' ||
          typeof record.path !== 'string' || record.path.charAt(0) !== '/' ||
          !/^[0-9a-f]{64}$/.test(record.sha256) || !Number.isSafeInteger(record.size) ||
          record.size < 0 || record.size > MAX_FILE || !Number.isFinite(record.expires)) return null;
      if (record.expires <= Date.now()) {
        self.forget(record);
        return null;
      }
      // A stored Location is never trusted as a request destination. URLs are
      // always constructed from the validated UUID under this same origin.
      return record;
    }).filter(function(record) { return record !== null; });
  };

  Queue.prototype.save = function(record) {
    this.memory[record.key] = record;
    try { if (this.storage) this.storage.setItem(PREFIX + record.key, JSON.stringify(record)); } catch (e) { /* Quota/private mode. */ }
  };

  Queue.prototype.forget = function(record) {
    delete this.memory[record.key];
    try { if (this.storage) this.storage.removeItem(PREFIX + record.key); } catch (e) { /* In-memory recovery. */ }
  };

  Queue.prototype.pendingCount = function() {
    return this.records().filter(function(record) { return !record.cancelled; }).length;
  };

  Queue.prototype.state = function(job, label, progress) {
    job.label = label;
    if (progress !== undefined) job.progress = progress;
    if (!job.hidden && this.options.onstate) this.options.onstate(job);
  };

  Queue.prototype.add = function(file, path, context) {
    if (this.jobs.length >= 128) throw new Error('Please finish or cancel some uploads before adding more files.');
    if (!Number.isSafeInteger(file.size) || file.size < 0 || file.size > MAX_FILE) throw new Error('Each file must be 8 GiB or smaller.');
    try { encodeURIComponent(file.name); encodeURIComponent(path); } catch (e) {
      throw new Error('The file or folder name contains an unsupported character.');
    }
    var self = this;
    var job = { file: file, path: path, context: context, progress: 0, generation: 0, failures: 0, record: null };
    job.cancel = function() { self.cancel(job); };
    job.retry = function() {
      if (!job.paused || job.finished) return;
      job.paused = false;
      job.failures = 0;
      job.failureSince = null;
      job.needHead = !!(job.record && job.record.created);
      self.state(job, 'Queued');
      self.pump();
    };
    this.jobs.push(job);
    this.state(job, 'Queued');
    this.pump();
    return job;
  };

  Queue.prototype.pump = function() {
    if (this.suspended) return;
    var self = this;
    this.jobs.slice().some(function(job) {
      if (self.active >= 4) return true;
      if (!job.active && !job.paused && !job.finished) {
        job.active = true;
        self.active++;
        self.advance(job);
      }
      return false;
    });
  };

  Queue.prototype.stopWork = function(job) {
    job.generation++;
    root.clearTimeout(job.timer);
    job.timer = null;
    if (job.xhr) { job.xhr.abort(); job.xhr = null; }
    if (job.reader) { if (job.reader.readyState === 1) job.reader.abort(); job.reader = null; }
  };

  Queue.prototype.release = function(job) {
    if (job.active) { job.active = false; this.active--; }
  };

  Queue.prototype.finish = function(job, error) {
    this.stopWork(job);
    job.finished = true;
    this.release(job);
    this.jobs = this.jobs.filter(function(item) { return item !== job; });
    if (!job.hidden && this.options.onfinish) this.options.onfinish(job, error);
    this.pump();
  };

  Queue.prototype.pause = function(job, message) {
    this.stopWork(job);
    job.paused = true;
    this.release(job);
    this.state(job, message + ' — click Retry');
    this.pump();
  };

  Queue.prototype.request = function(job, method, url, headers, body, callback) {
    var self = this;
    var generation = job.generation;
    var xhr = new root.XMLHttpRequest();
    job.xhr = xhr;
    var settled = false;
    function finish() {
      if (settled || generation !== job.generation) return;
      settled = true;
      job.xhr = null;
      callback(xhr);
    }
    try {
      xhr.open(method, url, true);
      xhr.timeout = 30000;
      xhr.setRequestHeader('Tus-Resumable', '1.0.0');
      Object.keys(headers || {}).forEach(function(name) { xhr.setRequestHeader(name, headers[name]); });
      xhr.onload = finish;
      xhr.onerror = finish;
      xhr.ontimeout = finish;
      xhr.onabort = finish;
      if (body && xhr.upload && !job.cancelling) {
        xhr.upload.onprogress = function(event) {
          if (generation === job.generation && event.lengthComputable) {
            self.state(job, 'Uploading', Math.min(99, (job.offset + event.loaded) / job.file.size * 100));
          }
        };
      }
      xhr.send(body || null);
    } catch (e) {
      // Includes requests refused by the browser before they reach the network.
      finish();
    }
  };

  Queue.prototype.hash = function(job) {
    var self = this;
    var generation = job.generation;
    var hash = new root.WSKSHA256();
    var at = 0;
    this.state(job, 'Checking file 0%', 0);
    function next() {
      if (generation !== job.generation) return;
      if (at === job.file.size) {
        job.sha256 = hash.hex();
        self.advance(job);
        return;
      }
      var reader = new root.FileReader();
      job.reader = reader;
      reader.onload = function() {
        if (generation !== job.generation) return;
        job.reader = null;
        var bytes = new Uint8Array(reader.result);
        if (!bytes.length) { self.finish(job, 'The selected file could not be read.'); return; }
        hash.update(bytes);
        at += bytes.length;
        self.state(job, 'Checking file ' + Math.floor(at / job.file.size * 100) + '%', 0);
        // A separate turn per slice keeps navigation and cancellation responsive.
        job.timer = root.setTimeout(next, 0);
      };
      reader.onerror = function() { if (generation === job.generation) self.finish(job, 'The selected file could not be read.'); };
      try {
        reader.readAsArrayBuffer(job.file.slice(at, Math.min(at + CHUNK, job.file.size)));
      } catch (e) {
        self.finish(job, 'The selected file could not be read.');
      }
    }
    next();
  };

  Queue.prototype.advance = function(job) {
    if (this.suspended || job.finished || job.paused) return;
    if (job.cancelling) { this.removeSession(job); return; }
    if (!job.sha256) { this.hash(job); return; }
    if (!job.record) {
      var records = this.records();
      var match = records.filter(function(record) {
        return !record.cancelled && record.path === job.path && record.name === job.file.name &&
          record.size === job.file.size && record.sha256 === job.sha256;
      })[0];
      if (match && this.jobs.some(function(other) { return other !== job && other.record && other.record.key === match.key; })) {
        this.finish(job, 'This file is already queued for this folder.');
        return;
      }
      if (!match && records.length >= 32) {
        this.pause(job, 'Too many saved uploads; finish or cancel an interrupted upload');
        return;
      }
      job.record = match || { key: uuid(), path: job.path, name: job.file.name, size: job.file.size,
        sha256: job.sha256, expires: Date.now() + LIFETIME, created: false, started: false, createUncertain: false };
      // Persist the idempotency key BEFORE starting creation, including for a
      // response lost during pagehide or an abrupt device suspension.
      this.save(job.record);
      job.needHead = !!job.record.created;
    }
    if (!job.record.created) this.create(job);
    else if (job.needHead) this.head(job);
    else this.patch(job);
  };

  Queue.prototype.acceptOffset = function(job, xhr, requireLength) {
    var offset = integer(xhr.getResponseHeader('Upload-Offset'));
    var length = integer(xhr.getResponseHeader('Upload-Length'));
    if (offset === null || offset > job.record.size || ((requireLength || length !== null) && length !== job.record.size) ||
        xhr.getResponseHeader('Tus-Resumable') !== '1.0.0') return false;
    job.offset = offset;
    var expiry = Date.parse(xhr.getResponseHeader('Upload-Expires'));
    if (Number.isFinite(expiry)) job.record.expires = Math.min(expiry, Date.now() + LIFETIME);
    this.save(job.record);
    return true;
  };

  Queue.prototype.create = function(job) {
    var self = this;
    // Older stored records with a started creation are conservatively ambiguous.
    // Persist uncertainty before sending: a reload can interrupt any callback.
    var previouslyUncertain = job.record.createUncertain === true ||
      (job.record.createUncertain === undefined && job.record.started);
    job.record.started = true;
    job.record.createUncertain = true;
    this.save(job.record);
    this.state(job, job.cancelling ? 'Cancelling' : 'Connecting');
    this.request(job, 'POST', '/uploads', {
      'Upload-Key': job.record.key,
      'Upload-Length': String(job.record.size),
      'Upload-Metadata': metadata(job.record)
    }, null, function(xhr) {
      if (xhr.status === 201) {
        var location = xhr.getResponseHeader('Location');
        var expected = '/uploads/' + job.record.key;
        var parsed;
        try { parsed = new root.URL(location, root.location.href); } catch (e) { /* Refuse malformed destinations. */ }
        if (!location || !parsed || parsed.origin !== root.location.origin || parsed.pathname !== expected ||
            parsed.search || parsed.hash || !self.acceptOffset(job, xhr, true)) {
          self.pause(job, 'The server returned an invalid upload session');
          return;
        }
        job.record.created = true;
        job.record.createUncertain = false;
        self.save(job.record);
        job.needHead = false;
        if (job.cancelling) self.removeSession(job);
        else self.patch(job);
      } else {
        // A definite refusal only resolves this attempt. It cannot erase a lost
        // response from an earlier creation, which may still have made a session.
        if (xhr.status !== 0 && !previouslyUncertain) {
          job.record.createUncertain = false;
          self.save(job.record);
        }
        if (xhr.status === 409 && !job.cancelling) self.pause(job, 'The saved upload does not match the server session');
        else self.failedRequest(job, xhr);
      }
    });
  };

  Queue.prototype.head = function(job) {
    var self = this;
    this.state(job, 'Checking saved progress');
    this.request(job, 'HEAD', '/uploads/' + job.record.key, {}, null, function(xhr) {
      if (xhr.status === 200 && self.acceptOffset(job, xhr, true)) {
        job.needHead = false;
        self.patch(job);
      } else if (xhr.status === 404 || xhr.status === 410) {
        // Do not silently create a second file: a completed receipt might have
        // expired too. The user decides whether to start this file again.
        self.forget(job.record);
        self.finish(job, 'The saved upload expired or was removed. Select the file again to start a new upload.');
      } else if (xhr.status === 200) self.pause(job, 'The server returned invalid saved progress');
      else self.failedRequest(job, xhr);
    });
  };

  Queue.prototype.patch = function(job) {
    if (job.offset === job.file.size) { this.complete(job); return; }
    var self = this;
    var offset = job.offset;
    var end = Math.min(offset + CHUNK, job.file.size);
    this.state(job, 'Uploading', offset / job.file.size * 100);
    this.request(job, 'PATCH', '/uploads/' + job.record.key, {
      'Content-Type': 'application/offset+octet-stream', 'Upload-Offset': String(offset)
    }, job.file.slice(offset, end), function(xhr) {
      if (xhr.status === 204 && self.acceptOffset(job, xhr) && job.offset === end) {
        job.failures = 0;
        job.failureSince = null;
        self.patch(job);
      } else if (xhr.status === 204) self.pause(job, 'The server returned an unexpected upload offset');
      else self.failedRequest(job, xhr);
    });
  };

  Queue.prototype.failedRequest = function(job, xhr) {
    var self = this;
    if (job.cancelling) {
      // Retain a bounded cleanup record for the next page load. The server's
      // expiration is the final backstop while the device is unavailable.
      this.finish(job);
      return;
    }
    if (xhr.status === 401 || xhr.status === 403) {
      this.pause(job, 'Authentication or permission is required');
      return;
    }
    if (xhr.status === 501) {
      this.pause(job, 'The destination filesystem does not support atomic resumable uploads');
      return;
    }
    if (xhr.status !== 0 && xhr.status !== 409 && xhr.status !== 408 && xhr.status !== 429 && xhr.status < 500) {
      var explanation = xhr.status === 422 ? 'The completed file did not match its checksum.' :
        xhr.status === 413 ? 'The server has reached its upload size or storage limit.' :
        'The server refused the upload (HTTP ' + xhr.status + ').';
      this.pause(job, explanation);
      return;
    }
    job.failures++;
    if (!job.failureSince) job.failureSince = Date.now();
    if (job.failures >= 120 || Date.now() - job.failureSince >= 60 * 60 * 1000) {
      this.pause(job, 'The server is still unavailable; progress is saved');
      return;
    }
    job.needHead = !!job.record.created;
    this.state(job, 'Waiting for server — progress saved', job.file.size ? job.offset / job.file.size * 100 : 0);
    var delay = Math.min(30000, 1000 * Math.pow(2, Math.min(job.failures - 1, 5)));
    // Four disconnected uploads should not continually reconnect in lockstep.
    delay += Math.floor(Math.random() * 250);
    job.timer = root.setTimeout(function() { self.advance(job); }, delay);
  };

  Queue.prototype.complete = function(job) {
    var record = job.record;
    this.state(job, 'Complete', 100);
    // First record completion as cleanup-only. A reload must never re-submit a
    // fully published file merely because its final receipt DELETE was lost.
    record.cancelled = true;
    this.save(record);
    if (this.options.ondone) this.options.ondone(job);
    this.finish(job);
    this.cleanup(record);
  };

  Queue.prototype.cleanup = function(record) {
    if (this.jobs.some(function(job) { return job.record && job.record.key === record.key; })) return;
    this.jobs.unshift({ record: record, generation: 0, cancelling: true, hidden: true });
    this.pump();
  };

  Queue.prototype.cancel = function(job) {
    if (job.finished || job.cancelling) return;
    this.stopWork(job);
    job.paused = false;
    job.cancelling = true;
    if (!job.record || !job.record.started) {
      if (job.record) this.forget(job.record);
      this.finish(job);
      return;
    }
    job.record.cancelled = true;
    this.save(job.record);
    this.state(job, 'Cancelling');
    if (job.active) this.removeSession(job);
    else this.pump();
  };

  Queue.prototype.removeSession = function(job) {
    var self = this;
    if (!job.record.created && job.record.createUncertain !== false) {
      // Creation might have reached the server even if its response did not.
      // Repeat the same key, then delete the resulting session; never upload.
      this.create(job);
      return;
    }
    this.request(job, 'DELETE', '/uploads/' + job.record.key, {}, null, function(xhr) {
      if (xhr.status === 204 || xhr.status === 404 || xhr.status === 410) self.forget(job.record);
      self.finish(job);
    });
  };

  Queue.prototype.suspend = function() {
    this.suspended = true;
    var self = this;
    this.jobs.forEach(function(job) {
      self.stopWork(job);
      self.release(job);
      job.needHead = !!(job.record && job.record.created);
    });
  };

  Queue.prototype.resume = function() {
    this.suspended = false;
    this.pump();
  };

  root.WSKUploadQueue = Queue;
})(typeof window !== 'undefined' ? window : this);
