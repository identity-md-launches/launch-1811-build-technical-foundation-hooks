// Run from the repository root. Optional argv[2] is the base automatic-ui.js in test/scratch.
'use strict';
const {test} = require('node:test');
const assert = require('node:assert/strict');
const {readFileSync} = require('node:fs');
const {wallet,A,other,token} = require('../../../test/helpers/automatic-wallet.cjs');
const source = readFileSync(process.argv[2] || 'site/automatic-ui.js','utf8');
for(const [reserve,cap,currentCap,amount,allowed] of [
  [500000000000000000n,1000000000000000000n,2000000n,1n,true],
  [500000n,1000000n,2000000000000000000n,500001n,false]
]) test('original-token cap across rotation '+reserve,async()=>{
  const w=wallet({reserve,cap,currentCap},source);w.el('topUpAmount').value=String(amount);
  await w.el('connect').click();await w.el('approveTopUp').click();
  assert.equal(w.sent.length,allowed?1:0,w.el('output').textContent);
  assert.ok(w.calls.some(c=>c.method==='eth_call' && c.params[0].data==='0xc9638491'+A.address(token)));
});
for(const button of ['approveTopUp','topUp']) test(button+' must refuse requester drift before sending',async()=>{
  // Both addresses expose the same interface, so a later interface check cannot hide the race.
  const w=wallet({allowance:1n,allowOtherRequester:true},source);await w.el('connect').click();
  w.after=c=>{if(c.method==='eth_call' && c.params[0].data==='0x'+A.selectors.head)w.el('requester').value=other;};
  await w.el(button).click();
  assert.equal(w.sent.length,0,'sent an unvalidated target/spender: '+JSON.stringify(w.sent));
});
test('transaction must carry the chain pinned at connect',async()=>{
  const w=wallet({},source);await w.el('connect').click();await w.el('approveTopUp').click();
  assert.equal(w.sent.length,1);assert.equal(w.sent[0].chainId,'0x7a69');
});
