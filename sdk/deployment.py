"""Deployment preparation only: no keys, signatures, broadcasts or paid Intake calls.

Uses the existing Store SDK's ABI encoder, artifact loader conventions and read-only RPC.
Public protocol addresses are first-party observations in manifest.json, not owner guesses.
"""
import hashlib
import ipaddress
import json
import re
import subprocess
from pathlib import Path
from urllib.parse import urlsplit

from sdk.hooks_store import ROOT, Rpc, StoreError, _cast, _decimal, _hex, _unique_object, keccak_hex, load_json

MANIFEST = ROOT / 'deployment/manifest.json'
BASELINE = ROOT / 'deployment/current-build.json'
PROPOSED_RECIPIENT = '0x3f252e859a277a86A3967c11D4E054B2f07a1F22'
# A published protocol payee is never the proposed advertising beneficiary.
INTAKE_PAYEE = '0x4e0fa57bde726079356537e2f34d671e9f41adbc'
ZERO_WORD = '0x' + '00' * 32
CONFIG_KEYS = {'version', 'profile', 'owner', 'ownerApproval', 'adProceedsRecipient',
               'recipientApproval', 'maxPrice', 'jobTimeout', 'reviewTimeout', 'templates',
               'templateApproval', 'localProtocol'}
TEMPLATE_KEYS = {'jobPrefix', 'jobMiddle', 'jobSuffix', 'reviewPrefix', 'reviewSuffix',
                 'minPanelSize', 'minAgreed', 'sampleSpecHash', 'sampleBrief', 'sampleJobId', 'checks'}


class CurlRpc(Rpc):
    """Explicit alternative transport for networks that require curl's HTTP proxy support.

    No curl config file is read (-q); RPC URLs and transport diagnostics are never printed.
    As with Rpc, every method is read-only and state reads use a fixed block number.
    """
    def request(self, method, params, *, timeout=30):
        if method not in {'eth_chainId', 'eth_blockNumber', 'eth_getCode', 'eth_call', 'eth_getTransactionReceipt'}:
            raise StoreError('only read-only RPC methods are permitted')
        self.counter += 1
        payload = json.dumps({'jsonrpc': '2.0', 'id': self.counter, 'method': method, 'params': params})
        host = urlsplit(self.url).hostname
        try:
            loopback = ipaddress.ip_address(host).is_loopback
        except ValueError:
            loopback = host == 'localhost'
        # A local rehearsal must never be sent through a public HTTP proxy.
        routing = ['--noproxy', '*'] if loopback else []
        try:
            result = subprocess.run(['curl', '-q', *routing, '--fail', '--silent', '--max-time', str(timeout),
                                     '-H', 'Content-Type: application/json', '--data-binary', payload, self.url],
                                    capture_output=True, timeout=timeout + 1)
            if result.returncode:
                raise StoreError('RPC transport failed')
            data = json.loads(result.stdout)
        except (OSError, ValueError, subprocess.TimeoutExpired) as exc:
            raise StoreError('RPC transport failed') from exc
        if 'error' in data:
            raise StoreError(method + ' failed; inspect the RPC response privately for revert details')
        if data.get('id') != self.counter or 'result' not in data:
            raise StoreError('invalid JSON-RPC response')
        return data['result']


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()


def address(value, field):
    value = _hex(value, 20, field)
    if int(value, 16) in (0, 0xdead):
        raise StoreError(field + ' must be supplied; zero/burn placeholders are forbidden')
    return value


def approval(record, expected, field):
    if not isinstance(record, dict) or set(record) != {'address', 'reference'} or \
            not isinstance(record['reference'], str) or not record['reference'].strip() or \
            address(record['address'], field) != expected.lower():
        raise StoreError(field + ' requires approval of this exact address and an operator evidence reference')


def artifact(name, root=ROOT):
    item = load_json(Path(root) / 'out' / (name + '.sol') / (name + '.json'))
    for part in ('bytecode', 'deployedBytecode'):
        if not re.fullmatch(r'0x(?:[0-9a-fA-F]{2})+', item[part]['object']):
            raise StoreError('missing/unlinked artifact: ' + name)
    return item


