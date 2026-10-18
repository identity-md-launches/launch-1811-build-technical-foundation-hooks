"""Unsigned automatic Hooks Store workflow. Python stdlib + Foundry cast, no signer/backend.

Approval + openJob prepay both fees. The requester explicitly commits one reviewed candidate.
Anyone can then trigger requestVerdict(askId), paying gas only. Deployment uses sdk.gated_deploy.
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
                'next': 'Read JobOpened and jobAsk(jobId); inspect the accepted build/review, then commitArtifact once.'}

    def commit_artifact(self, *, sender, job, artifact, reviewed_commit):
        reviewed_commit = _hex(reviewed_commit, 20, 'reviewed git commit')
        job = _hex(job, 32, 'job')
        if int(reviewed_commit, 16) == 0 or artifact['jobRequestId'].lower() != job:
            raise StoreError('nonzero reviewed commit and matching job required')
        return self.transaction(sender, 'commitArtifact(bytes32,' + ARTIFACT + ',bytes20)',
                                job, artifact_tuple(artifact), reviewed_commit)

    def request_verdict(self, *, sender, ask):
        # Deliberately no artifact, question, prefix, fee or recipient argument.
        return self.transaction(sender, 'requestVerdict(bytes32)', _hex(ask, 32, 'ask'))

    def retry_verdict(self, *, sender, job, reserve):
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
    r = sub.add_parser('retry'); r.add_argument('job'); r.add_argument('--reserve', type=int, required=True)
    w = sub.add_parser('withdraw'); w.add_argument('token')
    args = p.parse_args()
    try:
        client = AutomaticClient(Rpc(args.rpc), args.requester)
        if args.command == 'open': out = client.open_job(sender=args.sender, spec=load_json(args.spec), deployer=args.deployer, brief=args.brief, max_build_fee=args.max_build_fee, verdict_reserve=args.verdict_reserve)
        elif args.command == 'commit':
            artifact = load_json(args.artifact)
            out = client.commit_artifact(sender=args.sender, job=artifact['jobRequestId'], artifact=artifact, reviewed_commit=args.reviewed_commit)
        elif args.command == 'verdict': out = client.request_verdict(sender=args.sender, ask=args.ask)
        elif args.command == 'retry': out = client.retry_verdict(sender=args.sender, job=args.job, reserve=args.reserve)
        else: out = client.withdraw_refund(sender=args.sender, token=args.token)
        print(json.dumps(out, indent=2))
    except (StoreError, OSError, KeyError, ValueError) as exc:
        p.exit(2, str(exc) + '\n')


if __name__ == '__main__': main()
