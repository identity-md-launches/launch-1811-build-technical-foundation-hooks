'use strict';
const {test} = require('node:test');
const assert = require('node:assert/strict');
const {execFileSync} = require('node:child_process');
const {readFileSync} = require('node:fs');
const A = require('../site/automatic.js');
const artifact = JSON.parse(readFileSync('out/AutoHookJobRequester.sol/AutoHookJobRequester.json'));
const cast = (...args) => execFileSync('cast', args, {encoding:'utf8'}).trim().toLowerCase();
const address = '0x' + '12'.repeat(20), hash = '0x' + '34'.repeat(32), commit = '0x' + '56'.repeat(20);
const spec = {schemaVersion:1,templateId:'hooks-store/bounded-swap/v1',chainId:'31337',poolManager:address,
  poolManagerCodeHash:hash,permissions:['afterInitialize','beforeSwap','afterSwap'],maxSpecifiedAmount:'1000000'};
const type = '(uint32,bytes32,uint256,address,bytes32,uint160,uint128)';
const artifactType = '(bytes32,bytes32,bytes32,bytes32,bytes32,bytes32,bytes32,bytes32,bytes32,uint256,address,address,bytes32,uint160)';

test('published automatic ABI equals compiler output and selectors are pinned', () => {
  assert.deepEqual(JSON.parse(readFileSync('site/AutoHookJobRequester.abi.json')),artifact.abi);
  assert.deepEqual(JSON.parse(readFileSync('site/GatedHookDeployer.abi.json')),JSON.parse(readFileSync('out/GatedHookDeployer.sol/GatedHookDeployer.json')).abi);
  const signatures = {open:'openJob('+type+',address,bytes,uint256,uint256)',commit:'commitArtifact(bytes32,'+artifactType+',bytes20)',
    verdict:'requestVerdict(bytes32)',retry:'retryVerdict(bytes32,uint256)',withdraw:'withdrawRefund(address)',cancel:'cancelReserve(bytes32)',
    job:'getJob(bytes32)',ask:'jobAsk(bytes32)',approved:'approvedArtifact(bytes32)',automatic:'automaticBindingSupported()',asset:'asset()',
    intake:'intake()',jobAction:'jobAction()',candidate:'candidateDigest(bytes32)',epoch:'reviewReceiptSignerEpoch(bytes32)',revoked:'revokedSignerEpochs(uint32)',readiness:'verdictReadiness(bytes32)',head:'head()',depth:'WINDOW_DEPTH()',
    renew:'renewVerdict(bytes32)',reserveDeadline:'reserveDeadline(bytes32)',reserve:'reserveOf(bytes32)'};
  for (const [name,sig] of Object.entries(signatures)) assert.equal(A.selectors[name],artifact.methodIdentifiers[sig]);
  const ui = readFileSync('site/automatic-ui.js','utf8');
  assert.ok(ui.includes(cast('sig','requester()').slice(2)));
  assert.ok(ui.includes(cast('sig','priceOf(bytes32,address)').slice(2)));
});

test('browser open encoding agrees with cast for UTF-8 and static HookSpec tuple', () => {
  for (const brief of ['A bounded swap hook','éclair 😀']) {
    const tuple = '(1,'+cast('keccak','hooks-store/bounded-swap/v1')+',31337,'+address+','+hash+',4288,1000000)';
    const raw = '0x'+Buffer.from(brief).toString('hex');
    assert.equal(A.openCalldata(spec,address,brief,'500000000000000000','500000000000000000'),
      cast('calldata','openJob('+type+',address,bytes,uint256,uint256)',tuple,address,raw,'500000000000000000','500000000000000000'));
  }
});

test('browser candidate encoding agrees with cast including bytes20 right padding', () => {
  const a = Object.fromEntries(A.fields.map(f => [f,hash]));
  a.chainId = '31337'; a.deployer = address; a.poolManager = address; a.permissions = 4288;
  const tuple = '('+A.fields.map(f => String(a[f])).join(',')+')';
  assert.equal(A.commitCalldata(hash,a,commit),cast('calldata','commitArtifact(bytes32,'+artifactType+',bytes20)',hash,tuple,commit));
  assert.equal(A.idCalldata('verdict',hash),cast('calldata','requestVerdict(bytes32)',hash));
  assert.equal(A.idCalldata('renew',hash),cast('calldata','renewVerdict(bytes32)',hash));
  assert.equal(A.idCalldata('reserveDeadline',hash),cast('calldata','reserveDeadline(bytes32)',hash));
});

