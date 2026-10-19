#!/usr/bin/env bash
# Offline checks only: never contacts a public RPC or admits paid work.
set -euo pipefail
forge build
forge fmt --check
forge test
forge test --fuzz-seed 0x496abaac78906e29834a9e8c6092ebc83fe50f2785c67161be04f9cee38e1ef2
forge test --isolate --match-contract 'AutomaticGasTest|ReviewReceiptGasTest|JobProtocolGasTest' -vv
python3 -m unittest discover -s test -p 'test_*.py'
node --test test/*.test.cjs
python3 script/check_automatic_vectors.py
sh script/verify-vendored.sh
