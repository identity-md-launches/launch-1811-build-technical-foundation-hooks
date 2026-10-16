"use strict";
const assert = require("node:assert/strict");
const { test } = require("node:test");
const { execFileSync } = require("node:child_process");
const { readFileSync } = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const root = path.resolve(__dirname, "..");
const artifact = JSON.parse(readFileSync(path.join(root, "out/HookJobRequester.sol/HookJobRequester.json")));
const abi = JSON.parse(readFileSync(path.join(root, "site/HookJobRequester.abi.json")));
const html = readFileSync(path.join(root, "site/index.html"), "utf8");
const script = html.match(/<script>([\s\S]*?)<\/script>/)[1];
const word = value => BigInt(value).toString(16).padStart(64, "0");

function load(responses = []) {
  const calls = [];
  const ctx = vm.createContext({
    document: { getElementById: () => ({ addEventListener() {} }) },
    window: { ethereum: { async request(call) { calls.push(call); return responses.shift(); } } },
  });
  vm.runInContext(script, ctx);
  return { ctx, calls };
}

test("published requester ABI is exactly the compiler ABI and has only capped paid calls", () => {
  assert.deepEqual(abi, artifact.abi);
  assert.equal(artifact.methodIdentifiers["openJob(bytes32,bytes,uint256)"], "3574ac96");
  assert.equal(artifact.methodIdentifiers["requestReview(bytes32,uint256)"], "86304ddd");
  assert.equal(artifact.methodIdentifiers["openJob(bytes32,bytes)"], undefined);
  assert.equal(artifact.methodIdentifiers["requestReview(bytes32)"], undefined);
});

test("status page selectors and job event topics match the compiled contract", () => {
  const { ctx } = load();
  const selectors = { GET_JOB: "getJob(bytes32)", JOBS_OF: "jobsOf(address)",
    RECEIPT_EPOCH: "reviewReceiptSignerEpoch(bytes32)", REVOKED_EPOCH: "revokedSignerEpochs(uint32)" };
  for (const [name, signature] of Object.entries(selectors)) {
    assert.equal(vm.runInContext(name, ctx), "0x" + artifact.methodIdentifiers[signature]);
  }
  const topics = vm.runInContext("EVENTS", ctx);
  const expected = new Map(abi.filter(e => e.type === "event" &&
    ["jobRequestId", "requestId"].includes(e.inputs[0]?.name)).map(e => {
      const signature = `${e.name}(${e.inputs.map(i => i.type).join(",")})`;
      const topic = execFileSync("cast", ["keccak", signature], { encoding: "utf8" }).trim();
      return [topic, e.name];
    }));
  assert.equal(Object.keys(topics).length, expected.size);
  for (const [topic, label] of Object.entries(topics)) assert.ok(label.startsWith(expected.get(topic)));
});

test("pending receipt shows explicit signer revocation before individual closure", async () => {
  const incident = "0x" + "ab".repeat(32);
  const { ctx, calls } = load(["0x" + word(2), incident]);
  ctx.w = Array(15).fill(word(0)); ctx.w[4] = word(1); ctx.w[13] = "cd".repeat(32);
  const rows = await vm.runInContext('receiptRows("", "requester", w)', ctx);
  assert.match(rows[0][1], /Signer epoch 2 revoked; cannot finalize/);
  assert.equal(rows[1][1], incident);
  assert.equal(calls[0].params[0].data, "0x585ae49a" + ctx.w[13]);
  assert.equal(calls[1].params[0].data, "0xbc31fa7d" + word(2));
});

test("receipt reads distinguish pending arrival, retained answer and terminal job", async () => {
  for (const [epoch, expected] of [[0, /Awaiting a signed answer/], [1, /awaiting owner binding or correction/]]) {
    const { ctx } = load(["0x" + word(epoch), "0x" + word(0)]);
    ctx.w = Array(15).fill(word(0)); ctx.w[4] = word(1);
    const rows = await vm.runInContext('receiptRows("", "requester", w)', ctx);
    assert.match(rows[0][1], expected);
  }
  const { ctx, calls } = load();
  ctx.w = Array(15).fill(word(0)); ctx.w[4] = word(3);
  assert.equal((await vm.runInContext('receiptRows("", "requester", w)', ctx)).length, 0);
  assert.equal(calls.length, 0);
});

test("malformed revocation reads fail rather than display a verified receipt", async () => {
  const { ctx } = load(["0x" + word(1), "0x"]);
  ctx.w = Array(15).fill(word(0)); ctx.w[4] = word(1);
  await assert.rejects(vm.runInContext('receiptRows("", "requester", w)', ctx), /invalid signer revocation response/);
});
