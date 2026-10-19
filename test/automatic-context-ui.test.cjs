'use strict';
const {test} = require('node:test');
const assert = require('node:assert/strict');
const {wallet,A,requester,creator,token,other,job,ask,txHash} = require('./helpers/automatic-wallet.cjs');
const output = w => w.el('output').textContent;

for (const [reserve,cap,currentCap,amount,allowed] of [
  [500000000000000000n,1000000000000000000n,2000000n,1n,true],
  [500000n,1000000n,2000000000000000000n,500001n,false]
]) test('original-token UI cap across rotation '+reserve, async () => {
  const w = wallet({reserve,cap,currentCap}); w.el('topUpAmount').value = String(amount);
  await w.el('connect').click(); await w.el('approveTopUp').click();
  assert.equal(w.sent.length,allowed ? 1 : 0,output(w));
  assert.ok(w.calls.some(c => c.method === 'eth_call' && c.params[0].data === '0xc9638491'+A.address(token)));
});

for (const button of ['approveTopUp','topUp']) test(button+' rejects requester drift on final validation read', async () => {
  const w = wallet({allowance:1n,allowOtherRequester:true}); await w.el('connect').click();
  w.after = c => { if (c.method === 'eth_call' && c.params[0].data === '0x'+A.selectors.head) w.el('requester').value = other; };
  await w.el(button).click();
  assert.equal(w.sent.length,0,output(w));
  assert.match(output(w),/changed|drift|reconnect|connect again/i);
});

test('wallet network is anchored before top-up and explicit in transaction', async () => {
  const w = wallet(); await w.el('connect').click(); await w.el('approveTopUp').click();
  assert.equal(w.sent.length,1,output(w));
  assert.equal(w.sent[0].chainId,'0x7a69'); assert.equal(w.sent[0].from,creator);
  w.state.chain = '0x1'; await w.el('topUp').click();
  assert.equal(w.sent.length,1,output(w));
  assert.match(output(w),/chain|network|reconnect/i);
});

const drifts = {
  requester:w => { w.el('requester').value = other; },
  rawWhitespace:w => { w.el('topUpAmount').value += ' '; },
  unrelatedForm:w => { w.el('artifact').value += ' '; },
  inputABA:async w => { const e=w.el('brief'), old=e.value; e.value='edited'; await e.fire('input'); e.value=old; },
  changeABA:async w => { const e=w.el('job'), old=e.value; e.value=ask; await e.fire('change'); e.value=old; },
  account:w => { w.state.sender = other; },
  chain:w => { w.state.chain = '0x1'; },
  accountsEvent:w => { w.emit('accountsChanged',[creator]); },
  chainEvent:w => { w.emit('chainChanged','0x7a69'); },
  disconnect:w => { w.emit('disconnect',{code:4900}); },
  provider:w => { w.window.ethereum = {request:() => {throw Error('replacement provider must not be used');}}; },
  request:w => { w.provider.request = () => {throw Error('replacement request must not be used');}; }
};
const stages = {
  validation:c => c.method === 'eth_call' && c.params[0].data === '0x'+A.selectors.head,
  estimate:c => c.method === 'eth_estimateGas',
  submission:c => c.method === 'eth_sendTransaction',
  receipt:c => c.method === 'eth_getTransactionReceipt',
  allowance:c => c.method === 'eth_call' && c.params[0].data.startsWith('0xdd62ed3e')
};
for (const [name,change] of Object.entries(drifts)) for (const [stage,at] of Object.entries(stages)) {
  test(name+' drift at '+stage+' aborts approval and requires reconnection', async () => {
    const w = wallet(); await w.el('connect').click();
    let hit = false;
    w.after = async c => { if (!hit && at(c)) { hit=true; await change(w); } };
    await w.el('approveTopUp').click();
    assert.equal(hit,true);
    assert.equal(w.sent.length,['submission','receipt','allowance'].includes(stage) ? 1 : 0,output(w));
    assert.match(output(w),/changed|reconnect|connect/i);
    assert.doesNotMatch(output(w),/Approval confirmed|Mined and read back/);
    if (w.sent.length) assert.ok(output(w).includes(txHash),'returned hash must survive a failed context check');
    const count=w.sent.length; w.after=null;
    await w.el('topUp').click();
    assert.equal(w.sent.length,count,'must not transact again without reconnecting');
  });
}

