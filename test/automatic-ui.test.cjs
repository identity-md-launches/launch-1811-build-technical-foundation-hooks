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
    intake:'intake()',jobAction:'jobAction()',candidate:'candidateDigest(bytes32)',epoch:'reviewReceiptSignerEpoch(bytes32)',revoked:'revokedSignerEpochs(uint32)'};
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