def verify_build(root=ROOT):
    """Compare this local build snapshot, including sources/config. This is not an audit."""
    baseline = load_json(BASELINE)
    for name, expected in baseline['files'].items():
        if sha256((Path(root) / name).read_bytes()) != expected:
            raise StoreError('pinned source/config changed: ' + name)
    results = {}
    for name, expected in baseline['contracts'].items():
        built = artifact(name, root)
        results[name] = {}
        for part in ('bytecode', 'deployedBytecode'):
            code = bytes.fromhex(built[part]['object'][2:])
            if sha256(code) != expected[part]['sha256'] or len(code) != expected[part]['bytes']:
                raise StoreError('pinned bytecode changed: ' + name + '/' + part)
            results[name][part] = {'sha256': sha256(code), 'bytes': len(code)}
        # AST IDs can shift when a test is added; the byte locations must not shift.
        spans = lambda refs: sorted((x['start'], x['length']) for v in refs.values() for x in v)
        if spans(built['deployedBytecode'].get('immutableReferences', {})) != spans(expected['immutableReferences']):
            raise StoreError('immutable reference map changed: ' + name)
    return {'sourceCommit': baseline['sourceCommit'], 'baseCommit': baseline['baseCommit'],
            'status': 'unchanged', 'auditStatus': 'not-audited', 'contracts': results}


def config(value, *, require_owner=False):
    if not isinstance(value, dict) or set(value) - CONFIG_KEYS or type(value.get('version')) is not int or value['version'] != 1:
        raise StoreError('invalid deployment config fields/version')
    manifest = load_json(MANIFEST)
    if value.get('profile') not in manifest['profiles']:
        raise StoreError('unknown profile; Base has no supported paid Intake profile')
    result = dict(value)
    result['network'] = dict(manifest['profiles'][value['profile']])
    if value['profile'] == 'local':
        p = value.get('localProtocol')
        if not isinstance(p, dict) or set(p) != {'intake', 'asset', 'oracleSigner'}:
            raise StoreError('local fixture must supply its deployed protocol addresses')
        result['network'].update(p)
    elif 'localProtocol' in value:
        raise StoreError('local protocol overrides are forbidden on public profiles')
    for field in ('intake', 'asset', 'oracleSigner'):
        result['network'][field] = address(result['network'][field], field)
    result['maxPrice'] = _decimal(value.get('maxPrice'), 256, 'maxPrice')
    for field in ('jobTimeout', 'reviewTimeout'):
        if type(value.get(field)) is not int or not 3600 <= value[field] <= 30 * 86400:
            raise StoreError(field + ' must be 1 hour to 30 days')
    result['adProceedsRecipient'] = address(value.get('adProceedsRecipient'), 'adProceedsRecipient')
    if result['adProceedsRecipient'] == INTAKE_PAYEE:
        raise StoreError('Intake payee is not the advertising proceeds recipient')
    if value.get('owner') is not None:
        result['owner'] = address(value['owner'], 'owner')
        if result['owner'] in {INTAKE_PAYEE, *(result['network'][k] for k in ('intake', 'asset', 'oracleSigner'))}:
            raise StoreError('protocol authority/asset cannot be the launch owner')
    if require_owner:
        result['owner'] = address(value.get('owner'), 'owner')
        approval(value.get('ownerApproval'), result['owner'], 'ownerApproval')
    if value.get('templates') is not None:
        if value['profile'] == 'sepolia':
            raise StoreError('Sepolia is infrastructure only; job.open activation is unsupported')
        validate_templates(value['templates'], result['network']['chainId'], value.get('templateApproval'))
    return result


def names(c):
    return [x['contract'] for x in load_json(MANIFEST)['contracts']
            if 'onlyChainIds' not in x or c['network']['chainId'] in x['onlyChainIds']]


def validate_addresses(values, c, *, complete=False):
    if not isinstance(values, dict) or set(values) - set(names(c)):
        raise StoreError('unknown contract in deployed-address handoff; factory not supported on this chain')
    if complete and set(values) != set(names(c)):
        raise StoreError('complete confirmed deployment address handoff required')
    result = {n: address(v, n) for n, v in values.items()}
    if len(set(result.values())) != len(result):
        raise StoreError('deployment addresses must be distinct')
    return result


