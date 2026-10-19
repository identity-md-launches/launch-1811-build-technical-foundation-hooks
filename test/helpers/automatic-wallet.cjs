'use strict';
const assert = require('node:assert/strict');
const {readFileSync} = require('node:fs');
const vm = require('node:vm');
const A = require('../../site/automatic.js');
const address = n => '0x'+n.repeat(20), hash = n => '0x'+n.repeat(32);
const requester = address('12'), creator = address('23'), token = address('34'), currentToken = address('45');
const deployer = address('78'), other = address('99'), job = hash('56'), ask = hash('67'), txHash = hash('89');
const words = (...values) => '0x'+values.map(x => A.uint(x)).join('');

function wallet(overrides = {}, source = readFileSync('site/automatic-ui.js','utf8')) {
  const state = {price:501n, reserve:500n, cap:1000n, currentCap:2000000n, allowance:0n, status:2, review:0,
    cancelled:0, committed:true, spent:false, phase:1, available:true, sender:creator, chain:'0x7a69',
    start:900000n, head:900008n, deadline:1800086400n, candidate:1n, ask, context:0n, ...overrides};
  const elements = new Map(), sent = [], calls = [], listeners = new Map();
  const el = id => {
    if (!elements.has(id)) {
      const handlers = new Map();
      const element = {value:'',textContent:'',disabled:false,
        addEventListener(event,fn){ if (!handlers.has(event)) handlers.set(event,[]); handlers.get(event).push(fn); },
        async fire(event){ for (const fn of handlers.get(event) || []) await fn({target:element,type:event}); },
        click(){ return element.fire('click'); }};
      elements.set(id,element);
    }
    return elements.get(id);
  };
  const spec = {schemaVersion:1,templateId:'hooks-store/bounded-swap/v1',chainId:'31337',poolManager:other,
    poolManagerCodeHash:hash('ab'),permissions:['afterInitialize','beforeSwap','afterSwap'],maxSpecifiedAmount:'1000000'};
  const artifact = Object.fromEntries(A.fields.map(f => [f,hash('ab')]));
  Object.assign(artifact,{jobRequestId:job,chainId:'31337',deployer,poolManager:other,permissions:4288});
  for (const [id,v] of Object.entries({requester,job,ask,token,topUpAmount:'1',spec:JSON.stringify(spec),
    deployer,brief:'Bounded hook',buildFee:'1000',reserve:'500',artifact:JSON.stringify(artifact),commit:address('ab')})) el(id).value = v;
  const w = {state,el,sent,calls,window:{},before:null,after:null,
    emit(event,payload){ for (const fn of listeners.get(event) || []) fn(payload); }};
  const provider = {on(event,fn){ if (!listeners.has(event)) listeners.set(event,[]); listeners.get(event).push(fn); },
    async request({method,params}) {
      assert.equal(this,provider,'provider request receiver must be preserved');
      const call = {method,params}; calls.push(call);
      if (w.before) await w.before(call);
      const result = respond(method,params);
      if (w.after) await w.after(call,result);
      return result;
    }};
  function respond(method,params) {
    if (method === 'eth_accounts' || method === 'eth_requestAccounts') return state.sender ? [state.sender] : [];
    if (method === 'eth_chainId') return state.chain;
    if (method === 'eth_estimateGas') return '0x20000';
    if (method === 'eth_sendTransaction') {
      const tx = {...params[0]}; sent.push(tx);
      if (tx.data.startsWith('0x095ea7b3')) state.allowance = BigInt('0x'+tx.data.slice(-64));
      if (tx.data.startsWith('0x'+A.selectors.topUp)) {
        const amount = BigInt('0x'+tx.data.slice(-64));
        assert.ok(state.allowance >= amount);
        state.reserve += amount; state.allowance -= amount; state.phase = 0; state.start = state.head;
      }
      if (tx.data.startsWith('0x'+A.selectors.renew)) { state.start = state.head; state.phase = 0; }
      return txHash;
    }
    if (method === 'eth_getTransactionReceipt' && state.pending) { --state.pending; return null; }
    if (method === 'eth_getTransactionReceipt') return {status:state.receiptStatus || '0x1',logs:[{address:requester,
      topics:['0x95e6cf60266f65ecf4a509b236fccd720bc64ef7099f4a859a49d18cab89334c',job]}]};
    assert.equal(method,'eth_call');
    const {to,data} = params[0];
    if (data.startsWith('0xdd62ed3e')) { assert.ok([token,currentToken].includes(to)); return words(state.allowance); }
    if (data === '0xb61e96a5') { assert.equal(to,deployer); return '0x'+A.address(requester); }
    if (data.startsWith('0x51102885')) return words(500);
    assert.ok(to === requester || (state.allowOtherRequester && to === other), 'unvalidated requester target '+to);
    if (data === '0x'+A.selectors.automatic) return words(1);
    if (data === '0x'+A.selectors.asset) return '0x'+A.address(currentToken);
    if (data === '0x'+A.selectors.intake) return '0x'+A.address(other);
    if (data === '0x'+A.selectors.jobAction) return hash('bc');
    if (data === '0x'+A.selectors.maxPrice) return words(state.currentCap);
    if (data.startsWith('0xc9638491')) {
      assert.equal(data,'0xc9638491'+A.address(token),'top-up cap must use reserve token');
      if (state.capError) throw Error('token cap unavailable');
      return state.capRaw === undefined ? words(state.cap) : state.capRaw;
    }
    if (data === '0x'+A.selectors.head) return words(state.head);
    if (data === '0x'+A.selectors.depth) return words(8);
    if (data.startsWith('0x'+A.selectors.job)) {
      const fields = Array(15).fill(A.uint(0)); fields[0] = A.address(creator);
      fields[3] = A.uint(state.status); fields[4] = A.uint(state.review);
      return '0x'+fields.join('');
    }
    if (data.startsWith('0x'+A.selectors.ask)) return state.ask;
    if (data.startsWith('0x'+A.selectors.askContext)) return '0x'+A.hex(job,32)+[state.spent ? 1 : 0,state.context,0,0,0,0,0,0].map(n => A.uint(n)).join('');
    if (data.startsWith('0x'+A.selectors.candidate)) return words(state.committed ? state.candidate : 0);
    if (data.startsWith('0x'+A.selectors.approved) || data.startsWith('0x'+A.selectors.epoch)) return words(0);
    if (data.startsWith('0x'+A.selectors.reserveDeadline)) return words(state.deadline);
    if (data.startsWith('0x'+A.selectors.reserve)) return '0x'+A.address(token)+A.uint(state.reserve)+A.uint(state.cancelled);
    if (data.startsWith('0x'+A.selectors.readiness)) return words(state.phase,state.head,state.start,state.head-8n);
    if (data.startsWith('0x'+A.selectors.funding)) {
      if (!state.available) throw Error('quote unavailable');
      return words(state.price,state.reserve,BigInt(token));
    }
    throw Error('unexpected call '+data);
  }
  w.provider = w.window.ethereum = provider;
  vm.runInNewContext(source, {
    AutoHooks:A, document:{getElementById:el}, window:w.window, setTimeout:fn => { if (w.wait) w.wait(); return setTimeout(fn,0); }, TextEncoder
  });
  return w;
}
module.exports = {wallet,A,words,requester,creator,token,currentToken,deployer,other,job,ask,txHash};
