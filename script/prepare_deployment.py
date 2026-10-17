#!/usr/bin/env python3
"""Read-only deployment preparation CLI; deliberately has no submit/broadcast command."""
import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from sdk.hooks_store import Rpc, StoreError, load_json
from sdk.deployment import (MANIFEST, CurlRpc, config, names, verify_build, protocol_preflight,
                            deployment_transaction, configuration_plan, verify_configuration)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['manifest', 'verify-build', 'preflight', 'creation', 'configure', 'verify'])
    parser.add_argument('--config', help='explicit operator config JSON; never an environment file')
    parser.add_argument('--addresses', help='confirmed deployed addresses keyed by Solidity contract name')
    parser.add_argument('--contract', help='contract to prepare for creation')
    parser.add_argument('--rpc', help='read-only HTTP(S) endpoint; never printed into output')
    parser.add_argument('--transport', choices=['direct', 'curl'], default='direct', help='curl is opt-in proxy-compatible transport')
    parser.add_argument('--output', help='JSON output path; defaults to stdout')
    args = parser.parse_args()
    try:
        if args.command == 'manifest':
            result = load_json(MANIFEST)
            if args.config:
                c = config(load_json(args.config))
                result['selectedContracts'] = names(c)
                result['selectedProfile'] = args.config
        elif args.command == 'verify-build':
            result = verify_build()
        else:
            if not args.config:
                parser.error('--config is required')
            value = load_json(args.config)
            addresses = load_json(args.addresses) if args.addresses else {}
            if args.command == 'creation':
                if not args.contract:
                    parser.error('--contract is required for creation')
                result = deployment_transaction(value, args.contract, addresses)
            else:
                if not args.rpc:
                    parser.error('--rpc is required for read-only checks')
                rpc = (CurlRpc if args.transport == 'curl' else Rpc)(args.rpc)
                if args.command == 'preflight':
                    verify_build()
                    result = protocol_preflight(value, rpc)
                elif args.command == 'configure':
                    result = configuration_plan(value, addresses, rpc)
                else:
                    result = verify_configuration(value, addresses, rpc)
        output = json.dumps(result, indent=2, ensure_ascii=True) + '\n'
        if args.output:
            Path(args.output).write_text(output)
        else:
            print(output, end='')
    except (StoreError, OSError, ValueError, KeyError, TypeError):
        # Avoid paths/URLs or arbitrary config data in unexpected exceptions.
        exc = sys.exc_info()[1]
        print(str(exc) if isinstance(exc, StoreError) else 'invalid input, missing file or malformed artifact', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