def constructor(c, name, deployed):
    if name not in names(c):
        raise StoreError('contract not supported on this chain: ' + name)
    entry = next(x for x in load_json(MANIFEST)['contracts'] if x['contract'] == name)
    values = {'$owner': c['owner'], '$maxPrice': c['maxPrice'],
              **{'$' + k: c['network'][k] for k in ('intake', 'asset', 'oracleSigner')},
              **{'$contract:' + k: v for k, v in deployed.items()}}
    try:
        args = [values.get(x, x) if not x.startswith('$contract:') else values[x] for x in entry['constructorArgs']]
    except KeyError as exc:
        raise StoreError('deploy registry first; supply its confirmed address, never a prediction guess') from exc
    built = artifact(name)
    actual_types = next((x['inputs'] for x in built['abi'] if x['type'] == 'constructor'), [])
    if [x['type'] for x in actual_types] != entry['constructorTypes'] or len(args) > 16:
        raise StoreError('manifest does not match constructor ABI')
    encoded = _cast('abi-encode', 'f(' + ','.join(entry['constructorTypes']) + ')', *args) if args else '0x'
    return args, encoded, built


def deployment_transaction(value, name, deployed=None):
    c = config(value, require_owner=True)
    verify_build()
    deployed = validate_addresses(deployed or {}, c)
    args, encoded, built = constructor(c, name, deployed)
    return {'kind': 'unsigned-creation', 'contract': name, 'constructorArgs': args,
            'constructorCalldata': encoded, 'requires': 'fresh preflight and separate wallet approval',
            'transaction': {'chainId': hex(c['network']['chainId']), 'value': '0x0',
                            'data': built['bytecode']['object'] + encoded[2:]}}


def encode(output_type, value):
    if output_type == 'bool':
        value = 'true' if value else 'false'
    return _cast('abi-encode', 'f(' + output_type + ')', str(value)).lower()


def read_check(target, signature, output_type, expected):
    return {'to': target, 'signature': signature, 'data': _cast('calldata', signature),
            'expected': encode(output_type, expected), 'displayExpected': expected}


def validate_templates(t, chain, approved):
    if not isinstance(t, dict) or set(t) != TEMPLATE_KEYS:
        raise StoreError('templates must contain exact bundle fields; see deployment runbook')
    for key in ('jobPrefix', 'jobMiddle', 'jobSuffix', 'reviewPrefix', 'reviewSuffix'):
        if not isinstance(t[key], str):
            raise StoreError('template fragments must be UTF-8 strings')
    if sum(len(t[k].encode()) for k in ('jobPrefix', 'jobMiddle', 'jobSuffix')) > 4096 or \
            len((t['reviewPrefix'] + t['reviewSuffix']).encode()) > 4096:
        raise StoreError('template exceeds onchain length limit')
    for marker in ('forge build', 'forge test', 'adversarial review'):
        if not any(marker in t[k] for k in ('jobPrefix', 'jobMiddle', 'jobSuffix')):
            raise StoreError('template lacks a whole required marker: ' + marker)
    if type(t['minPanelSize']) is not int or type(t['minAgreed']) is not int or \
            not 2 <= t['minPanelSize'] <= 100 or not 1 <= t['minAgreed'] <= t['minPanelSize']:
        raise StoreError('invalid panel minimums')
    spec = _hex(t['sampleSpecHash'], 32, 'sampleSpecHash')
    job_id = _hex(t['sampleJobId'], 32, 'sampleJobId')
    if int(spec, 16) == 0 or int(job_id, 16) == 0:
        raise StoreError('sample spec/job IDs must be real inputs, not zero placeholders')
    brief = t['sampleBrief']
    if not isinstance(brief, str) or not 1 <= len(brief.encode()) <= 2000 or re.search(r'["\\<>\x00-\x1f\x7f]', brief):
        raise StoreError('sample brief is not accepted by the requester')
    try:
        job = json.loads(t['jobPrefix'] + spec + t['jobMiddle'] + brief + t['jobSuffix'], object_pairs_hook=_unique_object)
        review = json.loads(t['reviewPrefix'] + job_id + t['reviewSuffix'], object_pairs_hook=_unique_object)
    except (ValueError, TypeError) as exc:
        raise StoreError('assembled template is invalid JSON') from exc
    if not isinstance(job, dict) or 'objective' not in job or 'onchain' in job:
        raise StoreError('job body needs objective and must not launch a token/pool')
    # Legacy v/kind/repository job bodies are not the official paid schema.
    if any(k in job for k in ('v', 'kind', 'repository', 'specHash', 'request')):
        raise StoreError('old local job fixture is not the official paid body schema')
    if not isinstance(review, dict) or review.get('chainId') != chain or review.get('answerType') != 'bool' or \
            not isinstance(review.get('question'), str) or job_id not in review['question']:
        raise StoreError('review must ask about this job on this chain with a bool answer')
    if type(review.get('panelSize')) is not int or type(review.get('quorum')) is not int or \
            not t['minPanelSize'] <= review['panelSize'] <= 100 or \
            not t['minAgreed'] <= review['quorum'] <= review['panelSize']:
        raise StoreError('review body panel/quorum conflicts with configured minimums')
    if not isinstance(t['checks'], dict) or set(t['checks']) != {'job.open', 'oracle.request'}:
        raise StoreError('both free body-check results are required')
    for action, body in (('job.open', job), ('oracle.request', review)):
        checked = t['checks'][action]
        if not isinstance(checked, dict) or checked.get('inputSha256') != sha256(canonical(body)) or \
                checked.get('response', {}).get('action') != action or checked['response'].get('blockers') != [] or \
                not isinstance(checked.get('reference'), str) or not checked['reference'].strip():
            raise StoreError('free body-check result missing, stale or blocked: ' + action)
        if action == 'oracle.request' and checked['response'].get('request') != body:
            raise StoreError('free oracle checker draft differs from the assembled body')
    digest = sha256(canonical(t))
    if not isinstance(approved, dict) or approved.get('sha256') != digest or not approved.get('reference'):
        raise StoreError('templateApproval must approve the exact bundle SHA-256 and evidence')
    return {'job.open': job, 'oracle.request': review}


