"""Actual automatic requester transactions on disposable Anvil; no public RPC or key handling."""
import json
import unittest
from sdk.automatic import AutomaticClient
from sdk.hooks_store import Rpc, ROOT, build_spec, abi_tuple, TYPE, keccak_hex, _cast, StoreError
from test.helpers.local_rpc import LocalChain

FEE = 5 * 10**17


class AutomaticSdkTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.local = LocalChain().__enter__()
        cls.addClassCleanup(cls.local.__exit__, None, None, None)
        cls.owner, cls.creator, cls.outsider = cls.local.accounts[:3]
        cls.codec = cls.local.deploy('HookRequestCodec')
        cls.intake = cls.local.deploy('MockIntake')
        cls.imd = cls.local.deploy('TestToken', 'f(string,uint8)', 'Local IMD', '18')
        cls.requester = cls.local.deploy('AutoHookJobRequester', 'f(address,address,address,address,uint256,address)',
                                       cls.owner, cls.intake, cls.imd, cls.owner, str(FEE), cls.codec)
        cls.gate = cls.local.deploy('GatedHookDeployer', 'f(address,address)', cls.owner, cls.requester)
        cls.manager = cls.local.deploy('PoolManager', 'f(address)', cls.owner)
        cls.rpc = Rpc(cls.local.url)
        cls.client = AutomaticClient(cls.rpc, cls.requester)
        for action in ['jobAction()(bytes32)', 'reviewAction()(bytes32)']:
            value = cls.rpc.call(cls.requester, action)
            cls.local.call_transaction(cls.intake, 'setPrice(bytes32,address,uint256)', value, cls.imd, str(FEE))
        cls.local.call_transaction(cls.imd, 'mint(address,uint256)', cls.creator, str(10**20))
        cls.spec = build_spec(chain_id='31337',pool_manager=cls.manager,
                              pool_manager_code_hash=keccak_hex(cls.rpc.code(cls.manager)),max_specified_amount='1000000')

    def setUp(self):
        self.snapshot = self.local.request('evm_snapshot', [])
        self.rpc = Rpc(self.local.url)
        self.client = AutomaticClient(self.rpc, self.requester)
    def tearDown(self): self.assertTrue(self.local.request('evm_revert', [self.snapshot]))

    def _open(self, fee=FEE):
        out = self.client.open_job(sender=self.creator,spec=self.spec,deployer=self.gate,brief='Bounded hook',
                                   max_build_fee=fee,verdict_reserve=fee)
        self.assertTrue(out['unsigned'])
        self.assertEqual(out['prepayment'], fee * 2)
        approval_receipt = self.local.send(out['approvalTransaction']); receipt = self.local.send(out['transaction'])
        self.gas = {'approval':int(approval_receipt['gasUsed'],16),'openJob':int(receipt['gasUsed'],16)}
        topic = keccak_hex('JobOpened(bytes32,address,bytes32,uint256,bytes)')
        job = next(log['topics'][1] for log in receipt['logs'] if log['topics'][0] == topic)
        self.rpc = Rpc(self.local.url)
        ask = self.rpc.call(self.requester,'jobAsk(bytes32)(bytes32)',job)
        return job, ask

    def _candidate_asked(self, ask_verdict=True, fee=FEE):
        job, ask = self._open(fee)
        built = json.loads((ROOT/'out/BoundedSwapHook.sol/BoundedSwapHook.json').read_text())
        args = _cast('abi-encode','f('+TYPE+')',abi_tuple(self.spec))
        a = dict(jobRequestId=job,sourceHash=keccak_hex('local source'),sourceSubmissionHash=keccak_hex('local source submission'),
                 reviewSubmissionHash=keccak_hex('local independent review'),evidenceHash='0x'+'00'*32,buildHash=keccak_hex('local build'),
                 creationCodeHash=keccak_hex(built['bytecode']['object']),constructorArgsHash=keccak_hex(args),
                 runtimeCodeHash=keccak_hex(built['deployedBytecode']['object']),chainId=31337,deployer=self.gate,
                 poolManager=self.manager,poolManagerCodeHash=self.spec['poolManagerCodeHash'],permissions=4288)
        from sdk.gated_deploy import ARTIFACT, artifact_tuple
        import hashlib
        from sdk.result_snapshot import evidence_document
        core = self.rpc.call(self.gate,'artifactDigest('+ARTIFACT+')(bytes32)',artifact_tuple(a))
        a['evidenceHash']='0x'+hashlib.sha256(evidence_document(core,a['sourceSubmissionHash'],a['reviewSubmissionHash'])).hexdigest()
        self.client = AutomaticClient(Rpc(self.local.url), self.requester)
        with self.assertRaisesRegex(StoreError, 'Delivered'):
            self.client.commit_artifact(sender=self.creator,job=job,artifact=a,reviewed_commit='0x'+keccak_hex('local commit')[2:42])
        result = _cast('abi-encode','f(bytes32,bytes32,string)',job,keccak_hex('local exact completion'),'ipfs://local')
        self.local.call_transaction(self.intake,'complete(bytes32,bytes)',job,result)
        self.client = AutomaticClient(Rpc(self.local.url), self.requester)
        with self.assertRaisesRegex(StoreError, 'only the job requester'):
            self.client.commit_artifact(sender=self.outsider,job=job,artifact=a,reviewed_commit='0x'+keccak_hex('local commit')[2:42])
        tx = self.client.commit_artifact(sender=self.creator,job=job,artifact=a,reviewed_commit='0x'+keccak_hex('local commit')[2:42])
        receipt = self.local.send(tx)
        self.gas['commitArtifact']=int(receipt['gasUsed'],16)
        if not ask_verdict:
            return job, ask
        self.local.request('anvil_mine', ['0x8'])
        self.client = AutomaticClient(Rpc(self.local.url), self.requester)
        self.assertTrue(self.client.verdict_readiness(ask)['ready'])
        receipt = self.local.send(self.client.request_verdict(sender=self.outsider,ask=ask))
        self.gas['requestVerdict']=int(receipt['gasUsed'],16)
        print('LOCAL_MOCK_TRANSACTION_GAS '+json.dumps(self.gas,sort_keys=True))
        self.rpc = Rpc(self.local.url)
        self.assertEqual(int(self.rpc.call(self.imd,'balanceOf(address)(uint256)',self.intake),16), fee*2)
        self.rpc = Rpc(self.local.url)
        candidate = self.rpc.call(self.requester,'candidateDigest(bytes32)(bytes32)',job)
        self.assertEqual(candidate,self.rpc.call(self.gate,'artifactDigest('+ARTIFACT+')(bytes32)',artifact_tuple(a)))
        from sdk.gated_deploy import read_candidate
        stored, reviewed = read_candidate(self.rpc,self.requester,job)
        self.assertEqual(stored,a)
        self.assertEqual(reviewed,'0x'+keccak_hex('local commit')[2:42])

    def test_unready_trigger_reverts_and_cannot_spend(self):
        job, ask = self._open()
        with self.assertRaisesRegex(StoreError, 'not ready'):
            self.local.send(self.client.request_verdict(sender=self.outsider,ask=ask))
        self.assertEqual(int(self.rpc.call(self.imd,'balanceOf(address)(uint256)',self.intake),16), FEE)

    def test_sdk_reads_native_readiness_and_stops_early_transactions(self):
        job, ask = self._candidate_asked(ask_verdict=False)
        client = AutomaticClient(Rpc(self.local.url), self.requester)
        status = client.verdict_readiness(ask)
        self.assertFalse(status['ready'])
        self.assertEqual(status['blocksRemaining'], 8)
        with self.assertRaisesRegex(StoreError, 'not ready'):
            client.request_verdict(sender=self.outsider, ask=ask)
        self.local.request('anvil_mine', ['0x7'])
        client = AutomaticClient(Rpc(self.local.url), self.requester)
        self.assertEqual(client.verdict_readiness(ask)['blocksRemaining'], 1)
        self.assertFalse(client.verdict_readiness(ask)['ready'])
        with self.assertRaisesRegex(StoreError, 'not ready'):
            client.request_verdict(sender=self.outsider, ask=ask)
        self.assertEqual(int(client.rpc.call(self.imd, 'balanceOf(address)(uint256)', self.intake), 16), FEE)
        self.local.request('anvil_mine', ['0x1'])
        client = AutomaticClient(Rpc(self.local.url), self.requester)
        status = client.verdict_readiness(ask)
        self.assertTrue(status['ready'])
        self.assertEqual(status['fromBlock'], status['toBlock'])
        self.assertEqual(status['blocksRemaining'], 0)
        self.local.send(client.request_verdict(sender=self.outsider, ask=ask))
        fresh = AutomaticClient(Rpc(self.local.url), self.requester)
        self.assertFalse(fresh.verdict_readiness(ask)['ready'])

    def test_approval_open_commit_permissionless_verdict_encoding(self):
        self._candidate_asked()

    def test_unsigned_renewal_keeps_reserve_and_ask_and_resets_maturity(self):
        job, ask = self._candidate_asked(ask_verdict=False)
        client = AutomaticClient(Rpc(self.local.url), self.requester)
        reserve = client.reserve_status(job)
        self.assertEqual(reserve['amount'], FEE)
        self.assertFalse(reserve['cancelled'])
        self.assertEqual(reserve['token'], self.imd)
        with self.assertRaises(StoreError):
            client.renew_verdict(sender=self.creator, job=job)
        self.local.request('evm_setNextBlockTimestamp', [reserve['reserveDeadline'] + 1])
        self.local.request('anvil_mine', ['0x1'])
        client = AutomaticClient(Rpc(self.local.url), self.requester)
        with self.assertRaises(StoreError):
            client.renew_verdict(sender=self.outsider, job=job)
        tx = client.renew_verdict(sender=self.creator, job=job)
        self.assertEqual(tx['data'], _cast('calldata', 'renewVerdict(bytes32)', job))
        self.assertEqual(tx['value'], '0x0')
        # Preparing the transaction only simulates it; the old deadline and funds are unchanged.
        self.assertEqual(AutomaticClient(Rpc(self.local.url), self.requester).reserve_status(job), reserve)
        self.local.send(tx)
        client = AutomaticClient(Rpc(self.local.url), self.requester)
        self.assertGreater(client.reserve_status(job)['reserveDeadline'], reserve['reserveDeadline'])
        self.assertEqual(client.reserve_status(job)['amount'], FEE)
        self.assertEqual(client.rpc.call(self.requester, 'jobAsk(bytes32)(bytes32)', job), ask)
        self.assertEqual(client.verdict_readiness(ask)['blocksRemaining'], 8)
        self.assertEqual(int(client.rpc.call(self.imd, 'balanceOf(address)(uint256)', self.intake), 16), FEE)
        self.local.request('anvil_mine', ['0x8'])
        client = AutomaticClient(Rpc(self.local.url), self.requester)
        self.assertTrue(client.verdict_readiness(ask)['ready'])
        self.local.send(client.request_verdict(sender=self.outsider, ask=ask))
        with self.assertRaises(StoreError):
            AutomaticClient(Rpc(self.local.url), self.requester).renew_verdict(sender=self.creator, job=job)

    def test_cancelled_reserve_renewal_is_refused_without_payment(self):
        job, ask = self._candidate_asked(ask_verdict=False)
        deadline = self.client.reserve_status(job)['reserveDeadline']
        self.local.request('evm_setNextBlockTimestamp', [deadline + 1])
        self.local.request('anvil_mine', ['0x1'])
        self.local.call_transaction(self.requester, 'cancelReserve(bytes32)', job, sender=self.creator)
        client = AutomaticClient(Rpc(self.local.url), self.requester)
        self.assertTrue(client.reserve_status(job)['cancelled'])
        with self.assertRaises(StoreError):
            client.renew_verdict(sender=self.creator, job=job)

    def test_real_local_v2_answer_then_automatic_candidate_deployment(self):
        # The preceding transaction/encoding test commits and asks using the real consumer.
        self._candidate_asked()
        from sdk.gated_deploy import prepare_automatic, read_candidate
        rpc = Rpc(self.local.url)
        jobs = rpc.call(self.requester,'jobsOf(address)(bytes32[])',self.creator)
        job = '0x'+jobs[130:194]
        ask = rpc.call(self.requester,'jobAsk(bytes32)(bytes32)',job)
        ctx = rpc.call(self.requester,'getAsk(bytes32)',ask)
        word = lambda i: '0x'+ctx[2+i*64:2+(i+1)*64]
        verdict, start, end = word(1), int(word(5),16), int(word(6),16)
        head = self.local.request('eth_getBlockByNumber',['latest',False])
        block = self.local.request('eth_getBlockByNumber',[hex(end),False])
        issued = int(head['timestamp'],16)
        names = ['requestId','chainId','questionHash','answerType','answer','figure','fromBlock','toBlock','blockHash',
                 'panelJobId','panelSize','quorum','agreed','issuedAt','expiresAt']
        types = ['bytes32','uint256','bytes32','uint8','bytes','uint256','uint64','uint64','bytes32','bytes32',
                 'uint16','uint16','uint16','uint64','uint64']
        values = [ask[:34]+'00'*16,31337,rpc.call(self.requester,'expectedQuestionHash(bytes32,uint64,uint64)(bytes32)',ask,str(start),str(end)),
                  0,'0x'+'00'*31+'01',0,start,end,block['hash'],keccak_hex('local SDK panel')[:34]+'00'*16,
                  7,5,5,issued,issued+3600]
        typed = {'domain':{'name':'IdentityMD Oracle','version':'2','chainId':31337,'verifyingContract':self.requester},
                 'types':{'EIP712Domain':[{'name':n,'type':t} for n,t in [('name','string'),('version','string'),('chainId','uint256'),('verifyingContract','address')]],
                          'OracleAttestation':[{'name':n,'type':t} for n,t in zip(names,types)]},
                 'primaryType':'OracleAttestation','message':dict(zip(names,values))}
        # Disposable Anvil account signs locally. No key/config is read and no public RPC is used.
        signature = self.local.request('eth_signTypedData_v4',[self.owner,json.dumps(typed)])
        att = '('+','.join(str(v) for v in values)+')'
        encoded = _cast('abi-encode','f(bytes32,('+','.join(types)+'),bytes)',verdict,att,signature)
        self.local.call_transaction(self.intake,'complete(bytes32,bytes)',verdict,encoded)
        self.local.call_transaction(self.gate,'setManager(address,bytes32,bool)',self.manager,self.spec['poolManagerCodeHash'],'true')
        rpc = Rpc(self.local.url)
        a, reviewed = read_candidate(rpc,self.requester,job)
        built = json.loads((ROOT/'out/BoundedSwapHook.sol/BoundedSwapHook.json').read_text())
        args = _cast('abi-encode','f('+TYPE+')',abi_tuple(self.spec))
        out = prepare_automatic(rpc,deployer=self.gate,job=job,creation_code=built['bytecode']['object'],constructor_args=args)
        self.assertEqual(out['artifact'],a)
        self.assertEqual(out['reviewedCommit'],reviewed)
        self.assertTrue(out['automaticBindingSupported'])
        receipt = self.local.send(out['transaction'])
        self.assertNotEqual(Rpc(self.local.url).code(out['hook']),'0x')
        print('LOCAL_AUTOMATIC_DEPLOY_GAS '+str(int(receipt['gasUsed'],16)))

    def test_readonly_preflight_verifies_real_built_contracts(self):
        from script.preflight_automatic import preflight
        self.local.call_transaction(self.gate,'setManager(address,bytes32,bool)',self.manager,self.spec['poolManagerCodeHash'],'true')
        out=preflight(Rpc(self.local.url),self.requester,self.gate,self.spec)
        self.assertTrue(out['readOnly'])
        self.assertTrue(all(check['ok'] for check in out['checks']))
        self.assertEqual(out['windowPolicy']['minimumWindowAgeBlocks'], 173108)

    def test_unsigned_top_up_uses_original_asset_and_preserves_job_after_rotation(self):
        rpc = Rpc(self.local.url)
        self.local.call_transaction(self.requester, 'setProtocol(address,address,uint256,bytes32,bytes32)',
                                    self.intake, self.imd, str(2*FEE),
                                    rpc.call(self.requester, 'jobAction()(bytes32)'),
                                    rpc.call(self.requester, 'reviewAction()(bytes32)'))
        job, ask = self._candidate_asked(ask_verdict=False)
        old = Rpc(self.local.url)
        candidate = old.call(self.requester, 'candidateDigest(bytes32)(bytes32)', job)
        old_action = old.call(self.requester, 'reviewAction()(bytes32)')
        new_intake = self.local.deploy('MockIntake')
        new_token = self.local.deploy('TestToken', 'f(string,uint8)', 'Replacement local token', '6')
        self.local.call_transaction(self.requester, 'setProtocol(address,address,uint256,bytes32,bytes32)',
                                    new_intake, new_token, str(2*10**6), keccak_hex('new build'), keccak_hex('new verdict'))
        self.local.call_transaction(self.intake, 'setPrice(bytes32,address,uint256)', old_action, self.imd, str(3*FEE//2))
        self.local.request('anvil_mine', ['0x8'])
        client = AutomaticClient(Rpc(self.local.url), self.requester)
        self.assertTrue(client.verdict_readiness(ask)['phaseReady'])
        self.assertFalse(client.verdict_readiness(ask)['ready'])
        out = client.top_up_reserve(sender=self.creator, job=job, amount=FEE)
        self.assertTrue(out['unsigned'])
        self.assertEqual(out['approvalTransaction']['to'].lower(), self.imd.lower())
        self.assertEqual(out['approvalTransaction']['data'], _cast('calldata','approve(address,uint256)',self.requester,str(FEE)))
        self.assertEqual(out['transaction']['data'], _cast('calldata','topUpReserve(bytes32,uint256)',job,str(FEE)))
        # Preparing both transactions signs/sends nothing. Approval and top-up remain separate.
        self.assertEqual(client.reserve_status(job)['amount'],FEE)
        self.local.send(out['approvalTransaction'])
        self.local.send(out['transaction'])
        client = AutomaticClient(Rpc(self.local.url), self.requester)
        self.assertEqual(client.reserve_status(job)['amount'],2*FEE)
        self.assertEqual(client.verdict_readiness(ask)['funding']['price'],3*FEE//2)
        self.assertFalse(client.verdict_readiness(ask)['ready'])
        self.local.request('anvil_mine', ['0x8'])
        client = AutomaticClient(Rpc(self.local.url), self.requester)
        self.local.send(client.request_verdict(sender=self.outsider,ask=ask))
        rpc = Rpc(self.local.url)
        self.assertEqual(rpc.call(self.requester,'jobAsk(bytes32)(bytes32)',job),ask)
        self.assertEqual(rpc.call(self.requester,'candidateDigest(bytes32)(bytes32)',job),candidate)
        self.assertEqual(int(rpc.call(self.imd,'balanceOf(address)(uint256)',self.intake),16),5*FEE//2)
        self.assertEqual(int(rpc.call(self.imd,'balanceOf(address)(uint256)',new_intake),16),0)
        self.assertEqual(int(rpc.call(self.requester,'refunds(address,address)(uint256)',self.imd,self.creator),16),FEE//2)

    def test_real_six_to_eighteen_rotation_keeps_the_six_decimal_cap(self):
        rpc = Rpc(self.local.url)
        actions = [rpc.call(self.requester, name + '()(bytes32)') for name in ['jobAction','reviewAction']]
        original = self.local.deploy('TestToken', 'f(string,uint8)', 'Original local six decimals', '6')
        self.local.call_transaction(self.requester, 'setProtocol(address,address,uint256,bytes32,bytes32)',
                                    self.intake, original, '1000000', *actions)
        for action in actions:
            self.local.call_transaction(self.intake, 'setPrice(bytes32,address,uint256)', action, original, '500000')
        self.local.call_transaction(original, 'mint(address,uint256)', self.creator, '10000000')
        self.client = AutomaticClient(Rpc(self.local.url), self.requester)
        job, ask = self._candidate_asked(ask_verdict=False, fee=500000)
        self.local.call_transaction(self.requester, 'setProtocol(address,address,uint256,bytes32,bytes32)',
                                    self.intake, self.imd, str(2*10**18), *actions)
        client = AutomaticClient(Rpc(self.local.url), self.requester)
        with self.assertRaisesRegex(StoreError, 'maxPriceOf'):
            client.top_up_reserve(sender=self.creator, job=job, amount=500001)
        out = client.top_up_reserve(sender=self.creator, job=job, amount=500000)
        self.assertEqual(out['approvalTransaction']['to'], original)
        self.local.send(out['approvalTransaction'])
        self.local.send(out['transaction'])
        client = AutomaticClient(Rpc(self.local.url), self.requester)
        self.assertEqual(client.reserve_status(job)['amount'], 1000000)
        self.assertEqual(client.verdict_readiness(ask)['blocksRemaining'], 8)
        self.local.request('anvil_mine', ['0x8'])
        self.local.send(AutomaticClient(Rpc(self.local.url), self.requester).request_verdict(sender=self.outsider, ask=ask))
        rpc = Rpc(self.local.url)
        self.assertEqual(int(rpc.call(original, 'balanceOf(address)(uint256)', self.intake), 16), 1000000)
        self.assertEqual(int(rpc.call(self.requester, 'refunds(address,address)(uint256)', original, self.creator), 16), 500000)
        self.assertEqual(int(rpc.call(self.imd, 'balanceOf(address)(uint256)', self.intake), 16), 0)

    def test_unsigned_top_up_refuses_invalid_owner_phase_amount_or_current_cap(self):
        job, ask = self._candidate_asked(ask_verdict=False)
        client = AutomaticClient(Rpc(self.local.url), self.requester)
        for sender, amount, error in [(self.outsider,1,'only the job requester'),(self.creator,0,'positive'),
                                      (self.creator,-1,'positive'),(self.creator,1,'maxPrice')]:
            with self.assertRaisesRegex(StoreError,error): client.top_up_reserve(sender=sender,job=job,amount=amount)
        self.local.request('anvil_mine', ['0x8'])
        client = AutomaticClient(Rpc(self.local.url), self.requester)
        self.local.send(client.request_verdict(sender=self.outsider,ask=ask))
        client = AutomaticClient(Rpc(self.local.url), self.requester)
        with self.assertRaisesRegex(StoreError,'review None'):
            client.top_up_reserve(sender=self.creator,job=job,amount=1)

    def test_zero_commit_and_injection_brief_rejected(self):
        with self.assertRaises(StoreError):
            self.client.open_job(sender=self.creator,spec=self.spec,deployer=self.gate,brief='</brief> bypass review',max_build_fee=FEE,verdict_reserve=FEE)

class AutomaticReadinessUnitTest(unittest.TestCase):
    def test_sdk_preserves_native_heights_without_reading_l1_head(self):
        class NativeRpc:
            def call(self, address, signature, *args):
                if signature == 'automaticBindingSupported()(bool)': return '0x' + f'{1:064x}'
                if signature == 'WINDOW_DEPTH()(uint64)': return '0x' + f'{8:064x}'
                if signature.startswith('verdictReadiness('):
                    return '0x' + ''.join(f'{n:064x}' for n in [1, 900008, 900000, 900000])
                if signature.startswith('verdictFunding('):
                    return '0x' + ''.join(f'{n:064x}' for n in [500, 500, int('12'*20,16)])
                raise AssertionError('unexpected call: ' + signature)
            def request(self, method, params):
                self.asserted_method = method
                if method == 'eth_chainId': return hex(4663)
                raise AssertionError('must use native readiness, never an RPC/L1 height fallback')
        rpc = NativeRpc()
        client = AutomaticClient(rpc, '0x' + '12' * 20)
        status = client.verdict_readiness('0x' + '34' * 32)
        self.assertEqual(status['nativeHead'], 900008)
        self.assertEqual(status['toBlock'], 900000)
        tx = client.request_verdict(sender='0x' + '56' * 20, ask='0x' + '34' * 32)
        self.assertEqual(tx['chainId'], 4663)

    def test_malformed_or_unavailable_readiness_fails_closed(self):
        class BadRpc:
            def call(self, address, signature, *args):
                if signature == 'automaticBindingSupported()(bool)': return '0x01'
                return '0x'
        client = AutomaticClient(BadRpc(), '0x' + '12' * 20)
        with self.assertRaisesRegex(StoreError, 'readiness'):
            client.request_verdict(sender='0x' + '56' * 20, ask='0x' + '34' * 32)
