#!/usr/bin/env python3
"""Disposable local Anvil rehearsal. It cannot accept a public RPC or a private key.

Creates only local application and mock protocol contracts, never a project token or a pool.
Owner/recipient approval records here are test fixtures and are never valid for a public plan.
"""
import argparse
import json
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from sdk.hooks_store import ROOT, Rpc, load_json
from sdk.deployment import (MANIFEST, PROPOSED_RECIPIENT, config, names, protocol_preflight,
                            deployment_transaction, configuration_plan, verify_configuration, verify_build, canonical, sha256)
from test.helpers.local_rpc import LocalChain, local_templates


def run(output):
    output.mkdir(parents=True, exist_ok=True)
    evidence = {'evidenceKind': 'LOCAL MOCKS ONLY; not a public deployment or live paid pilot',
                'build': verify_build(), 'deployments': [], 'configurationReceipts': []}
    with LocalChain() as local, (output / 'local-script-dry-runs.log').open('w') as transcript:
        owner, signer = local.accounts[1:3]
        asset = local.deploy('StoreTokenMock')
        intake = local.deploy('MockIntake')
        for action in load_json(MANIFEST)['actions'].values():
            local.call_transaction(intake, 'setPrice(bytes32,address,uint256)', action, asset, '500000000000000000')
        c = load_json(ROOT / 'deployment/sepolia.draft.json')
        c.update(profile='local', owner=owner,
                 ownerApproval={'address': owner, 'reference': 'LOCAL FIXTURE; no real approval'},
                 recipientApproval={'address': PROPOSED_RECIPIENT, 'reference': 'LOCAL FIXTURE; no real approval'},
                 localProtocol={'intake': intake, 'asset': asset, 'oracleSigner': signer})
        evidence['localConfig'] = dict(c)
        evidence['preflight'] = protocol_preflight(c, Rpc(local.url))
        block_before = local.request('eth_blockNumber', [])
        for cmd in [
            ['forge', 'script', 'script/DeployStore.s.sol:DeployStore', '--sig', 'run(address)', owner],
            ['forge', 'script', 'script/DeployHookJobRequester.s.sol:DeployHookJobRequester', '--sig',
             'run(address,(address,address,address,address,uint256))', owner,
             f'({owner},{intake},{asset},{signer},500000000000000000)']]:
            cmd += ['--rpc-url', local.url]
            transcript.write('$ argv = ' + json.dumps(cmd) + '\n')
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=90)
            transcript.write(result.stdout + result.stderr + f'\nexit={result.returncode}\n')
            transcript.flush()
            if result.returncode:
                raise RuntimeError('existing deployment script simulation failed')
        if local.request('eth_blockNumber', []) != block_before:
            raise RuntimeError('script simulation unexpectedly submitted a transaction')
        evidence['scriptSimulationsDidNotBroadcast'] = True
        addresses = {}
        for name in names(config(c)):
            creation = deployment_transaction(c, name, addresses)
            receipt = local.send(creation['transaction'])
            addresses[name] = receipt['contractAddress']
            evidence['deployments'].append({'unsigned': creation, 'localReceipt': receipt})
        evidence['addresses'] = addresses
        evidence['ownerPlan'] = configuration_plan(c, addresses, Rpc(local.url))
        for item in evidence['ownerPlan']['transactions']:
            evidence['configurationReceipts'].append(local.send(item['transaction']))
        evidence['readback'] = verify_configuration(c, addresses, Rpc(local.url))
        if configuration_plan(c, addresses, Rpc(local.url))['transactions']:
            raise RuntimeError('configuration was not idempotent')
        evidence['repeatedConfiguration'] = 'no calls needed'
        # Exercise requester activation with explicitly LOCAL checker/approval fixtures, no paid call.
        t = local_templates(31337)
        c.update(templates=t, templateApproval={'sha256': sha256(canonical(t)), 'reference': 'LOCAL FIXTURE ONLY'})
        c['jobTimeout'], c['reviewTimeout'] = 172800, 7200
        actions = load_json(MANIFEST)['actions']
        h = lambda key: '0x' + t[key].encode().hex()
        template_tuple = '(' + ','.join([actions['job.open'], h('jobPrefix'), h('jobMiddle'), h('jobSuffix'),
            actions['oracle.request'], h('reviewPrefix'), h('reviewSuffix'), str(t['minPanelSize']), str(t['minAgreed'])]) + ')'
        cmd = ['forge', 'script', 'script/DeployHookJobRequester.s.sol:DeployHookJobRequester', '--sig',
               'runConfigure(address,address,(bytes32,bytes,bytes,bytes,bytes32,bytes,bytes,uint16,uint16))',
               owner, addresses['HookJobRequester'], template_tuple, '--rpc-url', local.url]
        block_before = local.request('eth_blockNumber', [])
        transcript.write('$ argv = ' + json.dumps(cmd) + '\n')
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=90)
        transcript.write(result.stdout + result.stderr + f'\nexit={result.returncode}\n')
        if result.returncode or local.request('eth_blockNumber', []) != block_before:
            raise RuntimeError('existing runConfigure simulation failed or broadcast')
        activation = {'evidenceKind': 'LOCAL MOCKS ONLY; never a live-approved template bundle', 'config': c,
                      'ownerPlan': configuration_plan(c, addresses, Rpc(local.url)), 'receipts': []}
        for item in activation['ownerPlan']['transactions']:
            activation['receipts'].append(local.send(item['transaction']))
        activation['readback'] = verify_configuration(c, addresses, Rpc(local.url))
        (output / 'local-requester-activation.json').write_text(json.dumps(activation, indent=2) + '\n')
    (output / 'local-dry-run.json').write_text(json.dumps(evidence, indent=2) + '\n')
    print(json.dumps({'evidenceKind': evidence['evidenceKind'], 'contracts': list(evidence['addresses']),
                      'ownerCalls': [x['signature'] for x in evidence['ownerPlan']['transactions']],
                      'readback': evidence['readback'], 'scriptSimulationsDidNotBroadcast': True}, indent=2))


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--output-directory', required=True)
    args = p.parse_args()
    run(Path(args.output_directory))
