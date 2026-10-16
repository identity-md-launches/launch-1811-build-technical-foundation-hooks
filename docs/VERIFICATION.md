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

## Follow-up: audit d9970905

Historical results for the previous follow-up; see the newer re-audit section below for current counts. See
[AUDIT_D9970905.md](AUDIT_D9970905.md) for the finding-by-finding changes and unresolved live
assumptions. The pinned compiler and all build/dependency configuration remain unchanged.

| Check | Result |
|---|---|
| `forge build` / `forge build --sizes` | Pass, Solidity 0.8.26; requester runtime 17,869 bytes, ads runtime 8,232 bytes |
| `forge test --summary` | 154 passed, zero failures/skips, repository-pinned seed |
| `FOUNDRY_FUZZ_SEED=0x0d8a41f9f69a702181f07cf91a207e74720f4a2acdeec9de3481f66d7a9cc902 forge test --summary` | 154 passed, zero failures/skips |
| `forge fmt --check` | Pass |
| `TMPDIR="$PWD/test/scratch" sh script/verify-vendored.sh` | 96 vendored files verified; no dependency changed |
| `python3 -m unittest discover -s test -p 'test_*.py' -v` | 10 passed, disposable local Anvil |
| `node --test test/listings-reader.test.cjs` | 6 passed |

The original escrow invariant and the added transfer/cancellation invariant each execute **256
sequences, 128,000 handler calls, zero reverts** per seed. Both check exact token backing,
aggregate credits/proceeds/escrow, per-placement rounding, cumulative conservation and complete
withdrawal at wind-down. The new suite includes listing transfers, original-payer cancellation
and current-owner cancellation. The original invariant assertions are reused unchanged.

New tests cover exact oracle ID/question/chain/window matching, swapped answers, missing or bad
owner bindings, immutable reservations after failure/expiry, repeated identical questions,
attestation/ask expiry, two-step requester ownership and EIP-7702/ERC-1271 signature paths. Existing
hook/pool, deployment, registry, hostile-token, stipend and protocol-vector checks remain green.
No test reads or writes environment variables; the fuzz seed is supplied only to the test runner.

Build fingerprints for the modified requester were refreshed from compiler artifacts; hook and
factory fingerprints were checked unchanged. `forge` lint continues to emit advisory warnings;
compilation succeeds. No Slither/Mythril, new independent audit, public-chain pilot or live EIP-7702
transaction was run. Passing local mocks does not establish live Intake mapping/canonicalization
or pre-delivery binding availability.

## Follow-up: re-audit 5f43f94d

Historical results for the receipt-first callback repair described in
[AUDIT_5F43F94D.md](AUDIT_5F43F94D.md). Compiler **Solidity 0.8.26**, existing Cancun/optimizer
settings, dependencies and build configuration are unchanged.

| Check | Result |
|---|---|
| `forge build` | Pass; compiler advisory lint warnings remain, no errors |
| `forge test --summary` | **178 passed**, zero failures/skips, repository-pinned seed `0x936d89b088020ddf36122a88c4c9aed7130c7a410f5c44680a7d121950c99345` |
| `FOUNDRY_FUZZ_SEED=0x662f5ad8fb23c9d700d6eae60c0eeff06f7539e06c5d4ac3ebfa01822301aa43 forge test --summary` | **178 passed**, zero failures/skips, assignment seed |
| `forge fmt --check` | Pass |
| `TMPDIR="$PWD/test/scratch" sh script/verify-vendored.sh` | 96 vendored files verified, existing 24 formatting-only differences; no dependency changed |
| Status-page JavaScript, extracted `<script>` through `node --check -` | Pass; `testStaticSiteReadContract` pins the additional receipt-event topic |
| Compiled requester runtime | **19,189 bytes**, below the 24,576-byte limit; build fingerprints refreshed, hook/factory fingerprints unchanged |

`ReviewDelivery.t.sol` adds **24 tests**, including five fuzz tests at 256 cases each. Unlike the
older bound-ask fixture, its early-answer paths do not bind before the sole mock Intake callback.
The mock always records the attempt as terminal, even on callback failure, and keeps the fee.
The tests assert successful early receipt and exact later confirmation without repayment; they
also demonstrate invalid delivery's irrecoverable fee and the cost of a new ask.

Cold-access ECDSA, EIP-7702 key and ERC-1271 receipt paths all succeed under the mock's 200,000-gas
stipend. Adversarial cases cover swapped yes/no receipts, duplicate UUIDs, every context-field
mismatch, unauthorized binding/delivery, replacement and failure after receipt, replay, expiry and
identical-question retry, malformed callback/bool/signature, wrong domain, zero/invalid context,
weak panels, timestamp extremes, tolerance boundaries, fresh late answers and expired signatures.
Tests also establish the chosen semantics for confirmation after signature expiry, signer/Intake
rotation, ERC-1271 revocation and requester abandonment.