for (const button of ['approve','open','commitArtifact','verdict','cancel','renew','topUp','withdraw']) {
  test(button+' snapshots every target and aborts drift after estimation', async () => {
    const w=wallet({allowance:1n,price:500n}); await w.el('connect').click();
    let hit=false;
    w.after=c => { if(c.method==='eth_estimateGas') { hit=true; w.el('requester').value=other; } };
    await w.el(button).click();
    assert.equal(hit,true,output(w)); assert.equal(w.sent.length,0,output(w));
  });
  test(button+' suppresses success and preserves hash on receipt drift', async () => {
    const w=wallet({allowance:1n,price:500n}); await w.el('connect').click();
    w.after=c => { if(c.method==='eth_getTransactionReceipt') w.state.chain='0x1'; };
    await w.el(button).click();
    assert.equal(w.sent.length,1,output(w));
    assert.ok(output(w).includes(txHash));
    assert.match(output(w),/chain changed/i); assert.doesNotMatch(output(w),/Mined and read back/);
  });
}

test('estimate mutation cannot rewrite the explicit send payload', async () => {
  const w=wallet(); await w.el('connect').click();
  let estimate;
  w.before=c => { if(c.method==='eth_estimateGas') {
    estimate=c.params[0]; Object.assign(estimate,{to:other,from:other,data:'0x',chainId:'0x1',value:'0x1'});
  }};
  await w.el('approveTopUp').click();
  assert.equal(w.sent.length,1,output(w));
  assert.notEqual(w.sent[0],estimate);
  assert.deepEqual(w.sent[0],{from:creator,chainId:'0x7a69',to:token,
    data:'0x095ea7b3'+A.address(requester)+A.uint(1),value:'0x0',gas:'0x20000'});
});

test('one lock covers every action including connect and status while a wallet call waits', async () => {
  const w=wallet(); await w.el('connect').click();
  let resume,entered;
  const waiting=new Promise(resolve => {entered=resolve;});
  w.before=c => { if(c.method==='eth_estimateGas') { entered(); return new Promise(resolve=>{resume=resolve;}); } };
  const action=w.el('approveTopUp').click(); await waiting;
  const count=w.calls.length;
  for(const button of ['connect','status','approve','open','commitArtifact','verdict','cancel','renew','approveTopUp','topUp','withdraw']) {
    assert.equal(w.el(button).disabled,true);
    await w.el(button).click(); assert.equal(w.calls.length,count);
  }
  resume(); await action;
  assert.equal(w.sent.length,1,output(w)); assert.equal(w.el('connect').disabled,false);
});

for(const [name,change] of Object.entries(drifts)) test('connect freezes context before account permission: '+name, async () => {
  const w=wallet();
  w.after=async c=> { if(c.method==='eth_requestAccounts') await change(w); };
  await w.el('connect').click();
  assert.doesNotMatch(output(w),/Automatic requester verified/);
  assert.equal(w.el('account').textContent,'');
});

test('requester and wallet events invalidate an idle connection even after values return', async () => {
  for(const mutate of [async w=>{await w.el('requester').fire('input');},
    w=>w.emit('accountsChanged',[creator]),w=>w.emit('chainChanged','0x7a69'),w=>w.emit('disconnect',{})]) {
    const w=wallet(); await w.el('connect').click(); await mutate(w);
    const count=w.calls.length; await w.el('status').click();
    assert.match(output(w),/Connect your wallet first/); assert.equal(w.calls.length,count);
    await w.el('connect').click(); assert.match(output(w),/verified/);
  }
});

test('ordinary form edits between completed actions can be captured without reconnecting', async () => {
  const w=wallet(); await w.el('connect').click();
  w.el('topUpAmount').value='2'; await w.el('topUpAmount').fire('input');
  await w.el('approveTopUp').click();
  assert.equal(w.sent.length,1,output(w)); assert.equal(w.sent[0].data.slice(-64),A.uint(2));
});

for(const overrides of [{capError:true},{capRaw:'0x'},{cap:0n}]) test('token-cap read fails closed without compatibility fallback '+JSON.stringify(overrides,(_,v)=>typeof v==='bigint'?String(v):v),async()=>{
  const w=wallet(overrides); await w.el('connect').click(); await w.el('approveTopUp').click();
  assert.equal(w.sent.length,0);
  assert.ok(!w.calls.some(c=>c.method==='eth_call' && c.params[0].data==='0x'+A.selectors.maxPrice));
});

for(const [name,change] of Object.entries({
  job:w=>{w.state.review=1;}, ask:w=>{w.state.ask=job;}, candidate:w=>{w.state.candidate=2n;},
  context:w=>{w.state.context=1n;}, reserve:w=>{w.state.reserve+=1n;},
  noRefresh:w=>{w.state.start=900000n;}, futureStart:w=>{w.state.start=w.state.head+1n;},
  deadline:w=>{w.state.deadline-=1n;}, cancelled:w=>{w.state.cancelled=1;}
})) test('top-up rejects incorrect '+name+' readback after a successful receipt',async()=>{
  const w=wallet({allowance:1n}); await w.el('connect').click();
  w.after=c=>{if(c.method==='eth_getTransactionReceipt')change(w);};
  await w.el('topUp').click(); assert.equal(w.sent.length,1,output(w));
  assert.match(output(w),/readback|refreshed/); assert.ok(output(w).includes(txHash));
  assert.doesNotMatch(output(w),/Mined and read back/);
});

