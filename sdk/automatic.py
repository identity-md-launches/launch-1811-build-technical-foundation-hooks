"""Unsigned automatic Hooks Store workflow. Python stdlib + Foundry cast, no signer/backend.

Approval + openJob prepay both fees. After Delivered, the requester commits one reviewed candidate.
Anyone can then trigger requestVerdict(askId), paying gas only. Deployment uses sdk.gated_deploy.
An expired unspent verdict window can be renewed without transferring tokens or creating an ask.
Top-ups produce separate bounded approval and funding transactions using the job's original asset.
"""
import argparse
import json
from sdk.hooks_store import Rpc, StoreError, _cast, _hex, abi_tuple, normalize_spec, TYPE, load_json, keccak_hex
from sdk.gated_deploy import ARTIFACT, artifact_tuple


def positive(value, field):
    if type(value) is not int or value <= 0 or value >= 1 << 256:
        raise StoreError(field + ' must be a positive uint256 in token base units')
    return value


class AutomaticClient:
    def __init__(self, rpc, requester):
        self.rpc = rpc
        self.requester = _hex(requester, 20, 'requester')
        if int(rpc.call(self.requester, 'automaticBindingSupported()(bool)'), 16) != 1:
            raise StoreError('automatic requester required')

    def transaction(self, sender, signature, *values):
        return {'chainId': int(self.rpc.request('eth_chainId', []), 16),
                'from': _hex(sender, 20, 'sender'), 'to': self.requester, 'value': '0x0',
                'data': _cast('calldata', signature, *values)}

    def open_job(self, *, sender, spec, deployer, brief, max_build_fee, verdict_reserve):
        spec = normalize_spec(spec)
        if int(self.rpc.request('eth_chainId', []), 16) != int(spec['chainId']):
            raise StoreError('RPC chain differs from HookSpec')
        # The consumer validates clock semantics before taking any build payment.
        self.rpc.call(self.requester, 'head()(uint64)')
        if not isinstance(brief, str) or not 1 <= len(brief.encode('utf-8')) <= 2000 or any(c in brief for c in '\\"<>') or any(ord(c) < 32 or ord(c) == 127 for c in brief):
            raise StoreError('brief must be bounded UTF-8 without JSON/control/delimiter characters')
        deployer = _hex(deployer, 20, 'deployer')
        if self.rpc.call(deployer, 'requester()(address)').lower()[-40:] != self.requester[2:]:
            raise StoreError('deployer uses another requester')
        positive(max_build_fee, 'max build fee'); positive(verdict_reserve, 'verdict reserve')
        manager_code = self.rpc.code(spec['poolManager'])
        if manager_code == '0x' or keccak_hex(manager_code) != spec['poolManagerCodeHash']:
            raise StoreError('PoolManager code does not match HookSpec')
        token = '0x' + self.rpc.call(self.requester, 'asset()(address)')[-40:]
        intake = '0x' + self.rpc.call(self.requester, 'intake()(address)')[-40:]
        action = self.rpc.call(self.requester, 'jobAction()(bytes32)')
        price = int(self.rpc.call(intake, 'priceOf(bytes32,address)(uint256)', action, token), 16)
        if price == 0 or price > max_build_fee:
            raise StoreError('build price unavailable or above user cap')
        cap = int(self.rpc.call(self.requester, 'maxPrice()(uint256)'), 16)
        review_action = self.rpc.call(self.requester, 'reviewAction()(bytes32)')
        verdict_price = int(self.rpc.call(intake, 'priceOf(bytes32,address)(uint256)', review_action, token), 16)
        if price > cap or verdict_reserve > cap or verdict_price == 0 or verdict_price > verdict_reserve:
            raise StoreError('build or verdict fee unavailable or above prepaid caps')
        approval = self.transaction(sender, 'approve(address,uint256)', self.requester, str(price + verdict_reserve))
        approval['to'] = token
        tx = self.transaction(sender, 'openJob(' + TYPE + ',address,bytes,uint256,uint256)',
                              abi_tuple(spec), deployer, '0x' + brief.encode().hex(), str(max_build_fee), str(verdict_reserve))
        return {'unsigned': True, 'approvalTransaction': approval, 'transaction': tx,
                'prepayment': price + verdict_reserve,
                'next': 'Wait for Delivered, inspect the accepted build/review, then commitArtifact once.'}

    def commit_artifact(self, *, sender, job, artifact, reviewed_commit):
        reviewed_commit = _hex(reviewed_commit, 20, 'reviewed git commit')
        job = _hex(job, 32, 'job')
        if int(reviewed_commit, 16) == 0 or artifact['jobRequestId'].lower() != job:
            raise StoreError('nonzero reviewed commit and matching job required')
        raw = _hex(self.rpc.call(self.requester, 'getJob(bytes32)', job), 480, 'job response')
        if int(raw[2+3*64:2+4*64], 16) != 2:
            raise StoreError('job must be Delivered before committing an artifact')
        if raw[26:66] != _hex(sender, 20, 'sender')[2:]:
            raise StoreError('only the job requester can commit an artifact')
        if self.reserve_status(job)['cancelled']:
            raise StoreError('cancelled reserve cannot be revived')
        return self.transaction(sender, 'commitArtifact(bytes32,' + ARTIFACT + ',bytes20)',
                                job, artifact_tuple(artifact), reviewed_commit)

    def reserve_status(self, job):
        job = _hex(job, 32, 'job')
        raw = _hex(self.rpc.call(self.requester, 'reserveOf(bytes32)(address,uint256,bool)', job), 96, 'reserve response')
        words = [raw[2+i*64:2+(i+1)*64] for i in range(3)]
        deadline = int(_hex(self.rpc.call(self.requester, 'reserveDeadline(bytes32)(uint64)', job), 32, 'reserve deadline'), 16)
        if int(words[0], 16) >= 1 << 160 or int(words[2], 16) not in (0, 1) or deadline >= 1 << 64:
            raise StoreError('malformed reserve response')
        return {'token': '0x' + words[0][-40:], 'amount': int(words[1], 16),
                'cancelled': bool(int(words[2], 16)), 'reserveDeadline': deadline}

    def renew_verdict(self, *, sender, job):
        tx = self.transaction(sender, 'renewVerdict(bytes32)', _hex(job, 32, 'job'))
        # Simulate as the requester at the pinned read block. No token approval, signing or send.
        self.rpc.request('eth_call', [{k: tx[k] for k in ('from', 'to', 'data', 'value')}, self.rpc.block])
        return tx

    def top_up_reserve(self, *, sender, job, amount):
        job = _hex(job, 32, 'job')
        amount = positive(amount, 'top-up amount')
        raw = _hex(self.rpc.call(self.requester, 'getJob(bytes32)', job), 480, 'job response')
        fields = [raw[2+i*64:2+(i+1)*64] for i in range(15)]
        if fields[0] != _hex(sender, 20, 'sender')[2:].rjust(64, '0'):
            raise StoreError('only the job requester can top up')
        if int(fields[3], 16) != 2 or int(fields[4], 16) != 0:
            raise StoreError('top-up requires Delivered with review None')
        reserve = self.reserve_status(job)
        if reserve['cancelled']:
            raise StoreError('cancelled reserve cannot be revived')
        digest = _hex(self.rpc.call(self.requester, 'candidateDigest(bytes32)(bytes32)', job), 32, 'candidate digest')
        if int(digest, 16) == 0:
            raise StoreError('commit an artifact before topping up')
        ask = _hex(self.rpc.call(self.requester, 'jobAsk(bytes32)(bytes32)', job), 32, 'ask')
        context = _hex(self.rpc.call(self.requester, 'getAsk(bytes32)', ask), 288, 'ask response')
        if int(context[66:130], 16) != 0:
            raise StoreError('top-up requires an unspent ask')
        cap = int(_hex(self.rpc.call(self.requester, 'maxPrice()(uint256)'), 32, 'maximum price'), 16)
        if reserve['amount'] + amount > cap:
            raise StoreError('total reserve exceeds current maxPrice')
        self.rpc.call(self.requester, 'head()(uint64)')
        approval = self.transaction(sender, 'approve(address,uint256)', self.requester, str(amount))
        approval['to'] = reserve['token']
        return {'unsigned': True, 'approvalTransaction': approval,
                'transaction': self.transaction(sender, 'topUpReserve(bytes32,uint256)', job, str(amount)),
                'job': job, 'ask': ask, 'token': reserve['token'], 'amount': amount,
                'reserveBefore': reserve['amount'], 'reserveAfter': reserve['amount'] + amount,
                'next': 'Submit approval and top-up separately, then refresh reserve/status. Wait eight native blocks.'}

    def verdict_funding(self, ask):
        ask = _hex(ask, 32, 'ask')
        try:
            raw = _hex(self.rpc.call(self.requester, 'verdictFunding(bytes32)(uint256,uint256,address)', ask),
                       96, 'verdict funding')
            price, reserve, token = [int(raw[2+i*64:2+(i+1)*64], 16) for i in range(3)]
            if token == 0 or token >= 1 << 160:
                raise StoreError('malformed funding token')
            return {'available': True, 'funded': 0 < price <= reserve, 'price': price,
                    'reserve': reserve, 'token': '0x' + f'{token:040x}'}
        except (StoreError, OSError, ValueError) as exc:
            return {'available': False, 'funded': False, 'error': str(exc)}

    def verdict_readiness(self, ask):
        ask = _hex(ask, 32, 'ask')
        raw = self.rpc.call(self.requester, 'verdictReadiness(bytes32)(bool,uint64,uint64,uint64)', ask)
        words = _hex(raw, 128, 'verdict readiness')
        ready, head, start, end = [int(words[2+i*64:2+(i+1)*64], 16) for i in range(4)]
        if ready not in (0, 1) or max(head, start, end) >= 1 << 64:
            raise StoreError('malformed verdict readiness')
        depth = int(self.rpc.call(self.requester, 'WINDOW_DEPTH()(uint64)'), 16)
        funding = self.verdict_funding(ask)
        return {'ready': bool(ready) and funding['funded'], 'phaseReady': bool(ready), 'funding': funding,
                'nativeHead': head, 'fromBlock': start, 'toBlock': end,
                'windowDepth': depth, 'blocksRemaining': max(0, start + depth - head),
                'note': 'Snapshot only; refresh after transactions. A positive live quote within reserve is required; prices can change before inclusion.'}

    def request_verdict(self, *, sender, ask):
        # Deliberately no artifact, question, prefix, fee or recipient argument.
        readiness = self.verdict_readiness(ask)
        if not readiness['ready']:
            raise StoreError('verdict not ready; native blocks remaining: ' + str(readiness['blocksRemaining']) +
                             '; delivery, candidate, active reserve, deadline and an affordable positive quote are required')
        return self.transaction(sender, 'requestVerdict(bytes32)', _hex(ask, 32, 'ask'))

    def retry_verdict(self, *, sender, job, reserve):
        self.rpc.call(self.requester, 'head()(uint64)')
        return self.transaction(sender, 'retryVerdict(bytes32,uint256)', _hex(job, 32, 'job'), str(positive(reserve, 'reserve')))

    def withdraw_refund(self, *, sender, token):
        return self.transaction(sender, 'withdrawRefund(address)', _hex(token, 20, 'token'))


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--rpc', required=True); p.add_argument('--requester', required=True); p.add_argument('--sender', required=True)
    sub = p.add_subparsers(dest='command', required=True)
    o = sub.add_parser('open'); o.add_argument('spec'); o.add_argument('--deployer', required=True); o.add_argument('--brief', required=True)
    o.add_argument('--max-build-fee', type=int, required=True); o.add_argument('--verdict-reserve', type=int, required=True)
    c = sub.add_parser('commit'); c.add_argument('artifact'); c.add_argument('--reviewed-commit', required=True)
    v = sub.add_parser('verdict'); v.add_argument('ask')
    s = sub.add_parser('status'); s.add_argument('ask')
    r = sub.add_parser('retry'); r.add_argument('job'); r.add_argument('--reserve', type=int, required=True)
    n = sub.add_parser('renew'); n.add_argument('job')
    t = sub.add_parser('top-up'); t.add_argument('job'); t.add_argument('--amount', type=int, required=True)
    d = sub.add_parser('reserve'); d.add_argument('job')
    w = sub.add_parser('withdraw'); w.add_argument('token')
    args = p.parse_args()
    try:
        client = AutomaticClient(Rpc(args.rpc), args.requester)
        if args.command == 'open': out = client.open_job(sender=args.sender, spec=load_json(args.spec), deployer=args.deployer, brief=args.brief, max_build_fee=args.max_build_fee, verdict_reserve=args.verdict_reserve)
        elif args.command == 'commit':
            artifact = load_json(args.artifact)
            out = client.commit_artifact(sender=args.sender, job=artifact['jobRequestId'], artifact=artifact, reviewed_commit=args.reviewed_commit)
        elif args.command == 'verdict': out = client.request_verdict(sender=args.sender, ask=args.ask)
        elif args.command == 'status': out = client.verdict_readiness(args.ask)
        elif args.command == 'retry': out = client.retry_verdict(sender=args.sender, job=args.job, reserve=args.reserve)
        elif args.command == 'renew': out = client.renew_verdict(sender=args.sender, job=args.job)
        elif args.command == 'top-up': out = client.top_up_reserve(sender=args.sender, job=args.job, amount=args.amount)
        elif args.command == 'reserve': out = client.reserve_status(args.job)
        else: out = client.withdraw_refund(sender=args.sender, token=args.token)
        print(json.dumps(out, indent=2))
    except (StoreError, OSError, KeyError, ValueError) as exc:
        p.exit(2, str(exc) + '\n')


if __name__ == '__main__': main()
