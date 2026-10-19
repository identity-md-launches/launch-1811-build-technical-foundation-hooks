# Local verification

For the current audit-7db42bb7 fixes use [checks/audit-7db42bb7/README.md](checks/audit-7db42bb7/README.md) and `bash script/check_automatic.sh`. Earlier logs below are historical. Current tests include full-horizon true/false delivery on both clocks, strict expiry closure, top-up caps/refunds/rotation, quote-aware SDK/UI readiness, per-chain preflight, and the preserved signature, replay, artifact, listing/ad and recovery regressions. Isolated callback checks cover both clocks and the 200k stipend.

Historical results below describe successive revisions and do not describe the current build.

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

## Follow-up: audit ef1f6915

Checks for [AUDIT_EF1F6915.md](AUDIT_EF1F6915.md), against commit
`cb6ca724441c9aebf9a38cb4d7426218e0712723`. Configuration and dependencies remain unchanged:
Solidity **0.8.26**, Cancun, optimizer 200, no via-IR, no FFI or test filesystem permissions.

| Check | Result |
|---|---|
| `forge build` | Pass; advisory lints remain, no compiler errors |
| `forge test --summary` | **208 passed**, zero failures/skips, 22 suites; repository-pinned seed `0x936d89b088020ddf36122a88c4c9aed7130c7a410f5c44680a7d121950c99345` |
| `forge test --fuzz-seed 0x6d967c2de7363601e4857550190128b5c78ed7519ccbde73e1f146db4f3b111f --summary` | **208 passed**, zero failures/skips; assignment-supplied seed |
| Report's two literal Solidity proofs | Both reproduced their reported failures on the original source; both pass after the fix and are delivered in `AuditExpiryProof.t.sol` / `AuditReceiptConflictProof.t.sol` |
| `forge test --isolate --match-contract ReviewReceiptGasTest -vv` | All 7 pass, with gas figures matching normal execution |
| `forge fmt --check` | Pass |
| `TMPDIR="$PWD/test/scratch" sh script/verify-vendored.sh` | 96 files verified; existing 24 formatting-only differences, no dependency changes |
| Status-page JavaScript via `node --check -` | Pass; updated lifecycle event topic also pinned in the Solidity reader test |
| `node --test test/listings-reader.test.cjs` | 6 passed |
| Compiled requester runtime | **20,497 bytes**, below 24,576; requester fingerprints updated; hook/factory fingerprints unchanged |

Eleven tests are added: two literal report proofs, seven expiry/conflict/recovery regressions,
and two ERC-1271 gas tests for expiry-request and reserved-retry delivery. Existing tests are
updated where expiry now needs owner confirmation or where an unbound reserved UUID now retains
a receipt. The final reservation-release assertion also verifies that requesting expiry alone
does not make a holder terminal; it passes under the pinned seed and in the supplied-seed full run.
No test uses environment variables, network, a live signer or a paid Intake request.

Both full runs include all existing listing/ad suites: registry (11), featured placements (21),
adversarial escrow (11), ownership transfer (5), and both stateful escrow invariants. Each invariant
executes **256 sequences / 128,000 calls / zero reverts per seed**, including accounting, original
payer refunds and complete wind-down. No listing/ad contract or test source was changed.

Cold minimum forwarded callback gas is **123,013** for ECDSA receipt, **168,106** for the 5-of-7
ERC-1271 receipt (**132,880** bound), and **185,260** for the audit's +22-cold-read stressor
(**150,053** bound). The expiry-request and reserved-retry 5-of-7 paths also use **168,106**.
The receipt allocation is created in `setUp`, before the measured transaction; every binary-search
trial restores state and cools consumer/signer. Each then succeeds through MockIntake's exact
200k one-shot call. The realistic signer uses five recoveries and real threshold/membership/expiry/
revocation checks, not an always-accepting mock. Invalid and over-budget signatures still fail
without a partial receipt or consumption. See the source tests and current audit remediation for
the compatibility ceiling and operator qualification requirements.

Manual review covered the new expiry request/confirmation transitions, stale approval isolation,
receipt preservation, exact conflict versus misdelivery guards, and reservation/consumption
invariants. This is contributor self-verification, not a new independent security audit. No
Slither, Mythril, public-chain fork, live pilot, deployment or paid request was performed. The
owner-supplied mapping and absence of a pending callback are not independently authenticated
onchain; live evidence sources and owner availability remain operational blockers for paid use.

## Follow-up: audit 6b607200

The six low findings are addressed in [AUDIT_6B607200.md](AUDIT_6B607200.md). Source was built with
the unchanged pinned **Solidity 0.8.26**, Cancun and optimizer configuration. No dependencies or
build settings were edited. All tests run locally without remote RPC, credentials or network access.

