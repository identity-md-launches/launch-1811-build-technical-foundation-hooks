#!/usr/bin/env python3
"""Read-only check of the deployed Intake ABI, bytecode and one public request record.
Does not quote, submit, sign, or send a transaction. Sources are public protocol records.
"""
import json
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from script.recheck_official import fetch
from sdk.hooks_store import _cast, keccak_hex

OUT = Path('docs/checks/consolidated')
RPC = 'https://ethereum-rpc.publicnode.com'
INTAKE = '0xa43e6f75ee006411f79ac1c84120606c2330de82'


def main():
    live = json.loads((OUT / 'live/live-rpc.json').read_text())
    chain = next(x for x in live if x['chainId'] == 1)
    code = next(c['response']['result'] for c in chain['calls']
                if c['request']['method'] == 'eth_getCode' and c['request']['params'][0] == INTAKE)
    verified = json.loads((OUT / 'sources/intake-verified.json').read_text())
    report = {'chainId': 1, 'block': chain['block'], 'intake': INTAKE,
              'runtimeHash': keccak_hex(code),
              'verifiedSourceBytecodeMatchesRPC': code.lower() == verified['deployed_bytecode'].lower(),
              'requestsGetter': next(x for x in verified['abi'] if x.get('name') == 'requests'),
              'automaticBindingSupported': False,
              'reason': 'No stored or oracle-signed Intake/body -> UUID/question commitment. Writer supplies success args.'}
    def call(method, params):
        return json.loads(fetch(RPC, {'jsonrpc':'2.0', 'id':1, 'method':method, 'params':params}))
    report['callbackGas'] = call('eth_call', [{'to':INTAKE, 'data':_cast('calldata','callbackGas()')},chain['block']])
    report['blockLimits'] = []
    for item in live:
        response = json.loads(fetch(item['rpc'], {'jsonrpc':'2.0','id':1,'method':'eth_getBlockByNumber',
                                                  'params':[item['block'],False]}))
        block = response.get('result', {})
        report['blockLimits'].append({'chainId':item['chainId'], 'block':item['block'],
                                     'gasLimit':block.get('gasLimit'), 'gasUsed':block.get('gasUsed')})
    topic = keccak_hex('Requested(bytes32,address,bytes32,bytes,address,bytes4,address,uint256)')
    logs = call('eth_getLogs', [{'address':INTAKE,'fromBlock':hex(int(chain['block'],16)-1500),
                               'toBlock':chain['block'],'topics':[topic]}])
    (OUT / 'sources/intake-requested-logs.json').write_text(json.dumps(logs,indent=2)+'\n')
    if logs.get('result'):
        event = logs['result'][-1]
        url = 'https://api.imd.fun/intake/1/' + event['transactionHash']
        record = json.loads(fetch(url))
        (OUT / 'sources/intake-record.json').write_text(json.dumps(record,indent=2)+'\n')
        report['publicRecord'] = {'url':url, 'requestIdFromChain':event['topics'][1],
                                 'authentication':'HTTP mapping is observational, not a protocol-signed proof'}
    (OUT / 'binding-evidence.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))

if __name__ == '__main__': main()