def protocol_preflight(value, rpc):
    c = config(value)
    n = c['network']
    if int(rpc.request('eth_chainId', []), 16) != n['chainId']:
        raise StoreError('RPC chain mismatch')
    evidence = {'chainId': n['chainId'], 'block': rpc.block, 'profile': value['profile'],
                'evidenceKind': 'local-mocks' if n['chainId'] == 31337 else 'live-read-only',
                'codeHashes': {}, 'prices': {}, 'paidPilotReady': False}
    for field in ('intake', 'asset', 'oracleSigner'):
        code = rpc.code(n[field])
        if not re.fullmatch(r'0x(?:[0-9a-fA-F]{2})*', code) or (code == '0x' and field != 'oracleSigner'):
            raise StoreError('no deployed code for ' + field)
        evidence['codeHashes'][field] = keccak_hex(code)
        observed = n.get('observedCodeHashes', {}).get(field)
        if observed is not None and evidence['codeHashes'][field] != observed:
            raise StoreError('protocol code changed since first-party observation; review required: ' + field)
    if rpc.call(n['asset'], 'decimals()').lower() != encode('uint256', 18):
        raise StoreError('asset must have 18 decimals')
    # Balance ABI is also a constructor-independent check, matching configureToken's checks.
    if not re.fullmatch(r'0x[0-9a-fA-F]{64}', rpc.call(n['asset'], 'balanceOf(address)', n['intake'])):
        raise StoreError('invalid asset balance ABI')
    for action, action_id in load_json(MANIFEST)['actions'].items():
        raw = rpc.call(n['intake'], 'priceOf(bytes32,address)', action_id, n['asset'])
        price = int(_hex(raw, 32, 'priceOf response'), 16)
        evidence['prices'][action] = str(price)
        if value['profile'] != 'sepolia' or action == 'oracle.request':
            if price == 0 or price > int(c['maxPrice']):
                raise StoreError('action unsold or above owner ceiling: ' + action)
        elif price != 0:
            raise StoreError('Sepolia capability changed; review official support before enabling jobs')
    if value['profile'] == 'sepolia':
        evidence['limitation'] = 'infrastructure only; no job.open; capabilities/docs discrepancy remains'
    else:
        evidence['limitation'] = 'prices/code alone do not prove writer, oracle binding or signer gas'
    return evidence


def expected_runtime(name, c, addresses):
    """Fill every immutable, then compare the ENTIRE runtime; do not mask unchecked bytes."""
    built = artifact(name)
    runtime = bytearray.fromhex(built['deployedBytecode']['object'][2:])
    refs = built['deployedBytecode'].get('immutableReferences', {})
    keys = sorted(refs, key=int)
    if name == 'FeaturedPlacements':
        values = [encode('address', addresses['HookListingRegistry'])]
    elif name == 'HookJobRequester':
        hash_name = keccak_hex('IdentityMD Oracle')
        hash_version = keccak_hex('2')
        type_hash = keccak_hex('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)')
        separator = keccak_hex(_cast('abi-encode', 'f(bytes32,bytes32,bytes32,uint256,address)', type_hash,
                                   hash_name, hash_version, str(c['network']['chainId']), addresses[name]))
        short = lambda text: '0x' + text.encode().hex().ljust(62, '0') + f'{len(text.encode()):02x}'
        # Declaration order in the pinned OpenZeppelin EIP712.sol; AST ID ordering follows it.
        values = [separator, encode('uint256', c['network']['chainId']), encode('address', addresses[name]),
                  hash_name, hash_version, short('IdentityMD Oracle'), short('2')]
    else:
        values = []
    if len(keys) != len(values):
        raise StoreError('unexpected immutable layout: ' + name)
    for key, value in zip(keys, values):
        for span in refs[key]:
            if span['length'] != 32:
                raise StoreError('unexpected immutable word width')
            runtime[span['start']:span['start'] + 32] = bytes.fromhex(value[2:])
    return '0x' + runtime.hex()


