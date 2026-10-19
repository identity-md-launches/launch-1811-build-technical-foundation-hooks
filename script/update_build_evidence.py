#!/usr/bin/env python3
"""Refresh LOCAL build fingerprints and site ABIs after `forge build`; never an audit claim.

Keeps deployment/audited-build.json as historical evidence. Does not compile, install, fetch,
sign, broadcast or modify compiler settings. The current source commit is assigned on submission.
"""
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
BASE = 'e69e04f63832b9fa1e84c7d58c685ce37924a490'


def write(path, value):
    (ROOT / path).write_text(json.dumps(value, indent=2) + '\n')


def main():
    historical = json.loads((ROOT / 'deployment/audited-build.json').read_text())
    paths = set(historical['files']) | {str(p.relative_to(ROOT)) for p in (ROOT / 'src/deployment').glob('*.sol')}
    paths |= {str(p.relative_to(ROOT)) for p in (ROOT / 'src/imd/automatic').glob('*.sol')}
    current = {'sourceCommit': None, 'baseCommit': BASE,
               'description': 'Local fixes for audit dde20fdc: live per-token reserve caps, shared ask ID generation, SDK/preflight token-cap checks and wallet/form context binding through UI receipts/readbacks. Not independently audited; historical audited-build.json is unchanged.',
               'algorithm': 'sha256', 'files': {}, 'contracts': {}}
    for path in sorted(paths):
        current['files'][path] = hashlib.sha256((ROOT / path).read_bytes()).hexdigest()
    fp = json.loads((ROOT / 'docs/build-fingerprints.json').read_text())
    names = list(historical['contracts']) + ['GatedHookDeployer', 'AutoHookJobRequester', 'HookRequestCodec']
    for name in names:
        built = json.loads((ROOT / f'out/{name}.sol/{name}.json').read_text())
        c = current['contracts'][name] = {}
        f = fp['contracts'].setdefault(name, {})
        for part, label in [('bytecode', 'creationCode'), ('deployedBytecode', 'runtimeCode')]:
            code = built[part]['object']
            raw = bytes.fromhex(code[2:])
            c[part] = {'sha256': hashlib.sha256(raw).hexdigest(), 'bytes': len(raw)}
            f[label + 'Bytes'] = len(raw)
            f[label + 'Hash'] = subprocess.check_output(['cast', 'keccak', code], text=True).strip()
        c['immutableReferences'] = built['deployedBytecode'].get('immutableReferences', {})
        if c['deployedBytecode']['bytes'] > 24576:
            raise ValueError(name + ' exceeds EIP-170')
        if name in ('HookJobRequester', 'GatedHookDeployer', 'AutoHookJobRequester', 'HookRequestCodec'):
            write(f'site/{name}.abi.json', built['abi'])
        if c['immutableReferences']:
            f['note'] = 'Compiler runtime template; constructor fills immutables, so live code hashes differ.'
    write('deployment/current-build.json', current)
    write('docs/build-fingerprints.json', fp)
    print('Updated local build fingerprints and ABIs; historical audit evidence unchanged.')


if __name__ == '__main__':
    main()