| Check | Result |
|---|---|
| `forge build` | Pass; pinned compiler 0.8.26 |
| `forge test` | **228 passed**, 24 suites, zero failures/skips; repository-pinned seed |
| `FOUNDRY_FUZZ_SEED=0x7b504948825fc356a810f67b6458a77924e9ee1fb1e4281a7e4787866c8d0c12 forge test` | **228 passed**, zero failures/skips |
| `forge fmt --check` | Pass |
| `node --test test/requester-abi.test.cjs test/listings-reader.test.cjs` | **11 passed**; built-in Node modules and local `cast` only |
| `forge test --match-contract ReviewReceiptGasTest -vv` | **8 passed**, including cold exact-200k calls and binary-search gas measurements |
| Requester compiled runtime size | **23,601 bytes**, below the 24,576-byte limit |

Both the original ad conservation invariant and the listing-transfer/cancellation invariant pass
**256 sequences / 128,000 calls / zero handler reverts each**, for both full-suite seeds. They
preserve deposits, original-payer refunds, recipient proceeds, exact backing and complete withdrawal
at wind-down. Registry, hook/pool, deployment, protocol-vector, receipt packing and previous audit
regressions also remain in the full suite.

`RequesterMvpAudit.t.sol` contributes 19 tests covering the six findings, including fuzzed transaction
orders, every mismatched pre-binding context field, yes/no receipts, owner-only recovery, abandoned
asks, epoch-wide compromise response, unchanged finalized verdicts, closed-ID replay, fresh-key retry,
quote/spend rollback, donation isolation, caller limits and reentrant token callbacks. Existing test
calls were migrated to the new mandatory maximum-price argument. Review packing still round-trips
all full-width fields while isolating the newly packed epoch bits.

`ReviewReceiptGas.t.sol` measures wrong-prebinding retention at **175,435** cold forwarded gas for
its realistic 5-of-7 ERC-1271 verifier, and **192,598** for the audit's 22-extra-cold-read verifier.
Unbound receipt measurements are **125,296** for EOA, **170,389** for 5-of-7 and **187,543** for the
stress verifier. The excessive 64-read verifier still loses the one-shot callback without partial
state, as expected. These fixtures do not qualify an arbitrary live signer or proxy.

The published requester ABI exactly equals the compiled artifact. Site tests pin both paid selectors,
reject obsolete uncapped signatures, compare every displayed event topic, and exercise pending,
retained, revoked and malformed receipt reads. Build fingerprints were refreshed for the requester;
the hook and factory fingerprints were checked unchanged.

