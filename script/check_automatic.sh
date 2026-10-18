#!/usr/bin/env bash
# Offline checks only: never contacts a public RPC or admits paid work.
set -euo pipefail
forge build
forge fmt --check
forge test
forge test --fuzz-seed 0x63141e4fb7e43e7da95e0ee07c1fb764e4512f7c4b40763dcc1324444f87f3de
forge test --isolate --match-contract 'AutomaticGasTest|ReviewReceiptGasTest|JobProtocolGasTest' -vv
python3 -m unittest discover -s test -p 'test_*.py'
node --test test/*.test.cjs
python3 script/check_automatic_vectors.py
sh script/verify-vendored.sh
