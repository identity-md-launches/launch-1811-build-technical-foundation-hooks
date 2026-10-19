#!/usr/bin/env bash
# Offline checks only: never contacts a public RPC or admits paid work.
set -euo pipefail
forge build
forge fmt --check
forge test
forge test --fuzz-seed 0x570e3760c7b3cd25a809ed002933b826699ace6868976bebf2a57dafff68df81
forge test --isolate --match-contract 'AutomaticGasTest|ReviewReceiptGasTest|JobProtocolGasTest' -vv
python3 -m unittest discover -s test -p 'test_*.py'
node --test test/*.test.cjs
python3 script/check_automatic_vectors.py
sh script/verify-vendored.sh