Foundry emits advisory lint warnings; compilation succeeds. No Slither/Mythril, independent audit,
live Intake pilot, deployment, paid request or funded-wallet operation was performed. The unchanged
optional Python SDK suite was not rerun. Real Intake requirements and operational trust are listed
in [the pilot checklist](IMD_INTEGRATION.md#requires-a-live-ethereum-or-robinhood-chain-pilot), including
asynchronous delivery, job callback ABI, quote/spend agreement, authenticated UUID/canonical question
mapping, fresh signing on retries and actual signer gas under 200k.

## Follow-up: audit 648ba2e5

The three user-facing findings are addressed in [AUDIT_648BA2E5.md](AUDIT_648BA2E5.md). Source was
built with the unchanged pinned **Solidity 0.8.26**, Cancun and optimizer configuration. No
dependencies or build settings were edited. All tests run locally without remote RPC, credentials
or network access.

| Check | Result |
|---|---|
| `forge build --force` | Pass; pinned compiler 0.8.26 |
| `forge test` | **240 passed**, 25 suites, zero failures/skips; repository-pinned seed |
| `forge test --fuzz-seed 0xd3b03810437118b5eb03fea9f057693c246d8de98f04d3c8f34d5d3623702e5c` | **240 passed**, zero failures/skips |
| `forge fmt --check` | Pass |
| `node --test test/requester-abi.test.cjs test/listings-reader.test.cjs` | **11 passed**; built-in Node modules and local `cast` only |
| `python3 -m unittest discover -s test -p 'test_*.py'` | **10 passed** against a disposable local Anvil |
| `forge test --match-contract ReviewReceiptGasTest -vv` | **8 passed**; cold 5-of-7 receipt 170,077, bound 132,553, wrong pre-binding 175,123; 22-cold-read stressor receipt 187,231, wrong pre-binding 192,286; EOA receipt 124,984 |
| Requester compiled runtime size | **24,081 bytes**, 495 bytes below the 24,576-byte limit |

`AuditContextMismatchProof.t.sol` contributes 12 tests: the same-UUID/other-context reproduction
fuzzed over every field and both verdicts, with every pre-existing path shown stuck and the new
closure's events, history, UUID, fee and terminal-ID invariants; owner-only, matching-verdict,
acknowledgment and precondition refusals; the quorum reproduction fuzzed over quorum and agreement,
bound and unbound, plus weak answers still failing closed in the mock's one attempt; split step
markers fuzzed over marker, boundary and cut; every assembled body fuzzed over spec hash and brief;
and synchronous Intake refusal fuzzed over the error code and both Intake paths beside the
asynchronous refusal. Two existing assertions that encoded the old quorum rule were changed as
described in the remediation note. Listing, ad escrow, invariant, protocol-vector, packing and all
earlier audit regressions remain in the suite.

The published requester ABI was regenerated and exactly equals the compiled artifact; the site's
event label for `ReviewReceiptDiscarded` names the third closure reason and the topic test still
compares every displayed event. Build fingerprints were refreshed for the requester; the hook and
factory fingerprints were checked unchanged.

Foundry emits advisory lint warnings; compilation succeeds. No Slither/Mythril, independent audit,
live Intake pilot, deployment, paid request or funded-wallet operation was performed. Whether the
live Intake refuses synchronously or after payment is listed with the other pilot items in
[the pilot checklist](IMD_INTEGRATION.md#requires-a-live-ethereum-or-robinhood-chain-pilot).


## Follow-up: protocol job callback tuple

Continues `575e8a8f74da581298a8527f493e9eab8a45901f`. The requested protocol-tuple test was
run **before** production/fixture changes and failed because the old `(bytes32,bytes)` callback
could not decode `(bytes32,bytes32,string)`. Its [RED trace](checks/job-protocol-tuple/red.log)
is retained alongside the [GREEN trace](checks/job-protocol-tuple/green.log) from immediately
after the targeted fix. The contract now stores the supplied document hash exactly, keeps
`JobDelivered` and emits `JobResultURI`. No URI string storage, oracle tuple change, mock
translation, skipped test, dependency or compiler-setting change was introduced.

| Command | Result |
|---|---|
| `forge build` | Pass; pinned Solidity 0.8.26, Cancun, optimizer 200; advisory lints |
| `forge test` | **252 passed**, 27 suites, zero failures/skips, repository-pinned seed; both escrow invariants passed 128,000 calls each |
| Assignment seed + full `--gas-report` | **252 passed**, 27 suites, zero failures/skips; both escrow invariants passed 128,000 calls each |
| `forge fmt --check` | Pass |
| `node --test test/requester-abi.test.cjs test/listings-reader.test.cjs` | **18 passed**, zero failures/skips |
| `python3 -m unittest discover -s test -p 'test_*.py' -v` | **10 passed**, disposable local Anvil |
| `forge test --isolate --match-contract 'JobProtocolGasTest\|ReviewReceiptGasTest' -vv` | **9 passed**; job tuple with 4,096-byte URI **67,052** cold forwarded gas; oracle gas unchanged |
| Requester runtime | **24,117 bytes**, **459 bytes** below the 24,576-byte limit |
| Vendored checksum verification | 96 files verified, 24 recorded formatting-only differences; used a writable scratch temp directory |

The 12 additional Foundry tests cover exact hash/event data, unauthorized and duplicate calls,
unknown/legacy/malformed callbacks, one-attempt fee loss, expiry and late completion without
resetting a negative review. All 240 preceding tests remain. Existing hash assertions now compare
the supplied result-document hash. The site decodes bounded URI event data and renders only
unverified text; malicious HTML/schemes, bad ABI/UTF-8, wrong emitters/IDs and removed logs are
covered. It neither fetches the URI nor turns it into a link or review approval.

The published ABI exactly matches compiler output; only the job callback changed and the URI
event was added. Tests verify refreshed requester fingerprints and unchanged hook/factory ones.
[Full command results, raw logs, gas measurements and operational assumptions](checks/job-protocol-tuple/README.md)
are retained. No live Intake, public-chain transaction, deployment, paid request, Slither/Mythril
or independent security audit was performed. See the [live pilot requirements](IMD_INTEGRATION.md#requires-a-live-ethereum-or-robinhood-chain-pilot)
for the remaining writer/action/body, payment, document availability, oracle mapping and signer
gas assumptions. Owner-trust disclosures and the distinction between delivery and review approval
remain in force.

## Deployment-preparation follow-up

Continues `b157921170c318f8eeee638b06025a81cf768c02` with unchanged audited Solidity and
compiler settings. [Command logs and live-read evidence](checks/deployment-preparation/README.md)
record 253 Foundry passes with each of the pinned and assignment seeds, 20 site/ABI passes,
30 Python passes, successful build/fmt checks, local deployment/configuration dry runs and exact
creation/runtime-template fingerprint equality for all five application contracts. The source
changes are reader/tooling fixes, a preparation manifest and owner-gated unsigned configuration;
there was no public deployment or paid pilot. The new gas regression reproduces the measured
20,224/20,256 URI boundary as a local pilot check, not a safe universal maximum.