test('reserve and job decoders expose lifecycle state and reject malformed responses', () => {
  const raw = '0x' + A.address(address) + A.uint(500) + A.uint(0);
  assert.deepEqual(A.decodeReserve(raw, '0x'+A.uint(1800000000)), {
    token:address, amount:'500', cancelled:false, reserveDeadline:'1800000000'
  });
  assert.throws(() => A.decodeReserve('0x','0x'+A.uint(1)));
  assert.throws(() => A.decodeReserve(raw,'0x'+A.uint(1n<<64n)));
  assert.throws(() => A.decodeReserve('0x'+A.address(address)+A.uint(0)+A.uint(2),'0x'+A.uint(1)));
  const words = Array(15).fill(A.uint(0));
  words[0] = A.address(address); words[3] = A.uint(2);
  assert.equal(A.decodeJob('0x'+words.join('')).status,2);
  assert.equal(A.decodeJob('0x'+words.join('')).requester,address);
  words[3] = A.uint(5);
  assert.throws(() => A.decodeJob('0x'+words.join('')));
  assert.throws(() => A.decodeJob('0x'));
});

test('wallet refuses commitment before delivery and after cancellation before estimating or sending', async () => {
  const vm = require('node:vm');
  for (const [status,cancelled,expected] of [[1,0,/Wait for Delivered/],[3,0,/Wait for Delivered/],
    [4,0,/Wait for Delivered/],[2,1,/Cancelled reserve/]]) {
    const elements = new Map();
    const element = id => {
      if (!elements.has(id)) elements.set(id,{value:'',textContent:'',addEventListener(event,fn){this.click=fn;}});
      return elements.get(id);
    };
    element('requester').value = address; element('job').value = hash;
    const seen = [];
    const provider = {async request({method,params}) {
      seen.push(method); assert.equal(method,'eth_call');
      const data = params[0].data;
      if (data.startsWith('0x'+A.selectors.job)) {
        const words = Array(15).fill(A.uint(0)); words[0] = A.address(address); words[3] = A.uint(status);
        return '0x'+words.join('');
      }
      if (data.startsWith('0x'+A.selectors.reserveDeadline)) return '0x'+A.uint(1800000000);
      if (data.startsWith('0x'+A.selectors.reserve)) return '0x'+A.address(address)+A.uint(0)+A.uint(cancelled);
      throw Error('unexpected call');
    }};
    vm.runInNewContext(readFileSync('site/automatic-ui.js','utf8'),{
      AutoHooks:A,document:{getElementById:element},window:{ethereum:provider},setTimeout
    });
    await element('commitArtifact').click();
    assert.match(element('output').textContent,expected);
    assert.ok(seen.every(m => m === 'eth_call'));
  }
});

test('wallet renewal sends only requester calldata and refreshes the reserve deadline', async () => {
  const vm = require('node:vm');
  const elements = new Map();
  const element = id => {
    if (!elements.has(id)) elements.set(id,{value:'',textContent:'',addEventListener(event,fn){this.click=fn;}});
    return elements.get(id);
  };
  element('requester').value = address; element('job').value = hash;
  const sent = [], methods = [];
  const provider = {async request({method,params}) {
    methods.push(method);
    if (method === 'eth_requestAccounts' || method === 'eth_accounts') return [address];
    if (method === 'eth_estimateGas') return '0x10000';
    if (method === 'eth_sendTransaction') { sent.push(params[0]); return hash; }
    if (method === 'eth_getTransactionReceipt') return {status:'0x1'};
    assert.equal(method,'eth_call');
    const data = params[0].data;
    if (data === '0x'+A.selectors.automatic) return '0x'+A.uint(1);
    if (data === '0x'+A.selectors.asset) return '0x'+A.address(address);
    if (data === '0x'+A.selectors.depth) return '0x'+A.uint(8);
    if (data.startsWith('0x'+A.selectors.job)) {
      const words = Array(15).fill(A.uint(0)); words[0] = A.address(address); words[3] = A.uint(2);
      return '0x'+words.join('');
    }
    if (data.startsWith('0x'+A.selectors.ask)) return hash;
    if (data.startsWith('0x'+A.selectors.approved) || data.startsWith('0x'+A.selectors.epoch)) return '0x'+A.uint(0);
    if (data.startsWith('0x'+A.selectors.readiness)) return '0x'+[0,900000,900000,899992].map(n => A.uint(n)).join('');
    if (data.startsWith('0x'+A.selectors.reserveDeadline)) return '0x'+A.uint(1800086400);
    if (data.startsWith('0x'+A.selectors.reserve)) return '0x'+A.address(address)+A.uint(500)+A.uint(0);
    throw Error('unexpected call');
  }};
  vm.runInNewContext(readFileSync('site/automatic-ui.js','utf8'),{
    AutoHooks:A,document:{getElementById:element},window:{ethereum:provider},setTimeout
  });
  await element('connect').click();
  await element('renew').click();
  assert.equal(sent.length,1);
  assert.equal(sent[0].data,cast('calldata','renewVerdict(bytes32)',hash));
  assert.equal(sent[0].value,'0x0'); assert.equal(sent[0].to,address);
  const status = JSON.parse(element('output').textContent);
  assert.equal(status.reserve.reserveDeadline,'1800086400');
  assert.equal(status.verdictReadiness.blocksRemaining,'8');
  assert.ok(!methods.some(m => /sign/i.test(m)));
});