test('approval requires exact allowance, not merely sufficient allowance',async()=>{
  for(const button of ['approve','approveTopUp']) for(const amount of [0n,999999n]) {
    const w=wallet();await w.el('connect').click();
    w.after=c=>{if(c.method==='eth_getTransactionReceipt')w.state.allowance=amount;};
    await w.el(button).click();assert.equal(w.sent.length,1,output(w));
    assert.match(output(w),/readback differs/);assert.ok(output(w).includes(txHash));
  }
});

test('status rejects context drift and cannot publish stale success',async()=>{
  const w=wallet();await w.el('connect').click();
  w.after=c=>{if(c.method==='eth_call' && c.params[0].data.startsWith('0x'+A.selectors.funding))w.state.chain='0x1';};
  await w.el('status').click();assert.match(output(w),/chain changed/i);assert.doesNotMatch(output(w),/jobStatus/);
});

for(const button of ['approveTopUp','topUp']) test(button+' detects wallet drift while polling a pending receipt',async()=>{
  const w=wallet({allowance:1n,pending:1});await w.el('connect').click();
  w.wait=()=>{w.state.chain='0x1';};
  await w.el(button).click();
  assert.equal(w.sent.length,1);assert.equal(w.calls.filter(c=>c.method==='eth_getTransactionReceipt').length,1);
  assert.ok(output(w).includes(txHash));assert.match(output(w),/chain changed/i);
});

test('pending receipts can complete with one submission and full final readback',async()=>{
  const w=wallet({allowance:1n,pending:2});await w.el('connect').click();await w.el('topUp').click();
  assert.equal(w.sent.length,1);assert.equal(w.calls.filter(c=>c.method==='eth_getTransactionReceipt').length,3);
  const result=JSON.parse(output(w));assert.equal(result.reserve.amount,'501');
  assert.equal(result.verdictReadiness.blocksRemaining,'8');assert.equal(result.transaction,txHash);
});

test('reverted receipt never reports approval or funding success',async()=>{
  const w=wallet({receiptStatus:'0x0'});await w.el('connect').click();await w.el('approveTopUp').click();
  assert.match(output(w),/Transaction reverted/);assert.ok(output(w).includes(txHash));
  assert.doesNotMatch(output(w),/Approval confirmed|Mined and read back/);
});

test('RPC guards bracket each operation with account and chain reads',async()=>{
  const w=wallet();await w.el('connect').click();w.calls.length=0;
  await w.el('approveTopUp').click();assert.equal(w.sent.length,1,output(w));
  for(let i=0;i<w.calls.length;i++) if(!['eth_accounts','eth_chainId'].includes(w.calls[i].method)) {
    assert.deepEqual(w.calls.slice(i-2,i).map(c=>c.method),['eth_accounts','eth_chainId']);
    assert.deepEqual(w.calls.slice(i+1,i+3).map(c=>c.method),['eth_accounts','eth_chainId']);
  }
});

for(const id of ['requester','deployer','spec','brief','buildFee','reserve','job','artifact','commit','ask','topUpAmount','token']) {
  test('captures raw '+id+' before the first await',async()=>{
    const w=wallet();await w.el('connect').click();let hit=false;
    w.after=c=>{if(!hit && c.method==='eth_accounts'){hit=true;w.el(id).value+=' ';}};
    await w.el('approveTopUp').click();assert.equal(w.sent.length,0,output(w));
    assert.match(output(w),/changed|reconnect/i);
  });
}

test('final top-up readback rejects a change after the status funding read',async()=>{
  const w=wallet({allowance:1n});await w.el('connect').click();
  let submitted=false;
  w.after=c=>{
    if(c.method==='eth_sendTransaction')submitted=true;
    if(submitted && c.method==='eth_call' && c.params[0].data.startsWith('0x'+A.selectors.funding))w.state.deadline+=1n;
  };
  await w.el('topUp').click();assert.equal(w.sent.length,1);assert.match(output(w),/readback changed/);
  assert.ok(output(w).includes(txHash));assert.doesNotMatch(output(w),/Mined and read back/);
});

test('final wallet probe after readbacks still withholds success on drift',async()=>{
  const w=wallet();await w.el('connect').click();
  let submitted=false, finalProbe=false;
  w.after=c=>{
    if(c.method==='eth_sendTransaction')submitted=true;
    if(submitted && c.method==='eth_call' && c.params[0].data.startsWith('0x'+A.selectors.reserveDeadline))finalProbe=true;
    if(finalProbe && c.method==='eth_chainId')w.emit('disconnect',{});
  };
  await w.el('approveTopUp').click();assert.equal(w.sent.length,1);assert.ok(output(w).includes(txHash));
  assert.doesNotMatch(output(w),/Approval confirmed|Mined and read back/);
});
