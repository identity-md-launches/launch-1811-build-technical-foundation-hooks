"""The actual requester joins exactly the bodies checked by the public, free schema checker."""
import copy
import json
import unittest
from unittest.mock import patch

from sdk.deployment import canonical, sha256, validate_templates
from sdk.hooks_store import ROOT, Rpc, StoreError, _cast, keccak_hex
from sdk.request_templates import assemble, templates
from test.helpers.local_rpc import LocalChain


class RequestTemplatesTest(unittest.TestCase):
    def test_retained_free_checker_evidence_binds_both_exact_assembled_bodies(self):
        t = json.loads((ROOT / 'deployment/hook-templates.json').read_text())
        bodies = assemble(t, t['sampleSpecHash'], t['sampleBrief'], t['sampleJobId'])
        for action, body in zip(['job.open', 'oracle.request'], bodies):
            saved = (ROOT / f'docs/checks/approval-binding/{action}.body.json').read_text()
            self.assertEqual(body, saved)
            check = json.loads((ROOT / f'docs/checks/approval-binding/{action}.check.json').read_text())
            self.assertEqual(check['inputSha256'], sha256(canonical(json.loads(body))))
            self.assertEqual(check['response']['blockers'], [])
            if action == 'oracle.request':
                self.assertTrue(check['assembledBodyMatchesDraft'])
                self.assertEqual(check['response']['request'], json.loads(body))
        self.assertEqual({k: t[k] for k in templates(1)}, templates(1))
        validate_templates(t, 1, {'sha256': sha256(canonical(t)), 'reference': 'LOCAL bundle integrity test'})

    def test_checker_cannot_validate_a_different_oracle_body(self):
        t = json.loads((ROOT / 'deployment/hook-templates.json').read_text())
        t['checks']['oracle.request']['response']['request']['quorum'] = 2
        with self.assertRaisesRegex(StoreError, 'draft differs'):
            validate_templates(t, 1, {'sha256': sha256(canonical(t)), 'reference': 'LOCAL mismatch test'})

    def test_requester_actual_assembled_bytes_match_checker_fixtures(self):
        with LocalChain() as chain:
            owner, creator, signer = chain.accounts[1:4]
            token = chain.deploy('StoreTokenMock')
            intake = chain.deploy('MockIntake')
            requester = chain.deploy('HookJobRequester', 'f(address,address,address,address,uint256)',
                                     owner, intake, token, signer, str(5 * 10**17))
            job_action, oracle_action = keccak_hex('local job action'), keccak_hex('local oracle action')
            t = json.loads((ROOT / 'deployment/hook-templates.json').read_text())
            hx = lambda s: '0x' + s.encode().hex()
            for action in [job_action, oracle_action]:
                chain.call_transaction(intake, 'setPrice(bytes32,address,uint256)', action, token, str(5 * 10**17))
            chain.call_transaction(requester, 'setJobTemplate(bytes32,bytes,bytes,bytes)', job_action,
                                   hx(t['jobPrefix']), hx(t['jobMiddle']), hx(t['jobSuffix']), sender=owner)
            chain.call_transaction(requester, 'setReviewTemplate(bytes32,bytes,bytes,uint16,uint16)', oracle_action,
                                   hx(t['reviewPrefix']), hx(t['reviewSuffix']), '7', '5', sender=owner)
            chain.call_transaction(token, 'mint(address,uint256)', creator, str(10**18))
            chain.call_transaction(token, 'approve(address,uint256)', requester, str(10**18), sender=creator)
            chain.call_transaction(requester, 'openJob(bytes32,bytes,uint256)', t['sampleSpecHash'],
                                   hx(t['sampleBrief']), str(5 * 10**17), sender=creator)
            job = Rpc(chain.url).call(requester, 'jobIds(uint256)', '0')
            def body(request_id):
                abi = Rpc(chain.url).call(intake, 'bodyOf(bytes32)', request_id)
                return bytes.fromhex(_cast('abi-decode', 'f()(bytes)', abi)[2:]).decode()
            self.assertEqual(body(job), (ROOT / 'docs/checks/approval-binding/job.open.body.json').read_text())
            snapshot = (ROOT / 'docs/checks/approval-binding/sources/previous-job-result.json').read_bytes()
            payload = _cast('abi-encode', 'f(bytes32,bytes32,string)', job, keccak_hex('0x' + snapshot.hex()), 'ipfs://local-fixture')
            chain.call_transaction(intake, 'complete(bytes32,bytes)', job, payload)
            chain.call_transaction(requester, 'requestReview(bytes32,uint256)', job, str(5 * 10**17), sender=creator)
            ask = Rpc(chain.url).call(intake, 'lastRequestId()')
            actual = body(ask)
            self.assertEqual(actual, assemble(t, t['sampleSpecHash'], t['sampleBrief'], job)[1])
            self.assertEqual(actual.replace(job, t['sampleJobId']),
                             (ROOT / 'docs/checks/approval-binding/oracle.request.body.json').read_text())
            self.assertNotIn('0x0x', actual)
            self.assertEqual(json.loads(actual)['chainId'], 1)  # fixture asks ABOUT chain 1 on local Anvil
