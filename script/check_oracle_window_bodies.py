#!/usr/bin/env python3
"""Capture exact LOCAL emitted bodies and optional free public checks; never pay/sign/admit.

Run the named Foundry tests first, saving -vv output to --log. Fixture addresses and ids
are local examples even when vm.chainId selects Ethereum or Robinhood. They are not live
jobs. --check sends only POST /requests/check and preserves the actual bytes/status/body.
The full oracle body and the endpoint's narrower drafting input are saved separately.
"""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import urllib.error
import urllib.request

URL = 'https://api.imd.fun/requests/check'


def capture(log, directory, check=False):
    directory.mkdir(parents=True, exist_ok=True)
    context = None
    records = []
    for line in log.read_text().splitlines():
        if 'testSaveEthereumBodyAndOfficialQuestionCompatibility()' in line:
            context = 'ethereum'
        elif 'testSaveRobinhoodBodyAndOfficialQuestionCompatibility()' in line:
            context = 'robinhood'
        elif line.startswith('[PASS]') or line.startswith('[FAIL]'):
            context = None
        if context is None:
            continue
        for marker, action in [('JOB_BODY: ', 'job.open'), ('ORACLE_BODY: ', 'oracle.request')]:
            if marker not in line:
                continue
            raw = line.split(marker, 1)[1].encode()
            body = json.loads(raw)
            stem = context + '.' + action
            (directory / (stem + '.body.json')).write_bytes(raw)
            record = {'example': stem, 'localFixtureOnly': True, 'rawBodyBytes': len(raw),
                      'rawBodySha256': hashlib.sha256(raw).hexdigest()}
            records.append(record)
            if not check:
                continue
            modes = [('exact', body)]
            if action == 'oracle.request':
                fields = {'question', 'panelSize', 'answerType', 'evidence', 'chainId', 'toleranceBps', 'head'}
                modes.append(('draft', {k: v for k, v in body.items() if k in fields}))
            for mode, value in modes:
                # Embed the unmodified emitted JSON bytes for the exact-body check.
                payload = (b'{"action":' + json.dumps(action).encode() + b',"input":' + raw + b'}') if mode == 'exact' else json.dumps({'action': action, 'input': value}, separators=(',', ':')).encode()
                prefix = directory / (stem + '.' + mode)
                prefix.with_suffix(prefix.suffix + '.request.json').write_bytes(payload)
                req = urllib.request.Request(URL, payload, {'Content-Type': 'application/json'})
                try:
                    response = urllib.request.urlopen(req, timeout=55)
                except urllib.error.HTTPError as exc:
                    response = exc
                with response:
                    status, result = response.status, response.read()
                prefix.with_suffix(prefix.suffix + '.response.json').write_bytes(result)
                outcome = {'url': URL, 'checkedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                           'mode': mode, 'httpStatus': status, 'localFixtureOnly': True,
                           'requestSha256': hashlib.sha256(payload).hexdigest(),
                           'responseSha256': hashlib.sha256(result).hexdigest()}
                prefix.with_suffix(prefix.suffix + '.metadata.json').write_text(json.dumps(outcome, indent=2) + '\n')
                print(stem, mode, status, flush=True)
    if len(records) != 4:
        raise ValueError('expected both exact job and oracle bodies from both named tests')
    (directory / 'bodies.json').write_text(json.dumps(records, indent=2) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--log', type=Path, required=True)
    parser.add_argument('--directory', type=Path, required=True)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    capture(args.log, args.directory, args.check)
