"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const http = require("node:http");
const { fetchBuffer } = require("./graph");

async function withServer(handler, run) {
  const server = http.createServer(handler);
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  try {
    const address = server.address();
    return await run(`http://127.0.0.1:${address.port}`);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
}

test("remote pack fetch fills one declared-size buffer across chunks", async () => {
  const expected = Buffer.from("complete-v4-pack");
  await withServer((req, res) => {
    res.writeHead(200, { "content-length": String(expected.length) });
    res.write(expected.subarray(0, 4));
    res.write(expected.subarray(4, 10));
    res.end(expected.subarray(10));
  }, async (base) => {
    const actual = await fetchBuffer(`${base}/graph.v4.bin`);
    assert.deepEqual(actual, expected);
  });
});

test("remote pack fetch fails closed on a truncated declared object", async () => {
  await withServer((req, res) => {
    res.writeHead(200, { "content-length": "20" });
    res.destroy();
  }, async (base) => {
    await assert.rejects(fetchBuffer(`${base}/graph.v4.bin`));
  });
});
