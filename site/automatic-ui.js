'use strict';
(() => {
  const A = AutoHooks, el = id => document.getElementById(id);
  let account;
  const show = value => { el('output').textContent = typeof value === 'string' ? value : JSON.stringify(value, null, 2); };
  const value = id => el(id).value.trim();
  const rpc = (method, params) => {
    if (!window.ethereum) throw Error('A wallet provider is required');
    return window.ethereum.request({method, params});
  };
  const call = (to, data) => rpc('eth_call', [{to, data}, 'latest']);
  const requester = () => { A.hex(value('requester'), 20); return value('requester'); };
  async function connected() {
    if (!account) throw Error('Connect your wallet first');
    const accounts = await rpc('eth_accounts', []);
    if (accounts[0]?.toLowerCase() !== account.toLowerCase()) throw Error('Wallet account changed; connect again');
    if (BigInt(await call(requester(), '0x' + A.selectors.automatic)) !== 1n) throw Error('Automatic requester required');
    return account;
  }
  async function send(to, data) {
    await connected();
    const tx = {from: account, to, data, value: '0x0'};
    tx.gas = await rpc('eth_estimateGas', [tx]);
    const hash = await rpc('eth_sendTransaction', [tx]);
    show({transaction: hash, status: 'Submitted; waiting up to 120 seconds for inclusion, not finality'});
    const deadline = Date.now() + 120000;
    while (Date.now() < deadline) {
      const receipt = await rpc('eth_getTransactionReceipt', [hash]);
      if (receipt) {
        if (receipt.status !== '0x1') throw Error('Transaction reverted: ' + hash);
        show({transaction: hash, status: 'Mined; confirm chain finality before relying on it'});
        return receipt;
      }
      await new Promise(resolve => setTimeout(resolve, 1000));
    }
    throw Error('Receipt deadline reached; transaction may still be pending: ' + hash);
  }
  async function openParameters() {
    await connected();
    const spec = JSON.parse(value('spec'));
    if (BigInt(spec.chainId) !== BigInt(await rpc('eth_chainId', []))) throw Error('Wallet network differs from HookSpec');
    await call(requester(), '0x' + A.selectors.head);
    A.hex(value('deployer'), 20);
    const uses = await call(value('deployer'), '0xb61e96a5'); // requester()
    if (uses.slice(-40).toLowerCase() !== requester().slice(2).toLowerCase()) throw Error('Deployer uses another requester');
    return A.openCalldata(spec, value('deployer'), value('brief'), value('buildFee'), value('reserve'));
  }
  function bind(id, fn) { el(id).addEventListener('click', async () => { try { await fn(); } catch (err) { show(err.message); } }); }
  bind('connect', async () => {
    [account] = await rpc('eth_requestAccounts', []);
    await connected(); el('account').textContent = account;
    el('token').value = '0x' + (await call(requester(), '0x' + A.selectors.asset)).slice(-40);
    show('Automatic requester verified. Read the contract and operator configuration before paying.');
  });
  bind('approve', async () => {
    await openParameters();
    const token = '0x' + (await call(requester(), '0x' + A.selectors.asset)).slice(-40);
    const intake = '0x' + (await call(requester(), '0x' + A.selectors.intake)).slice(-40);
    const action = await call(requester(), '0x' + A.selectors.jobAction);
    const price = BigInt(await call(intake, '0x51102885' + A.hex(action, 32) + A.address(token))); // priceOf(bytes32,address)
    if (price === 0n || price > BigInt(value('buildFee'))) throw Error('Build price unavailable or above cap');
    await send(token, '0x095ea7b3' + A.address(requester()) + A.uint(price + BigInt(value('reserve'))));
  });
  bind('open', async () => {
    const receipt = await send(requester(), await openParameters());
    const opened = receipt.logs.find(l => l.address.toLowerCase() === requester().toLowerCase() && l.topics[0] === '0x95e6cf60266f65ecf4a509b236fccd720bc64ef7099f4a859a49d18cab89334c');
    if (opened) { el('job').value = opened.topics[1]; await readStatus(); }
  });
  async function readStatus() {
    const job = value('job'); A.hex(job, 32);
    const raw = await call(requester(), A.idCalldata('job', job));
    const {words, status, review} = A.decodeJob(raw);
    const ask = await call(requester(), A.idCalldata('ask', job)); el('ask').value = ask;
    const approved = await call(requester(), A.idCalldata('approved', job));
    const epoch = await call(requester(), '0x' + A.selectors.epoch + words[13]);
    const incident = BigInt(epoch) === 0n ? null : await call(requester(), '0x' + A.selectors.revoked + A.uint(BigInt(epoch)));
    const readiness = await readReadiness(ask);
    const reserve = await readReserve(job);
    show({job, ask, jobStatus: ['None','Open','Delivered','Failed','Expired'][status],
      verdict: ['None','Pending','Passed','NotPassed','Unanswered'][review],
      exactAuthorizedArtifact: approved, signerEpoch: BigInt(epoch).toString(), revokedEpochIncident: incident,
      verdictReadiness: readiness, reserve,
      note: 'A Passed label alone cannot deploy: exact artifact, signer revocation, freshness, manager, bytecode and replay checks still apply.'});
  }
  async function readReserve(job) {
    const raw = await call(requester(), A.idCalldata('reserve', job));
    const deadline = await call(requester(), A.idCalldata('reserveDeadline', job));
    return A.decodeReserve(raw, deadline);
  }
  async function readReadiness(ask) {
    const raw = await call(requester(), A.idCalldata('readiness', ask));
    const depth = await call(requester(), '0x' + A.selectors.depth);
    const phase = A.decodeReadiness(raw, depth);
    let funding;
    try { funding = A.decodeFunding(await call(requester(), A.idCalldata('funding', ask))); }
    catch (err) { funding = {available: false, funded: false, error: err.message}; }
    return A.fundedReadiness(phase, funding);
  }
  bind('status', readStatus);
  bind('commitArtifact', async () => {
    const job = value('job');
    const state = A.decodeJob(await call(requester(), A.idCalldata('job', job)));
    if (state.status !== 2) throw Error('Wait for Delivered before committing an artifact.');
    if ((await readReserve(job)).cancelled) throw Error('Cancelled reserve cannot be revived.');
    const sender = await connected();
    if (state.requester !== sender.toLowerCase()) throw Error('Only the job requester can commit an artifact.');
    await send(requester(), A.commitCalldata(job, JSON.parse(value('artifact')), value('commit')));
    await readStatus();
  });
  bind('verdict', async () => {
    const readiness = await readReadiness(value('ask'));
    if (!readiness.ready) throw Error('Verdict not ready: ' + readiness.blocksRemaining +
      ' native blocks remaining. Delivery, candidate, active reserve, deadline and a positive quote within reserve are required. Refresh status; top up if needed.');
    await send(requester(), A.idCalldata('verdict', value('ask'))); await readStatus();
  });
  bind('cancel', async () => { await send(requester(), A.idCalldata('cancel', value('job'))); await readStatus(); });
  bind('renew', async () => { await send(requester(), A.idCalldata('renew', value('job'))); await readStatus(); });
  async function topUpParameters() {
    const sender = await connected(), job = value('job'), amount = value('topUpAmount');
    const data = A.topUpCalldata(job, amount);
    const state = A.decodeJob(await call(requester(), A.idCalldata('job', job)));
    if (state.requester !== sender.toLowerCase()) throw Error('Only the job requester can top up.');
    if (state.status !== 2 || state.review !== 0) throw Error('Top-up requires Delivered with no pending or finalized verdict.');
    const reserve = await readReserve(job);
    if (reserve.cancelled) throw Error('Cancelled reserve cannot be revived.');
    if (BigInt(await call(requester(), A.idCalldata('candidate', job))) === 0n) throw Error('Commit an artifact before topping up.');
    const ask = await call(requester(), A.idCalldata('ask', job));
    const ctx = A.hex(await call(requester(), A.idCalldata('askContext', ask)), 288);
    if (BigInt('0x' + ctx.slice(64, 128)) !== 0n) throw Error('Top-up requires an unspent ask.');
    const cap = BigInt(await call(requester(), '0x' + A.selectors.maxPrice));
    if (BigInt(reserve.amount) + BigInt(amount) > cap) throw Error('Total reserve exceeds current maxPrice.');
    await call(requester(), '0x' + A.selectors.head);
    return {job, ask, amount, token: reserve.token, data};
  }
  bind('approveTopUp', async () => {
    const p = await topUpParameters();
    await send(p.token, '0x095ea7b3' + A.address(requester()) + A.uint(p.amount));
    const allowance = BigInt(await call(p.token, '0xdd62ed3e' + A.address(account) + A.address(requester())));
    if (allowance !== BigInt(p.amount)) throw Error('Top-up approval readback differs from the bounded amount. Refresh before continuing.');
    show({job: p.job, token: p.token, approvedTopUp: p.amount, allowanceReadback: allowance.toString(),
      next: 'Approval confirmed. Submit the separate top-up transaction, then wait eight native blocks.'});
  });
  bind('topUp', async () => {
    const p = await topUpParameters();
    await send(requester(), p.data);
    await readStatus();
  });
  bind('withdraw', async () => { await send(requester(), '0x' + A.selectors.withdraw + A.address(value('token'))); });
})();
