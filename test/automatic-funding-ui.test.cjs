'use strict';
const {test} = require('node:test');
const assert = require('node:assert/strict');
const {readFileSync} = require('node:fs');
const {execFileSync} = require('node:child_process');
const vm = require('node:vm');
const A = require('../site/automatic.js');
const requester = '0x'+'12'.repeat(20), creator = '0x'+'23'.repeat(20), token = '0x'+'34'.repeat(20);
const currentToken = '0x'+'45'.repeat(20), job = '0x'+'56'.repeat(32), ask = '0x'+'67'.repeat(32);
const cast = (...args) => execFileSync('cast', args, {encoding:'utf8'}).trim().toLowerCase();
const words = (...values) => '0x'+values.map(x => A.uint(x)).join('');

function wallet(overrides = {}) {
  const state = {price:501n, reserve:500n, cap:1000n, allowance:0n, status:2, review:0, cancelled:0,
    committed:true, spent:false, phase:1, available:true, sender:creator, ...overrides};
  const elements = new Map(), sent = [], calls = [];
  const el = id => {
    if (!elements.has(id)) elements.set(id, {value:'',textContent:'',addEventListener(e,fn){this.click=fn;}});
    return elements.get(id);
  };
  el('requester').value = requester; el('job').value = job; el('ask').value = ask; el('topUpAmount').value = '1';
  const provider = {async request({method,params}) {
    calls.push({method,params});
    if (method === 'eth_accounts' || method === 'eth_requestAccounts') return [state.sender];
    if (method === 'eth_estimateGas') return '0x20000';
    if (method === 'eth_sendTransaction') {
      const tx = params[0]; sent.push(tx);
      if (tx.to === token) state.allowance = BigInt('0x'+tx.data.slice(-64));
      if (tx.data.startsWith('0x'+A.selectors.topUp)) {
        const amount = BigInt('0x'+tx.data.slice(-64));
        assert.ok(state.allowance >= amount);
        state.reserve += amount; state.allowance -= amount; state.phase = 0;
      }
      return job;
    }
    if (method === 'eth_getTransactionReceipt') return {status:'0x1'};
    assert.equal(method,'eth_call');
    const {to,data} = params[0];
    if (data.startsWith('0xdd62ed3e')) { assert.equal(to,token); return words(state.allowance); }
    assert.equal(to,requester);
    if (data === '0x'+A.selectors.automatic) return words(1);
    if (data === '0x'+A.selectors.asset) return '0x'+A.address(currentToken);
    if (data === '0x'+A.selectors.maxPrice) return words(state.cap);
    if (data === '0x'+A.selectors.head) return words(900008);
    if (data === '0x'+A.selectors.depth) return words(8);
    if (data.startsWith('0x'+A.selectors.job)) {
      const w = Array(15).fill(A.uint(0)); w[0] = A.address(creator); w[3] = A.uint(state.status); w[4] = A.uint(state.review);
      return '0x'+w.join('');
    }
    if (data.startsWith('0x'+A.selectors.ask)) return ask;
    if (data.startsWith('0x'+A.selectors.askContext)) return words(1,state.spent ? 1 : 0,0,0,0,0,0,0,0);
    if (data.startsWith('0x'+A.selectors.candidate)) return words(state.committed ? 1 : 0);
    if (data.startsWith('0x'+A.selectors.approved) || data.startsWith('0x'+A.selectors.epoch)) return words(0);
    if (data.startsWith('0x'+A.selectors.reserveDeadline)) return words(1800086400);
    if (data.startsWith('0x'+A.selectors.reserve)) return '0x'+A.address(token)+A.uint(state.reserve)+A.uint(state.cancelled);
    if (data.startsWith('0x'+A.selectors.readiness)) return words(state.phase,900008,state.phase ? 900000 : 900008,900000);
    if (data.startsWith('0x'+A.selectors.funding)) {
      if (!state.available) throw Error('quote unavailable');
      return words(state.price,state.reserve,BigInt(token));
    }
    throw Error('unexpected call '+data);
  }};
  vm.runInNewContext(readFileSync('site/automatic-ui.js','utf8'), {
    AutoHooks:A,document:{getElementById:el},window:{ethereum:provider},setTimeout
  });
  return {state, el, sent, calls};
}

