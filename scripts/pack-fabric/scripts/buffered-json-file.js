"use strict";

const fs = require("node:fs");

// Keep streaming JSON bounded without issuing a filesystem write for every
// comma and proof. This changes only write granularity, never the JSON bytes.
class BufferedJSONFile {
  constructor(file, limit = 256 * 1024) {
    if (!Number.isSafeInteger(limit) || limit < 1) throw new Error("invalid write buffer limit");
    this.fd = fs.openSync(file, "w");
    this.limit = limit;
    this.chunks = [];
    this.characters = 0;
  }
  write(chunk) {
    if (this.fd === null) throw new Error("writer is closed");
    if (typeof chunk !== "string") throw new Error("JSON chunk must be a string");
    this.chunks.push(chunk);
    this.characters += chunk.length;
    if (this.characters >= this.limit) this.flush();
  }
  flush() {
    if (!this.chunks.length) return;
    const data = Buffer.from(this.chunks.join(""), "utf8");
    let offset = 0;
    while (offset < data.length) {
      const written = fs.writeSync(this.fd, data, offset, data.length - offset);
      if (written <= 0) throw new Error("JSON write made no progress");
      offset += written;
    }
    this.chunks = [];
    this.characters = 0;
  }
  close() {
    if (this.fd === null) return;
    try { this.flush(); }
    finally { fs.closeSync(this.fd); this.fd = null; }
  }
}

module.exports = { BufferedJSONFile };
