#!/usr/bin/env python3
"""Capture public documentation/capabilities and read-only chain evidence; never submit work.

No credentials, wallet discovery, signatures, quote/payment endpoints or transaction RPCs.
The fixed public URLs below are cited first-party references and their published RPC catalog.
"""
import argparse
import concurrent.futures
import datetime
import hashlib
import json
import subprocess
import sys
from html.parser import HTMLParser
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from sdk.hooks_store import _cast, keccak_hex, load_json
from sdk.deployment import MANIFEST


class Text(HTMLParser):
    def __init__(self):
        super().__init__()
        self.text, self.ids, self.skip = [], [], 0

    def handle_starttag(self, tag, attrs):
        if tag in ('script', 'style'):
            self.skip += 1
        if 'id' in dict(attrs):
            self.ids.append(dict(attrs)['id'])

    def handle_endtag(self, tag):
        if tag in ('script', 'style'):
            self.skip -= 1

    def handle_data(self, value):
        if not self.skip and value.strip():
            self.text.append(value.strip())


def fetch(url, payload=None):
    args = ['curl', '-q', '--fail', '--silent', '--show-error', '--max-time', '20', url]
    if payload is not None:
        args += ['-H', 'Content-Type: application/json', '--data-binary', json.dumps(payload)]
    proc = subprocess.run(args, capture_output=True, timeout=25)
    if proc.returncode:
        raise RuntimeError(f'public HTTP transport failed (curl exit {proc.returncode})')
    return proc.stdout


def capture(out):
    out.mkdir(parents=True, exist_ok=True)
    now = datetime.datetime.now(datetime.timezone.utc).isoformat()
    sources = [
        ('capabilities', 'https://api.imd.fun/requests/capabilities'),
        ('docs', 'https://imd.fun/docs/'),
        ('launcherRecipe', 'https://api.imd.fun/reads/skill/evm-contracts-launch'),
        ('launcherUI', 'https://explorer.imd.fun/launch'),
        ('oracleAttester', 'https://api.imd.fun/oracle/requests?limit=1')]
    report = {'observedAt': now, 'evidenceKind': 'live HTTP observations, no launch or paid request', 'sources': {}}
    bodies = {}
    for name, url in sources:
        body = fetch(url)
        bodies[name] = body
        report['sources'][name] = {'url': url, 'sha256': hashlib.sha256(body).hexdigest(), 'bytes': len(body)}
    capabilities = json.loads(bodies['capabilities'])
    (out / 'capabilities.json').write_text(json.dumps(capabilities, indent=2) + '\n')
    recipe = json.loads(bodies['launcherRecipe'])
    # Raw first-party response preserved as evidence, not as instructions to run commands.
    (out / 'launcher-recipe.json').write_text(json.dumps(recipe, indent=2) + '\n')
    report['oracleAttester'] = json.loads(bodies['oracleAttester']).get('attester')
    report['launcherChains'] = [{'chainId': x['chainId'], 'contractsOnly': 'evm_contracts' in x['kinds']}
                               for x in capabilities['launches']['chains']]
    report['intakeChains'] = [x['chainId'] for x in capabilities['onchain']['chains']]
    parser = Text()
    parser.feed(bodies['docs'].decode())
    text = ' '.join(parser.text)
    report['protocolAnchors'] = {anchor: anchor in parser.ids
        for anchor in ['intake-what-comes-back', 'what-comes-back', 'job-body-launch-fields']}
    report['docsObservations'] = {
        'noPostDeploymentCalls': 'nothing is called after deployment' in text,
        'sepoliaLargerCallbackGas': '1,000,000 on Sepolia' in text,
        'sepoliaNotInCapturedIntakeCapabilities': 11155111 not in report['intakeChains']}
    # Fetch the actual launch page's relevant JS module; detect its no-token selection mapping.
    import re
    paths = re.findall(r'<script[^>]+src="([^"]+)', bodies['launcherUI'].decode())
    def chunk(path):
        raw = fetch('https://explorer.imd.fun' + path)
        content = raw.decode()
        if 'evm_contracts' not in content:
            return None
        snippets = [content[max(0, m.start()-120):m.end()+160] for m in re.finditer('evm_contracts', content)]
        return {'url': 'https://explorer.imd.fun' + path, 'sha256': hashlib.sha256(raw).hexdigest(),
                'containsNoTokenLabel': 'No token' in content, 'evmContractsSnippets': snippets}
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        report['launcherModules'] = [r for r in pool.map(chunk, paths) if r]
    (out / 'official-observations.json').write_text(json.dumps(report, indent=2) + '\n')
    endpoints = {'ethereum': 'https://ethereum-rpc.publicnode.com',
                 'sepolia': 'https://ethereum-sepolia-rpc.publicnode.com',
                 'robinhood': 'https://rpc.mainnet.chain.robinhood.com'}
    m = load_json(MANIFEST)
    def chain_read(profile):
        n = m['profiles'][profile]
        result = {'profile': profile, 'chainId': n['chainId'], 'rpc': endpoints[profile],
                  'observedAt': now, 'evidenceKind': 'live-read-only', 'calls': []}
        def call(method, params):
            payload = {'jsonrpc': '2.0', 'id': len(result['calls'])+1, 'method': method, 'params': params}
            data = json.loads(fetch(endpoints[profile], payload))
            result['calls'].append({'request': payload, 'response': data})
            if 'error' in data:
                raise RuntimeError('RPC error')
            return data['result']
        try:
            if int(call('eth_chainId', []), 16) != n['chainId']:
                raise RuntimeError('RPC chain mismatch')
            block = call('eth_blockNumber', [])
            result['block'] = block
            result['codeHashes'] = {}
            for field in ('intake', 'asset', 'oracleSigner'):
                code = call('eth_getCode', [n[field], block])
                result['codeHashes'][field] = {'address': n[field], 'bytes': (len(code)-2)//2, 'keccak256': keccak_hex(code)}
            result['prices'] = {}
            for action, action_id in m['actions'].items():
                data = _cast('calldata', 'priceOf(bytes32,address)', action_id, n['asset'])
                result['prices'][action] = str(int(call('eth_call', [{'to': n['intake'], 'data': data}, block]), 16))
            for method in ('decimals()', 'symbol()'):
                result[method] = call('eth_call', [{'to': n['asset'], 'data': _cast('calldata', method)}, block])
        except (RuntimeError, KeyError, ValueError, OSError, subprocess.TimeoutExpired) as exc:
            result['failure'] = str(exc) if isinstance(exc, RuntimeError) else type(exc).__name__
        return result
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        chains = list(pool.map(chain_read, endpoints))
    (out / 'live-rpc.json').write_text(json.dumps(chains, indent=2) + '\n')
    print(json.dumps({'observedAt': now, 'launcherChains': report['launcherChains'],
                      'intakeChains': report['intakeChains'], 'oracleAttester': report['oracleAttester'],
                      'docsObservations': report['docsObservations'],
                      'chainReads': [{k: r[k] for k in ('profile', 'block', 'prices', 'failure') if k in r} for r in chains]}, indent=2))
    return 1 if any('failure' in r for r in chains) else 0


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--output-directory', required=True)
    args = p.parse_args()
    try:
        raise SystemExit(capture(Path(args.output_directory)))
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        print('public evidence capture failed: ' + type(error).__name__, file=sys.stderr)
        raise SystemExit(1)
