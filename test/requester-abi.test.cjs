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
  const calls = [], elements = new Map(), created = [];
  const element = tag => {
    const el = { tag, children: [], textContent: "", hidden: false, addEventListener() {},
      append(...children) { this.children.push(...children); },
      replaceChildren(...children) { this.children = children; },
      set innerHTML(_) { throw new Error("untrusted HTML rendering"); },
    };
    created.push(el);
    return el;
  };
  const get = id => {
    if (!elements.has(id)) elements.set(id, element(id));
    return elements.get(id);
  };
  const ctx = vm.createContext({
    TextDecoder,
    document: { getElementById: get, querySelector: get, createElement: element },
    window: { ethereum: { async request(call) { calls.push(call); return responses.shift(); } } },
    fetch() { throw new Error("unexpected network fetch"); },
  });
  vm.runInContext(script, ctx);
  return { ctx, calls, elements, created };
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

test("job callback and URI event use the protocol tuple without changing the static Job or oracle ABI", () => {
  assert.equal(artifact.methodIdentifiers["onJobResult(bytes32,bytes32,string)"], "325a77b4");
  assert.equal(artifact.methodIdentifiers["onJobResult(bytes32,bytes)"], undefined);
  const callback = abi.find(e => e.type === "function" && e.name === "onJobResult");
  assert.deepEqual(callback.inputs.map(i => [i.name, i.type]),
    [["requestId", "bytes32"], ["resultHash", "bytes32"], ["uri", "string"]]);
  const event = abi.find(e => e.type === "event" && e.name === "JobResultURI");
  assert.deepEqual(event.inputs.map(i => [i.type, i.indexed]), [["bytes32", true], ["string", false]]);
  const fields = abi.find(e => e.type === "function" && e.name === "getJob").outputs[0].components;
  assert.equal(fields.length, 15);
  assert.ok(fields.every(f => f.type !== "string" && f.type !== "bytes"));
  assert.equal(fields[11].name, "resultHash");
  const oracle = abi.find(e => e.type === "function" && e.name === "onReviewResult");
  assert.deepEqual(oracle.inputs.map(i => i.type), ["bytes32", "tuple", "bytes"]);
});

test("URI event decoder agrees with cast for IPFS, HTTPS, Unicode and empty strings", () => {
  const { ctx } = load();
  for (const uri of ["ipfs://fixture/result.json", "https://example.invalid/intake-results/123", "ipfs://résultat/😀", ""]) {
    ctx.data = execFileSync("cast", ["abi-encode", "f(string)", uri], { encoding: "utf8" }).trim();
    assert.equal(vm.runInContext("decodeResultURI(data)", ctx), uri);
  }
});

test("URI decoder rejects malformed offsets, lengths, padding, oversized data and invalid UTF-8", () => {
  const { ctx } = load();
  const cases = [null, "0x", "0xzz", "0x" + word(32), "0x" + word(64) + word(0),
    "0x" + word(32) + word(1), "0x" + word(32) + word(1n << 255n),
    "0x" + word(32) + word(32769), "0x" + word(32) + word(0) + word(0),
    "0x" + word(32) + word(1) + "61" + "0".repeat(61) + "1",
    "0x" + word(32) + word(1) + "c3" + "0".repeat(62),
    "0x" + word(32) + word(32769) + "00".repeat(32800)];
  for (const data of cases) {
    ctx.data = data;
    assert.throws(() => vm.runInContext("decodeResultURI(data)", ctx));
  }
});

const requesterAddress = "0x" + "12".repeat(20), requestId = "0x" + "34".repeat(32);
const uriTopic = "0xb7024b3387ec94e50f20e6f13d42c52ecb72ae8b532d7c595b5a094954a78e0b";
function uriLog(uri) {
  return { address: requesterAddress, topics: [uriTopic, requestId], blockNumber: "0x123",
    transactionHash: "0x" + "56".repeat(32),
    data: execFileSync("cast", ["abi-encode", "f(string)", uri], { encoding: "utf8" }).trim() };
}

