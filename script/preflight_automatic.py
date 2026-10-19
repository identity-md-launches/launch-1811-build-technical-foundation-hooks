#!/usr/bin/env python3
"""Read-only automatic requester/deployer preflight. No API admission, signatures or transactions.

Supply actual configured addresses. Built runtimes are compared with immutable slots masked;
codec bytes are compared exactly. RPC state is pinned to one block by sdk.hooks_store.Rpc.
"""
import argparse
import json
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from sdk.hooks_store import ROOT, Rpc, StoreError, _hex, load_json, normalize_spec, keccak_hex


def window_policy(chain):
    # Independent tooling policy must agree with the pinned codec on the selected chain.
    floors_ms = {1: 12000, 11155111: 12000, 4663: 50, 31337: 1000}
    if chain not in floors_ms:
        raise StoreError('unsupported automatic window-policy chain')
    floor = floors_ms[chain]
    return {'minimumWindowAgeBlocks': 8 + (173100000 + floor - 1) // floor,
            'deliveryHorizonSeconds': 173100, 'assumedCadenceFloorMilliseconds': floor,
            'assumption': 'Cadence floor is policy, not a measured live guarantee. Monitor native cadence and callback latency.'}


def runtime_matches(rpc, address, name):
    built = load_json(ROOT / 'out' / (name + '.sol') / (name + '.json'))['deployedBytecode']
    actual = bytearray.fromhex(rpc.code(address)[2:])
    expected = bytearray.fromhex(built['object'].removeprefix('0x'))
    if len(actual) != len(expected) or len(actual) > 24576:
        return False
    for refs in built.get('immutableReferences', {}).values():
        for r in refs:
            start, length = r['start'], r['length']
            actual[start:start+length] = expected[start:start+length] = bytes(length)
    return actual == expected


def preflight(rpc, requester, deployer, spec):
    requester = _hex(requester, 20, 'requester'); deployer = _hex(deployer, 20, 'deployer')
    spec = normalize_spec(spec)
    chain = int(rpc.request('eth_chainId', []), 16)
    if int(spec['chainId']) != chain:
        raise StoreError('HookSpec and RPC chain differ')
    checks = []
    def require(label, ok):
        checks.append({'check':label,'ok':bool(ok)})
        if not ok: raise StoreError(label + ' failed')
    require('automatic requester runtime',runtime_matches(rpc,requester,'AutoHookJobRequester'))
    require('official gated deployer runtime',runtime_matches(rpc,deployer,'GatedHookDeployer'))
    require('deployer requester binding',rpc.call(deployer,'requester()(address)')[-40:] == requester[2:])
    require('automatic binding enabled',int(rpc.call(deployer,'automaticBindingSupported()(bool)'),16) == 1)
    codec = '0x' + rpc.call(requester,'codec()(address)')[-40:]
    require('exact deterministic codec runtime',runtime_matches(rpc,codec,'HookRequestCodec'))
    policy_window = window_policy(chain)
    codec_minimum = int(rpc.call(codec,'minimumWindowAgeBlocks()(uint64)'),16)
    require('codec and tooling window policy agree',codec_minimum == policy_window['minimumWindowAgeBlocks'])
    depth = int(rpc.call(requester,'WINDOW_DEPTH()(uint64)'),16)
    require('native question clock and confirmed window depth',depth == 8)
    age_blocks = int(rpc.call(requester,'maxWindowAgeBlocks()(uint64)'),16)
    require('native window age covers full delivery horizon',codec_minimum <= age_blocks < 1 << 64)
    native_head = int(rpc.call(requester,'head()(uint64)'),16)
    code = rpc.code(spec['poolManager'])
    require('PoolManager code hash',code != '0x' and keccak_hex(code) == spec['poolManagerCodeHash'])
    policy = rpc.call(deployer,'managers(address)(bool,bytes32)',spec['poolManager'])
    require('enabled PoolManager policy',int(policy[2:66],16) == 1 and '0x'+policy[66:130] == spec['poolManagerCodeHash'])
    intake = '0x' + rpc.call(requester,'intake()(address)')[-40:]
    asset = '0x' + rpc.call(requester,'asset()(address)')[-40:]
    require('Intake and IMD code',rpc.code(intake) != '0x' and rpc.code(asset) != '0x')
    cap = int(rpc.call(requester,'maxPrice()(uint256)'),16)
    token_cap = int(rpc.call(requester,'maxPriceOf(address)(uint256)',asset),16)
    require('current asset cap agrees with compatibility getter',cap == token_cap and cap > 0)
    prices = {}
    for action in ['jobAction','reviewAction']:
        action_id = rpc.call(requester,action+'()(bytes32)')
        price = int(rpc.call(intake,'priceOf(bytes32,address)(uint256)',action_id,asset),16)
        require(action+' sold within cap',0 < price <= cap)
        prices[action] = {'actionId':action_id,'price':price}
    return {'readOnly':True,'readBlock':rpc.block,'chainId':chain,'requester':requester,'deployer':deployer,
            'codec':codec,'intake':intake,'asset':asset,'prices':prices,'checks':checks,
            'nativeHead':native_head,'windowDepth':depth,'maxWindowAgeBlocks':age_blocks,
            'windowPolicy':policy_window,
            'limitation':'Code/configuration preflight only. No live Hooks Store oracle verdict, accepted build, finality or operational handoff is proven.'}


if __name__ == '__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--rpc',required=True);p.add_argument('--requester',required=True);p.add_argument('--deployer',required=True);p.add_argument('--spec',required=True)
    args=p.parse_args()
    try: print(json.dumps(preflight(Rpc(args.rpc),args.requester,args.deployer,load_json(args.spec)),indent=2))
    except (StoreError,OSError,ValueError) as exc: p.exit(2,str(exc)+'\n')
