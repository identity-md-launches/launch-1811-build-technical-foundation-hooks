# Local verification

The following checks completed locally with the pinned Solidity 0.8.26 compiler and the fuzz seed in `foundry.toml`:

| Check | Result |
|---|---|
| `forge build` | Pass |
| `forge build --force --offline` | Pass; fresh compilation of 81 source files, with recorded build fingerprints unchanged |
| `forge build --sizes` | Pass; hook runtime 3,431 bytes, factory runtime 13,879 bytes, both below the 24,576-byte deployment limit |
| `forge test` | 39 tests pass: 25 deployment/spec tests and 14 hook/pool tests; 7 fuzz tests, 256 cases each |
| `forge fmt --check` | Pass |
| `python3 -m unittest discover -s test -p 'test_*.py' -v` | 10 tests pass, including unsigned calldata submission and verification on disposable local Anvil |

The tests are delivered under `test/`, not the disposable scratch directory. Solidity test fixtures are reconstructed for each test. No test reads or sets environment variables. No fork, external RPC or funded wallet is required. All source dependencies are vendored; optional Python tests use only the standard library plus installed Foundry tools. The only lint warning is the generic post-call event warning discussed in the [threat model](THREAT_MODEL.md).

## What establishes the deployment claim

`testPredictionDeploymentPermissionsSettingsAndBytecodeAgree` independently concatenates the compiled creation code and ABI constructor tuple and recomputes the CREATE2 address using the actual factory. It checks the candidate has no code, deploys through CREATE2, then compares the actual address, **full runtime bytes**, all stored constructor settings, all fourteen declared permission flags, provenance mapping and event fields. Factory verification must return the identical plan. No address-forcing cheatcode participates in this success path.

`testScriptUsesSamePlanAndDeploymentAsStore` directly calls the script's preparation/execution functions with explicit configuration and checks the same plan and bytecode. The Python adapter test independently encodes the spec and CREATE2 preimage, calls the factory's miner, submits the emitted unsigned calldata to local Anvil, checks the receipt and verifies bytecode and constructor getters through RPC. The adapter's altered-plan and altered-transaction paths fail.

Negative deployment tests cover mismatched expected addresses and init hashes, changed constructor settings, invalid versions/templates/flags, missing manager code, changed code, wrong chains, invalid salts, duplicates, unregistered deployments, forged plans, search exhaustion and corrupted runtime/storage. `vm.etch` and `vm.store` occur only for deliberate corruption tests, never to create a supposedly valid hook address.

## What establishes reuse across new pools

`HookIntegrationTest.setUp` deploys a real vendored v4 PoolManager and one mined hook. It checks two distinct PoolIds have zero initial state and are unregistered in the hook, initializes both with that same hook, and adds liquidity. They use different currency pairs and fees. All setup is local and recreated per test.

`testTwoNewPoolsReuseOneDeployedHook` swaps across both pools and proves their counters are independent. The fuzz suite executes actual manager unlock/swap/settlement calls, checks exact input/output behavior and conservation of user-plus-manager token balances, and confirms the other pool's counter stays unchanged. Remaining tests cover both directions at the exact limit, over-limit failure, callback authorization, int256 extrema, disabled callbacks, dynamic fee rejection, unknown/duplicate pools and liquidity withdrawal after rejection. Failed settlement rolls back both the pool price change and hook counter, and a later properly settled swap succeeds.

## Reproducing evidence

Run the commands above from the repository root. For an inspectable deployment trace:

```sh
forge test --match-test testPredictionDeploymentPermissionsSettingsAndBytecodeAgree -vvvv
forge test --match-test testTwoNewPoolsReuseOneDeployedHook -vvvv
```

[build-fingerprints.json](build-fingerprints.json) records creation/runtime hashes for this build. Creation hashes there exclude constructor arguments; each plan's `initCodeHash` includes the full constructor ABI. The hashes are build fingerprints, not live chain evidence. `lib/SHA256SUMS` holds the *upstream* hashes, not the committed tree's; see [dependency provenance](DEPENDENCIES.md) and `script/verify-vendored.sh` for the corrected, verified evidence.

These are contributor self-check results, not independent verification or an audit. Live Ethereum, Base and Robinhood execution, public testnet deployments, production router/native currency/hostile token integrations, hosted wallet flows and external adversarial review remain untested. No claim of a working hosted deployment is based on IMD's checker.

## Follow-up (audit 0baee611 and IMD integration)

| Check | Result |
|---|---|
| `forge build` | Pass |
| `forge test` (also with `FOUNDRY_FUZZ_SEED=0x5f44…733b`) | 80 tests pass: 25 deployment, 15 hook/pool, 11 audit follow-up, 26 IMD requester, 3 oracle conformance |
| `forge fmt --check` | Pass |
| `sh script/verify-vendored.sh` | Pass: 96 files, 24 formatting-only differences from upstream |

The original 39 tests are unchanged and still pass. `AuditFixes.t.sol` covers:
- the 3 named mainnets and fuzzed unknown chains, on every release path: factory constructor, `deploy` with a matching spec, `DeployStore.run`, `DeployHook.prepare/execute/run`;
- end-to-end deploys on the allowed testnet ids, as local simulation;
- the chain-agnostic hook template;
- capped-gas mining.

The swap-limit decision is tested in `HookIntegration.t.sol`. `HookJobRequester.t.sol` and `OracleConformance.t.sol` cover the IMD flow against a mock Intake. These are self-checks, not an audit.
