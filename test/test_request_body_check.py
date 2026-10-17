"""The free checker records exact input binding and never treats an HTTP success as approval."""
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from script.check_request_body import main
from sdk.deployment import canonical, sha256
from sdk.hooks_store import ROOT


class RequestBodyCheckTest(unittest.TestCase):
    def test_free_endpoint_payload_and_success_failure_evidence(self):
        scratch = ROOT / 'test/scratch'
        scratch.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as directory:
            body = {'objective': 'Local fixture for checker transport; no work is admitted.'}
            inp, out = Path(directory) / 'input.json', Path(directory) / 'output.json'
            inp.write_text(json.dumps(body))
            argv = ['check_request_body.py', '--action', 'job.open', '--input', str(inp), '--output', str(out)]
            for response, expected in [({'action': 'job.open', 'blockers': []}, 0),
                                       ({'action': 'job.open', 'blockers': ['missing input']}, 1),
                                       ({'action': 'oracle.request', 'blockers': []}, 1),
                                       ({'action': 'job.open'}, 1)]:
                with patch('sys.argv', argv), patch('script.check_request_body.fetch', return_value=json.dumps(response).encode()) as fetch:
                    self.assertEqual(main(), expected)
                    fetch.assert_called_once_with('https://api.imd.fun/requests/check', {'action': 'job.open', 'input': body})
                recorded = json.loads(out.read_text())
                self.assertEqual(recorded['response'], response)
                self.assertEqual(recorded['inputSha256'], sha256(canonical(body)))
                self.assertEqual(recorded['rawBodySha256'], sha256(inp.read_bytes()))
                self.assertEqual(recorded['rawBodyBytes'], len(inp.read_bytes()))


    def test_oracle_projection_requires_exact_full_draft_not_only_no_blockers(self):
        scratch = ROOT / 'test/scratch'
        scratch.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as directory:
            body = {'v': 1, 'question': 'Did the public review pass?', 'chainId': 1, 'window': {'hours': 24},
                    'answerType': 'bool', 'evidence': 'panel', 'panelSize': 7, 'quorum': 5, 'validForSeconds': 86400}
            inp, out = Path(directory) / 'input.json', Path(directory) / 'output.json'
            inp.write_text(json.dumps(body))
            argv = ['check_request_body.py', '--action', 'oracle.request', '--input', str(inp), '--output', str(out)]
            for exact in (True, False):
                request = dict(body)
                if not exact:
                    request['quorum'] = 2
                response = {'action': 'oracle.request', 'blockers': [], 'request': request}
                with patch('sys.argv', argv), patch('script.check_request_body.fetch', return_value=json.dumps(response).encode()) as fetch:
                    self.assertEqual(main(), 0 if exact else 1)
                    payload = fetch.call_args.args[1]
                    self.assertEqual(set(payload['input']), {'question', 'chainId', 'answerType', 'evidence', 'panelSize'})
                recorded = json.loads(out.read_text())
                self.assertEqual(recorded['assembledBodyMatchesDraft'], exact)
                self.assertEqual(recorded['inputSha256'], sha256(canonical(body)))
                self.assertEqual(recorded['rawBodySha256'], sha256(inp.read_bytes()))
                self.assertEqual(recorded['rawBodyBytes'], len(inp.read_bytes()))
                self.assertEqual(recorded['response'], response)
