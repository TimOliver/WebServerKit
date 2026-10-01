/*
 * Incremental SHA-256 for file identity on HTTP LAN origins, where Web Crypto
 * is unavailable. Hash input stays bounded to one file slice and one block.
 */
(function(root) {
  'use strict';

  var K = new Uint32Array([
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
  ]);

  function rotate(value, count) {
    return (value >>> count) | (value << (32 - count));
  }

  function SHA256() {
    this.state = new Uint32Array([
      0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
      0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
    ]);
    this.words = new Uint32Array(64);
    this.block = new Uint8Array(64);
    this.used = 0;
    this.length = 0;
    this.finished = false;
  }

  SHA256.prototype.compress = function(bytes, offset) {
    var words = this.words;
    var i;
    for (i = 0; i < 16; i++) {
      var at = offset + i * 4;
      words[i] = (bytes[at] << 24) | (bytes[at + 1] << 16) | (bytes[at + 2] << 8) | bytes[at + 3];
    }
    for (i = 16; i < 64; i++) {
      var x = words[i - 15];
      var y = words[i - 2];
      words[i] = words[i - 16] + (rotate(x, 7) ^ rotate(x, 18) ^ (x >>> 3)) +
        words[i - 7] + (rotate(y, 17) ^ rotate(y, 19) ^ (y >>> 10));
    }
    var s = this.state;
    var a = s[0], b = s[1], c = s[2], d = s[3], e = s[4], f = s[5], g = s[6], h = s[7];
    for (i = 0; i < 64; i++) {
      var t1 = (h + (rotate(e, 6) ^ rotate(e, 11) ^ rotate(e, 25)) +
        ((e & f) ^ (~e & g)) + K[i] + words[i]) | 0;
      var t2 = ((rotate(a, 2) ^ rotate(a, 13) ^ rotate(a, 22)) +
        ((a & b) ^ (a & c) ^ (b & c))) | 0;
      h = g; g = f; f = e; e = (d + t1) | 0;
      d = c; c = b; b = a; a = (t1 + t2) | 0;
    }
    s[0] += a; s[1] += b; s[2] += c; s[3] += d;
    s[4] += e; s[5] += f; s[6] += g; s[7] += h;
  };

  SHA256.prototype.update = function(bytes) {
    if (this.finished) {
      throw new Error('SHA-256 digest is already finished');
    }
    this.length += bytes.length;
    if (this.length > 9007199254740991) {
      throw new Error('File is too large to hash accurately');
    }
    var at = 0;
    if (this.used) {
      var take = Math.min(64 - this.used, bytes.length);
      this.block.set(bytes.subarray(0, take), this.used);
      this.used += take;
      at += take;
      if (this.used === 64) {
        this.compress(this.block, 0);
        this.used = 0;
      }
    }
    while (at + 64 <= bytes.length) {
      this.compress(bytes, at);
      at += 64;
    }
    if (at < bytes.length) {
      this.block.set(bytes.subarray(at), this.used);
      this.used += bytes.length - at;
    }
    return this;
  };

  SHA256.prototype.hex = function() {
    if (!this.finished) {
      this.block[this.used++] = 0x80;
      if (this.used > 56) {
        this.block.fill(0, this.used);
        this.compress(this.block, 0);
        this.used = 0;
      }
      this.block.fill(0, this.used, 56);
      var view = new DataView(this.block.buffer);
      view.setUint32(56, Math.floor(this.length / 0x20000000), false);
      view.setUint32(60, (this.length * 8) >>> 0, false);
      this.compress(this.block, 0);
      this.finished = true;
    }
    var output = '';
    for (var i = 0; i < this.state.length; i++) {
      output += ('00000000' + this.state[i].toString(16)).slice(-8);
    }
    return output;
  };

  if (typeof module !== 'undefined' && module.exports) {
    module.exports = SHA256;
  } else {
    root.WSKSHA256 = SHA256;
  }
})(typeof window !== 'undefined' ? window : this);
