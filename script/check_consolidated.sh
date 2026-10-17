#!/usr/bin/env bash
# Local checks only. Never contacts a public RPC or submits a paid request.
set -euo pipefail
forge fmt --check
forge build
forge test
forge test --fuzz-seed 0x40bbcf769875f858aac6849e21037c680c23d3811f18267f1b80562a06409c89
forge test --isolate --match-contract 'ReviewReceiptGasTest|JobProtocolGasTest' -vv
forge test --match-path test/ParserGas.t.sol --match-test 'testMaximum|testWorst|testLimits' -vv
python3 -m unittest discover -s test -p 'test_*.py'
node --test test/*.test.cjs
