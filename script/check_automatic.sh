#!/usr/bin/env bash
# Offline checks only: never contacts a public RPC or admits paid work.
set -euo pipefail
forge build
forge fmt --check
forge test
forge test --fuzz-seed 0xe1cee08ccc29120111028768a3aec176c1fef4b508e16a2c358555bd62e98669
forge test --isolate --match-contract 'AutomaticGasTest|ReviewReceiptGasTest|JobProtocolGasTest' -vv
python3 -m unittest discover -s test -p 'test_*.py'
node --test test/*.test.cjs
python3 script/check_automatic_vectors.py
sh script/verify-vendored.sh
