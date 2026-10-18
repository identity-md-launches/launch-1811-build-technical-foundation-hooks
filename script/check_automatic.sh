#!/usr/bin/env bash
# Offline checks only: never contacts a public RPC or admits paid work.
set -euo pipefail
forge build
forge fmt --check
forge test
forge test --fuzz-seed 0x1cce11b977345bde5d2e8864effc5b353b22f85c7b0d962b70d90077d67f4205
forge test --isolate --match-contract 'AutomaticGasTest|ReviewReceiptGasTest|JobProtocolGasTest' -vv
python3 -m unittest discover -s test -p 'test_*.py'
node --test test/*.test.cjs
python3 script/check_automatic_vectors.py
sh script/verify-vendored.sh
