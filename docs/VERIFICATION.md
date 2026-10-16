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

## Follow-up (IMD requester hardening, job 17b4f2ef continuation)

| Check | Result |
|---|---|
| `forge build` | Pass |
| `forge test` (pinned seed, and `FOUNDRY_FUZZ_SEED=0x0a00…5885`) | 86 tests pass: 25 deployment, 15 hook/pool, 11 audit follow-up, 29 IMD requester, 3 oracle conformance, 3 requester deploy script |
| `forge fmt --check` | Pass |
| `sh script/verify-vendored.sh` | Pass: 96 files, 24 formatting-only differences from upstream |
| `python3 -m unittest discover -s test -p 'test_*.py'` | 10 tests pass against a disposable local Anvil |
| Static page RPC readback | The page's `eth_call` (`getJob`, `jobsOf`) and `eth_getLogs` calls replayed against a local Anvil after one job was opened, delivered and its review ask refused: 15 words, status Delivered, review Unanswered, one listed job, events in order |

The original 39 tests are unchanged. The 80 tests of the previous follow-up are kept, with the requester's constructor now taking `maxPrice` and `setAsset` replaced by `setPayment`. `HookJobRequester` gained a price ceiling, a version 1 fallback (`failureHook`) and a job/review id collision check; `build-fingerprints.json` records its new hashes. Nothing was broadcast to a public chain and no paid request was submitted.

## Follow-up: listing registry and featured ads

The original 86 Foundry tests and the Intake implementation remain unchanged. This follow-up adds
40 Foundry tests and a separate read-only listing page. It leaves build configuration, lockfiles,
remappings and vendored dependencies unchanged and adds no dependency.

| Check | Result |
|---|---|
| `forge build` | Pass, solc 0.8.26, original compiler settings |
| `forge test` | **126 passed**, zero failures/skips, with the existing pinned seed |
| `forge test --fuzz-seed 0x897ccfb85f71eb00ada949c5387d8bc41b650fda2a7d704b3960c7edf39b4654` | **126 passed**, zero failures/skips |
| `forge fmt --check` | Pass |
| `node --test test/listings-reader.test.cjs` | **6 passed**; Node built-ins and local Foundry `cast`, no installed packages or network |
| Compiled runtime sizes | Registry **9,035 bytes**, ads **8,056 bytes**, both below 24,576 bytes |

`HookListingRegistry.t.sol` covers free creation/editing, every persisted field, immutable historical
revisions, same-hook independent claims, duplicate rejection, two-step transfers and conflicts,
owner authorization including fuzzed callers, archive/restore, label normalization/search,
pagination, input limits and the absence of an audit badge despite audit URLs/labels/ad purchases.

`FeaturedPlacements.t.sol` covers exact price and duration, #ad disclosure, same-block ordering,
pagination, duplicate ads, automatic visibility expiry, renewing before old settlement, original
payer refund rights after edits/archive/transfers, stale purchase terms, recipient snapshots,
configuration failures, admin rotation, direct donations, withdrawal authorization, immediate and
half-period refunds, expiry boundaries, duplicate actions and fuzzed refund rounding/conservation.
Expected constructor failures use external call boundaries; traces confirmed later assertions
actually execute after each expected failure.

`FeaturedAdversarial.t.sol` exercises false/reverting/no-return/malformed tokens, sender and recipient
transfer taxes, no-op transfers, disappeared code, rollback/retry after failure and callbacks trying
to reenter each custody mutation. A reverting recipient token transfer cannot block internal
cancellation or settlement. These mocks establish the local defenses; they are not a live IMD test.

`FeaturedInvariant.t.sol` ran **256 sequences / 128,000 handler calls with zero reverts for each
seed**. It interleaves deposits, withdrawals, purchases, cancellations, time advances, settlement,
visibility changes, recipient rotation and proceeds claims. After every action it checks token
backing, each category's aggregate balances, per-placement refunds and earned funds, and cumulative
conservation. After every sequence it expires and settles all remaining ads, then withdraws every
balance without admin cooperation and asserts that no funds remain. History is bounded to 30
placements per sequence to keep exhaustive invariant checks practical. Unit tests cover invalid
actions separately, so handler success counts are not padded by expected authorization failures.

The JavaScript tests pin selectors to built artifacts, decode independent `cast abi-encode` vectors,
check dynamic metadata/label offsets and ordered pages, reject malformed ABI/undisclosed ads, and
exercise the renderer with malicious HTML and `javascript:` references. Supplied strings remain
text; every paid card contains a visible #ad badge, its pinned revision and unverified audit status.
No browser wallet transaction, hosted site or live RPC integration was exercised.

Manual contributor review checked authorization, accounting transitions, snapshot binding, token
call rollback, loop bounds and admin reach. Foundry lint emits advisory warnings, not build errors:
timestamp comparisons deliberately meter the seven-day ad period; events follow guarded token
calls so failed calls cannot record a deposit/withdrawal; label validation reverts inside explicitly
bounded loops. Scalar counters default to zero under Solidity semantics. `onlyOwner` before the
configuration guard makes no external call, and the token's code-length check also rejects zero.
Block timestamp drift/censorship and token behavior remain explicit assumptions in
[the operating terms and threat model](LISTINGS_AND_ADS.md).

No independent audit, Slither/Mythril run, public-chain fork, live deployment, paid Intake request,
new token or pool, funded-wallet operation, or rerun of the unchanged optional Python SDK suite
was performed. Recipient address approval, canonical IMD verification, deployment/source
verification and a separate contributor's adversarial review remain future launch responsibilities.
The previous `build-fingerprints.json` remains evidence for the unchanged foundation/Intake build;
it does not describe these additional contracts or a live deployment.