test('funding decoder and readiness fail closed on unavailable, zero, unaffordable or malformed quotes', () => {
  const phase = {ready:true};
  for (const price of [0,501]) assert.equal(A.fundedReadiness(phase,A.decodeFunding(words(price,500,BigInt(token)))).ready,false);
  assert.equal(A.fundedReadiness(phase,{available:false,funded:false}).ready,false);
  assert.equal(A.fundedReadiness(phase,A.decodeFunding(words(500,500,BigInt(token)))).ready,true);
  assert.equal(A.fundedReadiness({ready:false},A.decodeFunding(words(500,500,BigInt(token)))).ready,false);
  for (const bad of ['0x',words(1,2,0),words(1,2,1n<<160n)]) assert.throws(() => A.decodeFunding(bad));
});

test('wallet does not estimate or send an underfunded or unavailable verdict', async () => {
  for (const options of [{price:501n},{price:0n},{available:false}]) {
    const w = wallet(options);
    await w.el('verdict').click();
    assert.match(w.el('output').textContent,/not ready.*positive quote within reserve/);
    assert.ok(w.calls.every(c => c.method === 'eth_call'));
    assert.equal(w.sent.length,0);
  }
});

test('top-up is separate from a bounded original-token approval and reads the resulting state', async () => {
  const w = wallet();
  await w.el('connect').click();
  assert.equal(w.el('token').value,currentToken);
  await w.el('approveTopUp').click();
  assert.equal(w.sent.length,1);
  assert.equal(w.sent[0].to,token);
  assert.equal(w.sent[0].data,cast('calldata','approve(address,uint256)',requester,'1'));
  assert.equal(JSON.parse(w.el('output').textContent).allowanceReadback,'1');
  assert.equal(w.state.reserve,500n);
  await w.el('topUp').click();
  assert.equal(w.sent.length,2);
  assert.equal(w.sent[1].to,requester);
  assert.equal(w.sent[1].data,cast('calldata','topUpReserve(bytes32,uint256)',job,'1'));
  const result = JSON.parse(w.el('output').textContent);
  assert.equal(result.ask,ask);
  assert.equal(result.reserve.token,token);
  assert.equal(result.reserve.amount,'501');
  assert.equal(result.verdictReadiness.ready,false);
  assert.equal(result.verdictReadiness.funding.funded,true);
  assert.equal(result.verdictReadiness.blocksRemaining,'8');
  assert.equal(w.sent.every(tx => tx.value === '0x0'),true);
});

test('top-up controls reject wrong caller, bad phase, cancellation, missing commitment, spent ask and cap', async () => {
  for (const [options,pattern] of [[{sender:token},/Only the job requester/],[{status:1},/Delivered/],
    [{review:1},/Delivered/],[{review:3},/Delivered/],[{cancelled:1},/Cancelled/],
    [{committed:false},/Commit an artifact/],[{spent:true},/unspent ask/],[{cap:500n},/exceeds current maxPrice/]]) {
    for (const button of ['approveTopUp','topUp']) {
      const w = wallet(options); await w.el('connect').click(); await w.el(button).click();
      assert.match(w.el('output').textContent,pattern);
      assert.equal(w.sent.length,0);
      assert.ok(!w.calls.some(c => c.method === 'eth_estimateGas'));
    }
  }
  for (const amount of ['0','-1','1.5',String(1n<<256n)]) assert.throws(() => A.topUpCalldata(job,amount));
});

test('top-up rechecks the current cap after approval without sending a second transaction', async () => {
  const w = wallet(); await w.el('connect').click(); await w.el('approveTopUp').click();
  w.state.cap = 500n;
  await w.el('topUp').click();
  assert.equal(w.sent.length,1);
  assert.match(w.el('output').textContent,/exceeds current maxPrice/);
});
