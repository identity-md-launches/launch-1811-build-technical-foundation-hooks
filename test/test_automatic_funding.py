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


class TokenCapRpc:
    """No maxPrice compatibility fallback is permitted for a legacy reserve."""
    block = 'latest'

    def __init__(self, reserve, cap, current_cap):
        self.reserve, self.cap, self.current_cap = reserve, cap, current_cap
        self.seen = []
        self.bad_cap = None

    def request(self, method, params):
        assert method == 'eth_chainId'
        return hex(31337)

    def call(self, address, signature, *args):
        self.seen.append((address, signature, args))
        if signature == 'automaticBindingSupported()(bool)': return words(1)
        if signature == 'getJob(bytes32)': return words(int(TOKEN, 16), 0, 0, 2, *([0] * 11))
        if signature.startswith('reserveOf('): return words(int(TOKEN, 16), self.reserve, 0)
        if signature.startswith('reserveDeadline('): return words(1800086400)
        if signature.startswith('candidateDigest('): return words(1)
        if signature.startswith('jobAsk('): return ASK
        if signature.startswith('getAsk('): return words(1, *([0] * 8))
        if signature == 'maxPrice()(uint256)': return words(self.current_cap)
        if signature == 'maxPriceOf(address)(uint256)':
            assert args == (TOKEN,)
            if self.bad_cap == 'unavailable': raise StoreError('cap unavailable')
            return self.bad_cap if self.bad_cap is not None else words(self.cap)
        if signature == 'head()(uint64)': return words(900008)
        raise AssertionError(signature)


class TokenCapSdkTest(unittest.TestCase):
    def test_top_up_18_to_6_uses_unchanged_original_cap(self):
        rpc = TokenCapRpc(5 * 10**17, 10**18, 2 * 10**6)
        result = AutomaticClient(rpc, REQUESTER).top_up_reserve(sender=TOKEN, job=ASK, amount=1)
        self.assertEqual(result['reserveAfter'], 5 * 10**17 + 1)
        self.assertEqual(result['approvalTransaction']['to'], TOKEN)
        self.assertNotIn('maxPrice()(uint256)', [s for _, s, _ in rpc.seen])

    def test_top_up_6_to_18_cannot_exceed_original_cap(self):
        rpc = TokenCapRpc(500000, 1000000, 2 * 10**18)
        client = AutomaticClient(rpc, REQUESTER)
        with self.assertRaisesRegex(StoreError, 'maxPriceOf'):
            client.top_up_reserve(sender=TOKEN, job=ASK, amount=500001)
        result = client.top_up_reserve(sender=TOKEN, job=ASK, amount=500000)
        self.assertEqual(result['reserveAfter'], 1000000)
        self.assertNotIn('maxPrice()(uint256)', [s for _, s, _ in rpc.seen])

    def test_unavailable_malformed_zero_or_lowered_token_cap_has_no_fallback(self):
        for cap in ['unavailable', '0x', words(0), words(499)]:
            rpc = TokenCapRpc(500, 1000, 2 * 10**18)
            rpc.bad_cap = cap
            with self.subTest(cap=cap), self.assertRaises(StoreError):
                AutomaticClient(rpc, REQUESTER).top_up_reserve(sender=TOKEN, job=ASK, amount=1)
            self.assertNotIn('maxPrice()(uint256)', [s for _, s, _ in rpc.seen])


class TokenCapPreflightTest(unittest.TestCase):
    @patch('script.preflight_automatic.runtime_matches', return_value=True)
    def test_matching_positive_cap_and_token_argument_required(self, _runtime):
        rpc = PolicyRpc(31337, 173108, 173108)
        original = rpc.call
        def call(address, signature, *args):
            if signature == 'maxPriceOf(address)(uint256)':
                self.assertEqual(address, REQUESTER)
                self.assertEqual(args, (TOKEN,))
            return original(address, signature, *args)
        rpc.call = call
        result = preflight(rpc, REQUESTER, TOKEN, rpc.spec)
        self.assertIn({'check':'current asset cap agrees with compatibility getter','ok':True}, result['checks'])

    @patch('script.preflight_automatic.runtime_matches', return_value=True)
    def test_mismatch_zero_and_unavailable_caps_rejected(self, _runtime):
        for cap, token_cap in [(0,0),(1000,1),(1,1000),(1,None)]:
            rpc = PolicyRpc(31337, 173108, 173108)
            original = rpc.call
            def call(address, signature, *args):
                if signature == 'maxPrice()(uint256)': return words(cap)
                if signature == 'maxPriceOf(address)(uint256)':
                    if token_cap is None: raise StoreError('cap unavailable')
                    return words(token_cap)
                return original(address, signature, *args)
            rpc.call = call
            with self.subTest(cap=cap,token_cap=token_cap), self.assertRaises(StoreError):
                preflight(rpc, REQUESTER, TOKEN, rpc.spec)
