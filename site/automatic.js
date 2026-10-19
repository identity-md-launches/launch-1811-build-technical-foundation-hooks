(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.AutoHooks = factory();
})(globalThis, function () {
  'use strict';
  const selectors = {
    open: '48061a3c', commit: '9e163130', verdict: 'cadb35dc', retry: '3290babc',
    withdraw: 'a16c86f7', cancel: 'b2ca4edc', job: 'f729cf0d', ask: '326f999f',
    approved: '1648eac4', automatic: '0ff82b3a', asset: '38d52e0f', intake: '86d1508f',
    jobAction: '1079a365', candidate: '7868e9ab', epoch: '585ae49a', revoked: 'bc31fa7d',
    readiness: '123667dd', head: '8f7dcfa3', depth: '08d87b1f',
    renew: 'b65b7d6f', reserveDeadline: '364a74f5', reserve: 'd7b8c543'
  };
  const fields = ['jobRequestId', 'sourceHash', 'sourceSubmissionHash', 'reviewSubmissionHash', 'evidenceHash',
    'buildHash', 'creationCodeHash', 'constructorArgsHash', 'runtimeCodeHash', 'chainId', 'deployer',
    'poolManager', 'poolManagerCodeHash', 'permissions'];
  const template = 'd5b9f25682e1a94a8612512a085ff280ecb29f842e25a46af01bd6c03770c8a2';
  function hex(value, bytes) {
    if (typeof value !== 'string' || !new RegExp('^0x[0-9a-fA-F]{' + bytes * 2 + '}$').test(value)) throw Error('Expected ' + bytes + '-byte hex value');
    return value.slice(2).toLowerCase();
  }
  function uint(value, bits = 256) {
    if (typeof value === 'number' && !Number.isSafeInteger(value)) throw Error('Use decimal strings for large integers');
    if (!/^(0|[1-9][0-9]*)$/.test(String(value))) throw Error('Expected unsigned decimal integer');
    const n = BigInt(value);
    if (n >= (1n << BigInt(bits))) throw Error('Integer exceeds uint' + bits);
    return n.toString(16).padStart(64, '0');
  }
  const address = value => hex(value, 20).padStart(64, '0');
  function bytes(raw) {
    const h = Array.from(raw, b => b.toString(16).padStart(2, '0')).join('');
    return uint(raw.length) + h.padEnd(Math.ceil(raw.length / 32) * 64, '0');
  }
  function specWords(spec) {
    if (spec.schemaVersion !== 1 || spec.templateId !== 'hooks-store/bounded-swap/v1' ||
        JSON.stringify(spec.permissions) !== JSON.stringify(['afterInitialize', 'beforeSwap', 'afterSwap'])) throw Error('Expected HookSpec v1 bounded-swap schema');
    if (BigInt(spec.chainId) === 0n || BigInt(spec.maxSpecifiedAmount) === 0n || BigInt('0x' + hex(spec.poolManager, 20)) === 0n) throw Error('Nonzero spec context required');
    return [uint(1), template, uint(spec.chainId), address(spec.poolManager), hex(spec.poolManagerCodeHash, 32), uint(4288, 160), uint(spec.maxSpecifiedAmount, 128)];
  }
  function openCalldata(spec, deployer, brief, maxBuildFee, reserve) {
    const encoded = new TextEncoder().encode(brief);
    if (!encoded.length || encoded.length > 2000 || /["\\<>\u0000-\u001f\u007f]/u.test(brief) ||
        Array.from(brief).some(c => c.codePointAt(0) >= 0xd800 && c.codePointAt(0) <= 0xdfff)) throw Error('Brief must be bounded UTF-8 without quotes, slashes, controls or delimiter characters');
    return '0x' + selectors.open + [...specWords(spec), address(deployer), uint(11 * 32), uint(maxBuildFee), uint(reserve)].join('') + bytes(encoded);
  }
  function artifactWords(a) {
    return fields.map((f, i) => i === 9 || i === 13 ? uint(a[f], i === 13 ? 160 : 256) : i === 10 || i === 11 ? address(a[f]) : hex(a[f], 32));
  }
  function commitCalldata(job, artifact, reviewedCommit) {
    if (hex(job, 32) !== hex(artifact.jobRequestId, 32) || BigInt('0x' + hex(reviewedCommit, 20)) === 0n) throw Error('Matching job and nonzero reviewed commit required');
    return '0x' + selectors.commit + hex(job, 32) + artifactWords(artifact).join('') + hex(reviewedCommit, 20).padEnd(64, '0');
  }
  function idCalldata(kind, id) {
    if (!['verdict', 'cancel', 'job', 'ask', 'approved', 'candidate', 'readiness', 'renew', 'reserveDeadline', 'reserve'].includes(kind)) throw Error('Unsupported ID call');
    return '0x' + selectors[kind] + hex(id, 32);
  }
  function decodeReadiness(raw, depth) {
    const words = hex(raw, 128).match(/.{64}/g).map(w => BigInt('0x' + w));
    const [ready, head, start, end] = words;
    if (ready > 1n || words.slice(1).some(w => w >= 1n << 64n)) throw Error('Malformed readiness response');
    depth = BigInt(depth);
    if (depth <= 0n || depth >= 1n << 64n) throw Error('Malformed window depth');
    const remaining = start + depth > head ? start + depth - head : 0n;
    return {ready: ready === 1n, nativeHead: head.toString(), fromBlock: start.toString(), toBlock: end.toString(),
      windowDepth: depth.toString(), blocksRemaining: remaining.toString()};
  }
  function decodeJob(raw) {
    const words = hex(raw, 480).match(/.{64}/g);
    const status = Number(BigInt('0x' + words[3])), review = Number(BigInt('0x' + words[4]));
    if (status > 4 || review > 4 || BigInt('0x' + words[0]) >= 1n << 160n) throw Error('Malformed job response');
    return {words, requester: '0x' + words[0].slice(-40), status, review};
  }
  function decodeReserve(raw, deadline) {
    const words = hex(raw, 96).match(/.{64}/g).map(w => BigInt('0x' + w));
    const end = BigInt('0x' + hex(deadline, 32));
    if (words[0] >= 1n << 160n || words[2] > 1n || end >= 1n << 64n) throw Error('Malformed reserve response');
    return {token: '0x' + words[0].toString(16).padStart(40, '0'), amount: words[1].toString(),
      cancelled: words[2] === 1n, reserveDeadline: end.toString()};
  }
  return {selectors, fields, hex, uint, address, openCalldata, commitCalldata, idCalldata, decodeReadiness, decodeJob, decodeReserve};
});
