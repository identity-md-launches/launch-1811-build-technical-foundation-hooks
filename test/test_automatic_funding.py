"""Funding readiness and policy failures must stop unsigned/UI transactions before payment."""
import unittest
from unittest.mock import patch
from sdk.automatic import AutomaticClient
from sdk.hooks_store import StoreError, build_spec, keccak_hex
from script.preflight_automatic import preflight

REQUESTER = '0x' + '12' * 20
TOKEN = '0x' + '34' * 20
ASK = '0x' + '56' * 32


def words(*values):
    return '0x' + ''.join(f'{value:064x}' for value in values)


class FundingRpc:
    def __init__(self, price=501, reserve=500, unavailable=False, phase=1):
        self.price, self.reserve, self.unavailable, self.phase = price, reserve, unavailable, phase

    def call(self, address, signature, *args):
        if signature == 'automaticBindingSupported()(bool)': return words(1)
        if signature == 'WINDOW_DEPTH()(uint64)': return words(8)
        if signature.startswith('verdictReadiness('): return words(self.phase, 900008, 900000, 900000)
        if signature.startswith('verdictFunding('):
            if self.unavailable: raise StoreError('quote unavailable')
            return words(self.price, self.reserve, int(TOKEN, 16))
        raise AssertionError(signature)


class FundingReadinessTest(unittest.TestCase):
    def test_price_increase_zero_or_unavailable_quote_is_not_ready(self):
        for rpc in [FundingRpc(), FundingRpc(price=0), FundingRpc(unavailable=True)]:
            with self.subTest(rpc=rpc):
                client = AutomaticClient(rpc, REQUESTER)
                self.assertFalse(client.verdict_readiness(ASK)['ready'])
                with self.assertRaisesRegex(StoreError, 'not ready'):
                    client.request_verdict(sender=TOKEN, ask=ASK)

    def test_positive_affordable_quote_also_requires_phase_readiness(self):
        for phase in [0, 1]:
            client = AutomaticClient(FundingRpc(price=500, phase=phase), REQUESTER)
            result = client.verdict_readiness(ASK)
            self.assertEqual(result['ready'], bool(phase))
            self.assertEqual(result['phaseReady'], bool(phase))
            self.assertEqual(result['funding']['price'], 500)
            self.assertEqual(result['funding']['token'], TOKEN)


class PolicyRpc:
    block = '0x123'

    def __init__(self, chain, age, minimum):
        self.chain, self.age, self.minimum = chain, age, minimum
        self.spec = build_spec(chain_id=str(chain), pool_manager=TOKEN,
                               pool_manager_code_hash=keccak_hex('0x6000'), max_specified_amount='1000000')

    def request(self, method, params):
        assert method == 'eth_chainId'
        return hex(self.chain)

    def code(self, address): return '0x6000'

    def call(self, address, signature, *args):
        if signature == 'requester()(address)': return words(int(REQUESTER, 16))
        if signature in ('codec()(address)', 'intake()(address)', 'asset()(address)'): return words(int(TOKEN, 16))
        if signature == 'head()(uint64)': return words(900008)
        if signature == 'WINDOW_DEPTH()(uint64)': return words(8)
        if signature == 'maxWindowAgeBlocks()(uint64)': return words(self.age)
        if signature == 'minimumWindowAgeBlocks()(uint64)': return words(self.minimum)
        if signature == 'managers(address)(bool,bytes32)': return words(1, int(self.spec['poolManagerCodeHash'], 16))
        return words(1)


class WindowPolicyPreflightTest(unittest.TestCase):
    @patch('script.preflight_automatic.runtime_matches', return_value=True)
    def test_old_default_cannot_pass_on_any_supported_chain(self, _runtime):
        for chain, minimum in [(1,14433), (11155111,14433), (4663,3462008), (31337,173108)]:
            rpc = PolicyRpc(chain, 7200, minimum)
            with self.subTest(chain=chain), self.assertRaises(StoreError):
                preflight(rpc, REQUESTER, TOKEN, rpc.spec)

    @patch('script.preflight_automatic.runtime_matches', return_value=True)
    def test_codec_and_tooling_policy_must_agree(self, _runtime):
        rpc = PolicyRpc(4663, 4000000, 14433)
        with self.assertRaises(StoreError): preflight(rpc, REQUESTER, TOKEN, rpc.spec)

    @patch('script.preflight_automatic.runtime_matches', return_value=True)
    def test_exact_minima_and_larger_policies_report_assumptions(self, _runtime):
        for chain, minimum in [(1,14433), (11155111,14433), (4663,3462008), (31337,173108)]:
            for margin in [0, 999]:
                rpc = PolicyRpc(chain, minimum + margin, minimum)
                result = preflight(rpc, REQUESTER, TOKEN, rpc.spec)
                self.assertEqual(result['windowPolicy']['minimumWindowAgeBlocks'], minimum)
                self.assertEqual(result['windowPolicy']['deliveryHorizonSeconds'], 173100)
                self.assertEqual(result['maxWindowAgeBlocks'], minimum + margin)

    @patch('script.preflight_automatic.runtime_matches', return_value=True)
    def test_unsupported_chain_rejected_without_guessing(self, _runtime):
        rpc = PolicyRpc(999001, 4000000, 14433)
        with self.assertRaises(StoreError): preflight(rpc, REQUESTER, TOKEN, rpc.spec)
