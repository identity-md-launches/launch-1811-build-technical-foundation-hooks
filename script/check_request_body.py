#!/usr/bin/env python3
"""Free public body check only. No quote, payment, credentials, signature or request admission."""
import argparse
import datetime
import json
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from sdk.hooks_store import load_json, keccak_hex
from sdk.deployment import canonical, sha256
from script.recheck_official import fetch


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--action', required=True, choices=['job.open', 'oracle.request'])
    p.add_argument('--input', required=True, help='exact assembled body JSON for this pilot')
    p.add_argument('--output', required=True, help='checker evidence to include under templates.checks[action]')
    args = p.parse_args()
    raw_body = Path(args.input).read_bytes()
    body = load_json(args.input)
    url = 'https://api.imd.fun/requests/check'
    # The official checker accepts a drafting subset for oracle.request, NOT its full body.
    # Only approve the assembled body if the returned full request equals it exactly.
    checker_input = body
    if args.action == 'oracle.request':
        fields = {'question', 'panelSize', 'answerType', 'evidence', 'chainId', 'toleranceBps', 'head'}
        checker_input = {k: v for k, v in body.items() if k in fields}
    response = json.loads(fetch(url, {'action': args.action, 'input': checker_input}))
    matches = args.action != 'oracle.request' or response.get('request') == body
    record = {'inputSha256': sha256(canonical(body)), 'rawBodySha256': sha256(raw_body),
              'rawBodyKeccak256': keccak_hex('0x' + raw_body.hex()), 'rawBodyBytes': len(raw_body),
              'response': response,
              'checkerInput': {'action': args.action, 'input': checker_input},
              'assembledBodyMatchesDraft': matches,
              'reference': url + ' at ' + datetime.datetime.now(datetime.timezone.utc).isoformat()}
    Path(args.output).write_text(json.dumps(record, indent=2) + '\n')
    # An HTTP 200 by itself is not approval. Preserve all checker output, including blockers.
    return 0 if response.get('action') == args.action and response.get('blockers') == [] and matches else 1


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired):
        print('free body check failed; no work was admitted', file=sys.stderr)
        raise SystemExit(1)