def base_readbacks(c, addresses):
    ads, req = addresses['FeaturedPlacements'], addresses['HookJobRequester']
    reads = []
    for target in (ads, req):
        reads += [read_check(target, 'owner()', 'address', c['owner']),
                  {'to': target, 'signature': 'pendingOwner()', 'data': _cast('calldata', 'pendingOwner()'),
                   'expected': ZERO_WORD, 'displayExpected': 'unset (no pending ownership transfer)'}]
    for sig, typ, value in [('registry()', 'address', addresses['HookListingRegistry']),
                            ('PRICE()', 'uint256', '100000000000000000'), ('DURATION()', 'uint256', '604800')]:
        reads.append(read_check(ads, sig, typ, value))
    for sig, typ, value in [('intake()', 'address', c['network']['intake']), ('asset()', 'address', c['network']['asset']),
                            ('oracleSigner()', 'address', c['network']['oracleSigner']), ('maxPrice()', 'uint256', c['maxPrice'])]:
        reads.append(read_check(req, sig, typ, value))
    if 'HooksStoreFactory' in addresses:
        reads.append(read_check(addresses['HooksStoreFactory'], 'runtimeCodeHash()', 'bytes32',
                                keccak_hex(artifact('BoundedSwapHook')['deployedBytecode']['object'])))
    # Verify the ABI domain as well as every immutable byte used in the actual digest path.
    domain = _cast('abi-encode', 'f(bytes1,string,string,uint256,address,bytes32,uint256[])', '0x0f',
                   'IdentityMD Oracle', '2', str(c['network']['chainId']), req, ZERO_WORD, '[]')
    reads.append({'to': req, 'signature': 'eip712Domain()', 'data': _cast('calldata', 'eip712Domain()'),
                  'expected': domain.lower(), 'displayExpected': 'IdentityMD Oracle v2; this chain and requester'})
    return reads


def desired_settings(c, addresses):
    ads, req = addresses['FeaturedPlacements'], addresses['HookJobRequester']
    actions = load_json(MANIFEST)['actions']
    settings = [
        (ads, 'configureToken(address)', [c['network']['asset']], [('imd()', 'address', c['network']['asset'])]),
        (ads, 'setProceedsRecipient(address)', [c['adProceedsRecipient']], [('proceedsRecipient()', 'address', c['adProceedsRecipient'])]),
        (req, 'setFailureHook(bool)', ['true'], [('failureHook()', 'bool', True)]),
        (req, 'setTimeouts(uint64,uint64)', [str(c['jobTimeout']), str(c['reviewTimeout'])],
         [('jobTimeout()', 'uint64', c['jobTimeout']), ('reviewTimeout()', 'uint64', c['reviewTimeout'])])]
    t = c.get('templates')
    if t is not None:
        h = lambda k: '0x' + t[k].encode().hex()
        settings += [
            (req, 'setJobTemplate(bytes32,bytes,bytes,bytes)',
             [actions['job.open'], h('jobPrefix'), h('jobMiddle'), h('jobSuffix')],
             [('jobAction()', 'bytes32', actions['job.open']), ('jobBodyPrefix()', 'bytes', h('jobPrefix')),
              ('jobBodyMiddle()', 'bytes', h('jobMiddle')), ('jobBodySuffix()', 'bytes', h('jobSuffix'))]),
            (req, 'setReviewTemplate(bytes32,bytes,bytes,uint16,uint16)',
             [actions['oracle.request'], h('reviewPrefix'), h('reviewSuffix'), str(t['minPanelSize']), str(t['minAgreed'])],
             [('reviewAction()', 'bytes32', actions['oracle.request']), ('reviewBodyPrefix()', 'bytes', h('reviewPrefix')),
              ('reviewBodySuffix()', 'bytes', h('reviewSuffix')), ('minPanelSize()', 'uint16', t['minPanelSize']),
              ('minAgreed()', 'uint16', t['minAgreed'])])]
    return settings


