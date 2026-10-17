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