test("history exposes URI only as unverified text, with no HTML, links or content fetching", async () => {
  const values = ["javascript:alert(1)", "data:text/html,<script>alert(1)</script>",
    '<img src=x onerror="alert(1)">', "ipfs://fixture/result.json", ""];
  const { ctx, calls, elements, created } = load([values.map(uriLog)]);
  ctx.addr = requesterAddress; ctx.id = requestId;
  assert.equal(await vm.runInContext('history("", addr, id, "256")', ctx), values.length);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].method, "eth_getLogs");
  const filter = calls[0].params[0];
  assert.equal(filter.address, requesterAddress);
  assert.equal(filter.fromBlock, "0x100");
  assert.equal(filter.topics[1], requestId);
  assert.ok(filter.topics[0].includes(uriTopic));
  const rows = elements.get("#history tbody").children;
  values.forEach((uri, i) => {
    assert.equal(rows[i].children[3].textContent, "Result URI (unverified): " + (uri || "(empty URI)"));
    assert.equal(rows[i].children[3].children.length, 0);
  });
  assert.ok(created.every(el => ["f", "history", "#history tbody", "tr", "td"].includes(el.tag)));
  assert.equal(elements.get("history").hidden, false);
});

test("history filters other contracts, requests, unknown topics and removed logs", async () => {
  const good = uriLog("ipfs://fixture");
  const logs = [{ ...good, address: "0x" + "ab".repeat(20) },
    { ...good, topics: [uriTopic, "0x" + "cd".repeat(32)] },
    { ...good, topics: ["0x" + "ef".repeat(32), requestId] }, { ...good, removed: true }, good];
  const { ctx, elements } = load([logs, logs.slice(0, -1)]);
  ctx.addr = requesterAddress; ctx.id = requestId;
  assert.equal(await vm.runInContext('history("", addr, id, "")', ctx), 1);
  assert.equal(elements.get("#history tbody").children.length, 1);
  assert.equal(await vm.runInContext('history("", addr, id, "")', ctx), 0);
  assert.equal(elements.get("history").hidden, true);
});

test("malformed URI logs show unavailable without hiding later history or granting review approval", async () => {
  const good = uriLog("ipfs://fixture");
  const { ctx, elements } = load([[{ ...good, data: "0x" },
    { ...good, topics: [...good.topics, requestId] }, good]]);
  ctx.addr = requesterAddress; ctx.id = requestId;
  assert.equal(await vm.runInContext('history("", addr, id, "")', ctx), 3);
  const rows = elements.get("#history tbody").children;
  assert.match(rows[0].children[3].textContent, /Result URI unavailable/);
  assert.match(rows[1].children[3].textContent, /Result URI unavailable/);
  assert.equal(rows[2].children[3].textContent, "Result URI (unverified): ipfs://fixture");
  ctx.w = Array(15).fill(word(0)); ctx.w[3] = word(2); ctx.w[11] = "ab".repeat(32);
  const job = vm.runInContext("jobRows(w)", ctx);
  assert.equal(job.find(r => r[0] === "Result hash")[1], "0x" + ctx.w[11]);
  assert.equal(job.find(r => r[0] === "Review")[1], "No verified review result");
});

test("build fingerprints match compiler artifacts and requester runtime stays below EIP-170", () => {
  const fingerprints = JSON.parse(readFileSync(path.join(root, "docs/build-fingerprints.json")));
  assert.equal(fingerprints.compiler, "0.8.26");
  for (const [name, expected] of Object.entries(fingerprints.contracts)) {
    const built = JSON.parse(readFileSync(path.join(root, `out/${name}.sol/${name}.json`)));
    for (const [key, field] of [["creationCode", "bytecode"], ["runtimeCode", "deployedBytecode"]]) {
      const code = built[field].object;
      assert.equal((code.length - 2) / 2, expected[key + "Bytes"], `${name} ${key} bytes`);
      assert.equal(execFileSync("cast", ["keccak", code], { encoding: "utf8" }).trim(),
        expected[key + "Hash"], `${name} ${key} hash`);
    }
  }
  assert.ok(fingerprints.contracts.HookJobRequester.runtimeCodeBytes < 24576);
});