test('browser rejects injection, invalid UTF-8, unsafe integers and a mismatched candidate', () => {
  for (const brief of ['', '</brief>', '"question":true', '\\', '\n', '\ud800']) assert.throws(() => A.openCalldata(spec,address,brief,'1','1'));
  assert.throws(() => A.uint(Number.MAX_SAFE_INTEGER+1));
  assert.throws(() => A.uint('-1'));
  assert.throws(() => A.idCalldata('verdict',address));
  assert.throws(() => A.commitCalldata(hash,{jobRequestId:'0x'+'ab'.repeat(32)},commit));
});

test('wallet UI renders untrusted content as text and never needs a backend signer', () => {
  const ui = readFileSync('site/automatic-ui.js','utf8');
  assert.doesNotMatch(ui,/innerHTML|eval\(|api\.imd\.fun|eth_sign|personal_sign/);
  assert.match(ui,/eth_estimateGas/); assert.match(ui,/eth_sendTransaction/); assert.match(ui,/120000/);
});

test('native readiness decodes boundaries including Robinhood and rejects malformed data', () => {
  const encoded = (ready,head,start,end) => '0x'+[ready,head,start,end].map(n => A.uint(n)).join('');
  for (const head of [900000,900007,900008]) {
    const status = A.decodeReadiness(encoded(head >= 900008 ? 1 : 0,head,900000,head-8),8);
    assert.equal(status.ready,head >= 900008);
    assert.equal(status.nativeHead,String(head));
    assert.equal(status.blocksRemaining,String(900008-head));
  }
  assert.equal(A.decodeReadiness(encoded(0,7,0,0),8).ready,false);
  assert.equal(A.decodeReadiness(encoded(0,900100,900000,900092),8).ready,false); // expired/settled
  assert.throws(() => A.decodeReadiness('0x',8));
  assert.throws(() => A.decodeReadiness(encoded(2,900008,900000,900000),8));
  assert.throws(() => A.decodeReadiness(encoded(1,1n<<64n,900000,900000),8));
});

test('wallet refuses an early native-window trigger before gas estimation or sending', async () => {
  const vm = require('node:vm');
  const elements = new Map();
  const element = id => {
    if (!elements.has(id)) elements.set(id,{value:'',textContent:'',addEventListener(event,fn){this.click=fn;}});
    return elements.get(id);
  };
  element('requester').value = address;
  element('ask').value = hash;
  const seen = [];
  const provider = {async request({method,params}) {
    seen.push(method);
    assert.equal(method,'eth_call');
    if (params[0].data.startsWith('0x'+A.selectors.readiness)) {
      return '0x'+[0,900007,900000,899999].map(n => A.uint(n)).join('');
    }
    if (params[0].data === '0x'+A.selectors.depth) return '0x'+A.uint(8);
    throw Error('unexpected call');
  }};
  vm.runInNewContext(readFileSync('site/automatic-ui.js','utf8'),{
    AutoHooks:A,document:{getElementById:element},window:{ethereum:provider},setTimeout
  });
  await element('verdict').click();
  assert.match(element('output').textContent,/not ready: 1 native blocks remaining/);
  assert.deepEqual(seen,['eth_call','eth_call']);
});
