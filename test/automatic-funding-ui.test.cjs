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

const {wallet} = require('./helpers/automatic-wallet.cjs');

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
    await w.el('connect').click();
    await w.el('verdict').click();
    assert.match(w.el('output').textContent,/not ready.*positive quote within reserve/);
    assert.ok(!w.calls.some(c => c.method === 'eth_estimateGas'));
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