def read(rpc, check):
    return rpc.request('eth_call', [{'to': check['to'], 'data': check['data']}, rpc.block]).lower()


def check_deployed(c, addresses, rpc):
    for name, target in addresses.items():
        if rpc.code(target) != expected_runtime(name, c, addresses):
            raise StoreError('deployed runtime/immutables differ: ' + name)
    for check in base_readbacks(c, addresses):
        if read(rpc, check) != check['expected']:
            raise StoreError('state readback mismatch: ' + check['signature'])


def configuration_plan(value, addresses, rpc):
    c = config(value, require_owner=True)
    approval(c.get('recipientApproval'), c['adProceedsRecipient'], 'recipientApproval')
    verify_build()
    addresses = validate_addresses(addresses, c, complete=True)
    if c['owner'] in addresses.values() or c['adProceedsRecipient'] == addresses['FeaturedPlacements']:
        raise StoreError('owner/recipient must not be an application contract')
    evidence = protocol_preflight(value, rpc)
    check_deployed(c, addresses, rpc)
    checks = base_readbacks(c, addresses)
    txs = []
    for target, signature, args, states in desired_settings(c, addresses):
        after = [read_check(target, sig, typ, val) for sig, typ, val in states]
        checks += after
        actual = [read(rpc, x) for x in after]
        if actual == [x['expected'] for x in after]:
            continue
        if signature == 'configureToken(address)' and actual[0] != ZERO_WORD:
            raise StoreError('immutable token configuration conflicts; never replace backing asset')
        if signature.startswith(('setJobTemplate(', 'setReviewTemplate(')) and actual[0] != ZERO_WORD:
            raise StoreError('existing template differs; this bootstrap tool will not rotate pending work')
        data = _cast('calldata', signature, *args)
        tx = {'chainId': hex(c['network']['chainId']), 'from': c['owner'], 'to': target, 'value': '0x0', 'data': data}
        # Simulate each independent setter with the intended owner, at exactly the read snapshot.
        rpc.request('eth_call', [{k: v for k, v in tx.items() if k != 'chainId'}, rpc.block])
        txs.append({'signature': signature, 'args': args, 'transaction': tx, 'readback': after})
    if c.get('templates') is None:
        for signature in ('jobAction()', 'reviewAction()'):
            check = read_check(addresses['HookJobRequester'], signature, 'bytes32', ZERO_WORD)
            if read(rpc, check) != ZERO_WORD:
                raise StoreError('expected requester disabled but template is configured')
            checks.append(check)
    return {'format': 'hooks-store-unsigned-owner-calls/v1', 'chainId': c['network']['chainId'],
            'snapshotBlock': rpc.block, 'configSha256': sha256(canonical(value)), 'addresses': addresses,
            'requires': 'separate owner wallet execution; launcher calls no setters; refresh after each receipt',
            'readiness': 'configured infrastructure only' if c.get('templates') is None else 'pilot configuration; live evidence still required',
            'protocol': evidence, 'transactions': txs, 'readbacks': checks}


def verify_configuration(value, addresses, rpc):
    """Recompute expected state from approved inputs, never trust a caller-edited plan."""
    c = config(value, require_owner=True)
    approval(c.get('recipientApproval'), c['adProceedsRecipient'], 'recipientApproval')
    verify_build()
    addresses = validate_addresses(addresses, c, complete=True)
    evidence = protocol_preflight(value, rpc)
    check_deployed(c, addresses, rpc)
    checks = base_readbacks(c, addresses)
    for target, _, _, states in desired_settings(c, addresses):
        checks += [read_check(target, sig, typ, val) for sig, typ, val in states]
    if c.get('templates') is None:
        checks += [read_check(addresses['HookJobRequester'], sig, 'bytes32', ZERO_WORD)
                   for sig in ('jobAction()', 'reviewAction()')]
    for check in checks:
        if read(rpc, check) != check['expected']:
            raise StoreError('state readback mismatch: ' + check['signature'])
    return {'status': 'configuration-matches', 'chainId': c['network']['chainId'], 'block': rpc.block,
            'checks': len(checks), 'codeAndImmutables': 'exact match', 'protocol': evidence,
            'paidPilotProven': False}