The previous 154 tests remain, with three binding/timing tests updated to assert the repaired
behavior and the static-reader topic assertion extended. Protocol digest/signature conformance,
two-step ownership, hook/pool/deployment tests and ad escrow protections still pass. Both escrow
invariants execute **256 sequences / 128,000 calls / zero reverts per seed**, retaining their exact
accounting, original-payer refund and complete wind-down assertions.

No test reads or writes environment variables; the alternate seed is supplied only to the runner.
No new library, network-dependent fixture or runtime installation is required. No public RPC,
live pilot, deployment, paid request, new independent audit, Slither or Mythril was run for this
follow-up. Passing the local one-attempt model does not establish live Intake ABI, authenticated
post-delivery mapping, canonicalization, actual signer gas or review-evidence availability.

## Follow-up: audit 1053af02

Checks for [AUDIT_1053AF02.md](AUDIT_1053AF02.md), against the existing pinned Solidity **0.8.26**,
Cancun target, optimizer 200, dependency tree and build configuration. No compiler setting or
dependency was changed, installed or fetched to run the suite.

| Check | Result |
|---|---|
| `forge build` | Pass; compiler advisory lints remain, no errors |
| `forge test --summary` | **197 passed**, zero failures/skips, 19 suites, repository-pinned seed `0x936d89b088020ddf36122a88c4c9aed7130c7a410f5c44680a7d121950c99345` |
| `FOUNDRY_FUZZ_SEED=0xc5bf18a4df77c5e8edab03e022ca2da2c37fe246ae0a377a0087f77fcf90bf32 forge test --summary` | **197 passed**, zero failures/skips; new signer failure assertions also rerun with this seed |
| `forge test --isolate --match-contract ReviewReceiptGasTest -vv` | Pass; gas figures below also match normal test mode |
| `forge fmt --check` | Pass |
| `TMPDIR="$PWD/test/scratch" sh script/verify-vendored.sh` | 96 files verified, existing 24 formatting-only differences; no vendored changes |
| Status-page JavaScript extracted into `node --check -` | Pass; Solidity test pins the added discard-event topic |
| Report's literal NotPassed-expiry proof, run in scratch | Pass; regression delivered in `ReviewDelivery.t.sol` / `ReviewRecovery.t.sol` |
| Requester compiled runtime | **19,965 bytes**, below 24,576; fingerprints updated, hook/factory fingerprints verified unchanged |

The 19 new tests are in `ReviewRecovery.t.sol` (11), `ReviewReceiptGas.t.sol` (5), and
`ReviewReceiptPacking.t.sol` (3). Two prior tests that allowed receipt expiry now assert the
repaired behavior, including both bools under fuzzing. The static-reader topic assertion is
extended. Existing exact-binding, replay, protocol-vector, signer, clock-skew, one-attempt,
ownership, hook, pool, listing and ad tests remain. Both escrow invariants pass **256 sequences /
128,000 calls / zero reverts each** under both seeds.

The cold minimum forwarded gas measurements are:

| Callback/signature fixture | Receipt-first | Pre-bound |
|---|---:|---:|
| ECDSA, 65 bytes | 125,266 | — |
| ERC-1271 5-of-7, 325 bytes | 170,359 | 135,137 |
| ERC-1271 audit fixture, +22 cold reads, 65 bytes | 187,513 | 152,310 |

Each binary-search trial restores state and cools the consumer and signer. Successful delivery
then uses the actual mock's exact 200,000-gas call. Asks are prepared before the measured test;
`--isolate` checks and `--opcodes SSTORE -vvvvv` traces confirm the metadata update costs 5,000 gas.
The 5-of-7 fixture performs five ECDSA recoveries and eleven cold membership/expiry/threshold
reads; its signature validation fits a separate cold 60k execution cap. It rejects wrong,
duplicate, revoked, expired and insufficient signers; those cases assert `BadSignature` on a
fresh attestation before testing the failed one-shot callback. A 64-cold-read fixture shows an
over-budget callback losing its attempt/fee with no partial receipt, reservation or consumption.
These are forwarded callback measurements, not transaction gas/refund figures or live-chain claims.

The preallocated metadata bit is hidden from the unchanged receipt ABI; fuzzing and maximum-value
tests round-trip all fields, including full-width IDs/chain and packed block/timestamp/count/bool
values, then finalize the exact bound answer. New recovery tests reject unauthorized/matching/
malformed/terminal discard attempts, retain original receipt history, and exercise both expiry
and failure before unused-reservation release. Consumed UUIDs stay immutable.

No test reads or writes environment variables; the alternate seed is passed only to the runner.
All fixtures are local ordinary source files and require no network for verification. No public
RPC/fork, live pilot, deployment, paid request, Slither, Mythril or new independent audit was run.
The remaining live mapping/ABI/evidence/gas assumptions, two retained informational choices,
constructor parameters and owner recovery responsibilities are documented in
[IMD_INTEGRATION.md](IMD_INTEGRATION.md).
