#!/usr/bin/env python3
"""Free public body check only. No quote, payment, credentials, signature or request admission."""
import argparse
import datetime
import json
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from sdk.hooks_store import load_json
from sdk.deployment import canonical, sha256
from script.recheck_official import fetch


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--action', required=True, choices=['job.open', 'oracle.request'])
    p.add_argument('--input', required=True, help='exact assembled body JSON for this pilot')
    p.add_argument('--output', required=True, help='checker evidence to include under templates.checks[action]')
    args = p.parse_args()
    body = load_json(args.input)
    url = 'https://api.imd.fun/requests/check'
    response = json.loads(fetch(url, {'action': args.action, 'input': body}))
    record = {'inputSha256': sha256(canonical(body)), 'response': response,
              'reference': url + ' at ' + datetime.datetime.now(datetime.timezone.utc).isoformat()}
    Path(args.output).write_text(json.dumps(record, indent=2) + '\n')
    # An HTTP 200 by itself is not approval. Preserve all checker output, including blockers.
    return 0 if response.get('action') == args.action and response.get('blockers') == [] else 1


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired):
        print('free body check failed; no work was admitted', file=sys.stderr)
        raise SystemExit(1)
