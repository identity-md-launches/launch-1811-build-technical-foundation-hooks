"""Meaningful success/failure coverage against disposable Anvil and compiled contracts."""
import copy
import json
import subprocess
import unittest
from pathlib import Path
from unittest.mock import patch

from sdk.deployment import (
    MANIFEST, PROPOSED_RECIPIENT, INTAKE_PAYEE, CurlRpc, artifact, canonical, config, configuration_plan,
    deployment_transaction, expected_runtime, names, protocol_preflight, sha256,
    validate_templates, verify_build, verify_configuration,
)
from sdk.hooks_store import ROOT, Rpc, StoreError, _cast, keccak_hex, load_json
from test.helpers.local_rpc import LocalChain, local_templates




class DeploymentPreparationTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.local = LocalChain().__enter__()
        cls.addClassCleanup(cls.local.__exit__, None, None, None)
        cls.owner, cls.signer = cls.local.accounts[1:3]
        cls.token = cls.local.deploy('StoreTokenMock')
        cls.intake = cls.local.deploy('MockIntake')
        for action in load_json(MANIFEST)['actions'].values():
            cls.local.call_transaction(cls.intake, 'setPrice(bytes32,address,uint256)', action, cls.token, '500000000000000000')
        cls.base = load_json(ROOT / 'deployment/sepolia.draft.json')
        cls.base.update(profile='local', owner=cls.owner,
                        ownerApproval={'address': cls.owner, 'reference': 'LOCAL fixture approval only'},
                        recipientApproval={'address': PROPOSED_RECIPIENT, 'reference': 'LOCAL fixture approval only'},
                        localProtocol={'intake': cls.intake, 'asset': cls.token, 'oracleSigner': cls.signer})
        cls.addresses = {}
        for name in names(config(cls.base)):
            tx = deployment_transaction(cls.base, name, cls.addresses)
            cls.addresses[name] = cls.local.send(tx['transaction'])['contractAddress']

    def setUp(self):
        self.snapshot = self.local.request('evm_snapshot', [])
        self.c = copy.deepcopy(self.base)

    def tearDown(self):
        self.assertTrue(self.local.request('evm_revert', [self.snapshot]))

    def rpc(self):
        return Rpc(self.local.url)

    def test_complete_unsigned_deploy_configure_readback_and_idempotence(self):
        evidence = protocol_preflight(self.c, self.rpc())
        self.assertEqual(evidence['prices']['job.open'], '500000000000000000')
        plan = configuration_plan(self.c, self.addresses, self.rpc())
        self.assertEqual([t['signature'] for t in plan['transactions']],
                         ['configureToken(address)', 'setProceedsRecipient(address)'])
        with self.assertRaisesRegex(StoreError, 'readback'):
            verify_configuration(self.c, self.addresses, self.rpc())
        for item in plan['transactions']:
            self.assertEqual(item['transaction']['from'], self.owner)
            self.assertEqual(item['transaction']['value'], '0x0')
            receipt = self.local.send(item['transaction'])
            self.assertEqual(receipt['status'], '0x1')
        verified = verify_configuration(self.c, self.addresses, self.rpc())
        self.assertEqual(verified['status'], 'configuration-matches')
        self.assertFalse(verified['paidPilotProven'])
        self.assertEqual(configuration_plan(self.c, self.addresses, self.rpc())['transactions'], [])
        for name, target in self.addresses.items():
            self.assertEqual(self.rpc().code(target), expected_runtime(name, config(self.c), self.addresses))

    def test_exact_templates_and_settings_calldata_then_all_readbacks(self):
        t = local_templates(31337)
        self.c.update(templates=t, templateApproval={'sha256': sha256(canonical(t)), 'reference': 'LOCAL fixture approval'})
        self.c['jobTimeout'] = 2 * 86400
        self.c['reviewTimeout'] = 7200
        plan = configuration_plan(self.c, self.addresses, self.rpc())
        self.assertIn('setJobTemplate(bytes32,bytes,bytes,bytes)', [t['signature'] for t in plan['transactions']])
        self.assertIn('setReviewTemplate(bytes32,bytes,bytes,uint16,uint16)', [t['signature'] for t in plan['transactions']])
        for item in plan['transactions']:
            self.local.send(item['transaction'])
        self.assertEqual(verify_configuration(self.c, self.addresses, self.rpc())['status'], 'configuration-matches')
        self.assertEqual(configuration_plan(self.c, self.addresses, self.rpc())['transactions'], [])
        self.c['templates']['jobPrefix'] = self.c['templates']['jobPrefix'].replace('Build', 'Make')
        with self.assertRaisesRegex(StoreError, 'stale|Approval'):
            configuration_plan(self.c, self.addresses, self.rpc())

    def test_no_guessed_owner_or_unapproved_recipient_or_payee_substitution(self):
        for change, message in [({'owner': None}, 'owner'), ({'ownerApproval': None}, 'Approval'),
                                ({'owner': '0x' + '00' * 20}, 'placeholder'),
                                ({'recipientApproval': None}, 'Approval'),
                                ({'adProceedsRecipient': INTAKE_PAYEE}, 'payee'),
                                ({'ownerApproval': {'address': self.signer, 'reference': 'wrong address'}}, 'Approval')]:
            with self.subTest(change=change), self.assertRaisesRegex(StoreError, message):
                configuration_plan({**self.c, **change}, self.addresses, self.rpc())
        self.assertEqual(load_json(MANIFEST)['proposedAdProceedsRecipient'], PROPOSED_RECIPIENT)

    def test_constructor_dependency_order_and_no_factory_on_production(self):
        with self.assertRaisesRegex(StoreError, 'registry first'):
            deployment_transaction(self.c, 'FeaturedPlacements')
        for profile in ('ethereum', 'robinhood'):
            c = load_json(ROOT / f'deployment/{profile}.draft.json')
            c.update(owner=self.owner, ownerApproval=self.c['ownerApproval'])
            self.assertNotIn('HooksStoreFactory', names(config(c)))
            with self.assertRaisesRegex(StoreError, 'not supported'):
                deployment_transaction(c, 'HooksStoreFactory')
        self.c['profile'] = 'sepolia'
        with self.assertRaisesRegex(StoreError, 'overrides'):
            config(self.c)

    def test_actual_unsold_overpriced_and_chain_mismatch_fail_preflight(self):
        action = load_json(MANIFEST)['actions']['job.open']
        for price in ('0', '500000000000000001'):
            self.local.call_transaction(self.intake, 'setPrice(bytes32,address,uint256)', action, self.token, price)
            with self.assertRaisesRegex(StoreError, 'unsold|ceiling'):
                protocol_preflight(self.c, self.rpc())
        public = load_json(ROOT / 'deployment/sepolia.draft.json')
        with self.assertRaisesRegex(StoreError, 'chain mismatch'):
            protocol_preflight(public, self.rpc())

    def test_both_rpc_transports_are_read_only_and_observe_same_snapshot(self):
        direct, curl = self.rpc(), CurlRpc(self.local.url)
        self.assertEqual(protocol_preflight(self.c, direct), protocol_preflight(self.c, curl))
        for rpc in (direct, curl):
            with self.assertRaisesRegex(StoreError, 'read-only'):
                rpc.request('eth_sendTransaction', [])

    def test_public_protocol_code_change_requires_new_review(self):
        class ChangedCodeRpc:
            block = '0x1'
            def request(self, method, params):
                return hex(11155111)
            def code(self, address):
                return '0x60006000'
        with self.assertRaisesRegex(StoreError, 'protocol code changed'):
            protocol_preflight(load_json(ROOT / 'deployment/sepolia.draft.json'), ChangedCodeRpc())

    def test_missing_code_wrong_owner_wrong_registry_and_immutable_tamper_fail(self):
        wrong = dict(self.addresses, HookListingRegistry=self.signer)
        with self.assertRaisesRegex(StoreError, 'runtime'):
            configuration_plan(self.c, wrong, self.rpc())
        self.c['owner'] = self.local.accounts[3]
        self.c['ownerApproval'] = {'address': self.c['owner'], 'reference': 'LOCAL wrong owner'}
        with self.assertRaisesRegex(StoreError, 'readback'):
            configuration_plan(self.c, self.addresses, self.rpc())
        self.c = copy.deepcopy(self.base)
        req = self.addresses['HookJobRequester']
        code = bytearray.fromhex(self.rpc().code(req)[2:])
        span = next(iter(artifact('HookJobRequester')['deployedBytecode']['immutableReferences'].values()))[0]
        code[span['start']] ^= 1
        self.local.request('anvil_setCode', [req, '0x' + code.hex()])
        with self.assertRaisesRegex(StoreError, 'runtime/immutables'):
            configuration_plan(self.c, self.addresses, self.rpc())

    def test_conflicting_one_time_token_and_wrong_caller_fail(self):
        other_token = self.local.deploy('StoreTokenMock')
        ads = self.addresses['FeaturedPlacements']
        self.local.call_transaction(ads, 'configureToken(address)', other_token, sender=self.owner)
        with self.assertRaisesRegex(StoreError, 'token configuration conflicts'):
            configuration_plan(self.c, self.addresses, self.rpc())
        from sdk.hooks_store import ReceiptReverted
        with self.assertRaises(ReceiptReverted):
            self.local.call_transaction(ads, 'setProceedsRecipient(address)', PROPOSED_RECIPIENT)

    def test_body_checks_reject_blockers_wrong_chain_old_fixture_and_changed_approval(self):
        t = local_templates(31337)
        approve = lambda: {'sha256': sha256(canonical(t)), 'reference': 'LOCAL only'}
        validate_templates(t, 31337, approve())
        t['checks']['oracle.request']['response']['blockers'] = ['ambiguous']
        with self.assertRaisesRegex(StoreError, 'blocked'):
            validate_templates(t, 31337, approve())
        t = local_templates(31337)
        with self.assertRaisesRegex(StoreError, 'this chain'):
            validate_templates(t, 1, approve())
        t['jobPrefix'] = t['jobPrefix'].replace('objective', 'request')
        with self.assertRaisesRegex(StoreError, 'objective'):
            validate_templates(t, 31337, approve())
        t = local_templates(31337)
        self.c['templates'] = t
        self.c['templateApproval'] = approve()
        self.c.pop('localProtocol')
        self.c['profile'] = 'sepolia'
        with self.assertRaisesRegex(StoreError, 'infrastructure only'):
            config(self.c)

    def test_existing_scripts_simulate_without_broadcasting(self):
        before = self.local.request('eth_blockNumber', [])
        for args in [
            ['script/DeployStore.s.sol:DeployStore', '--sig', 'run(address)', self.owner],
            ['script/DeployHookJobRequester.s.sol:DeployHookJobRequester', '--sig',
             'run(address,(address,address,address,address,uint256))', self.owner,
             f'({self.owner},{self.intake},{self.token},{self.signer},500000000000000000)']]:
            result = subprocess.run(['forge', 'script', *args, '--rpc-url', self.local.url],
                                    text=True, capture_output=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('Script ran successfully', result.stdout)
        self.assertEqual(self.local.request('eth_blockNumber', []), before, 'simulations must not broadcast')

    def test_verify_build_detects_artifact_change_and_cli_refuses_draft_creation(self):
        self.assertEqual(verify_build()['status'], 'unchanged')
        original = artifact
        def altered(name, root=ROOT):
            a = original(name, root)
            a['bytecode']['object'] += '00'
            return a
        with patch('sdk.deployment.artifact', side_effect=altered), self.assertRaisesRegex(StoreError, 'bytecode changed'):
            verify_build()
        result = subprocess.run(['python3', 'script/prepare_deployment.py', 'creation', '--config',
                                 'deployment/sepolia.draft.json', '--contract', 'HookListingRegistry'],
                                text=True, capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, '')
