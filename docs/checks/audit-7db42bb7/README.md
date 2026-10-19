# Findings 1–4: implementation and local verification

Base: `357201be804e18ab48567172fb6c8b07acb30a2c`.
Report: [7db42bb7](https://api.imd.fun/jobs/7db42bb7-5204-4805-894f-db1a2c11cd8e/report.md).
This is source and local-test evidence. No public deployment, payments, backend or new trust root.

## Changes

- `HookRequestCodec.minimumWindowAgeBlocks()` defines 14,433 blocks for Ethereum/Sepolia,
  3,462,008 for Robinhood, and 173,108 for local chain 31337; other chains revert. These cover
  173,100 seconds plus eight blocks under **assumed** cadence floors of 12 seconds, 50 milliseconds
  and 1 second respectively. The constructor selects the minimum, `setPanel` rejects undersizing,
  and requester `head()` validates policy through `paymentHead` before reading the native clock.
- Preflight independently computes the policy, requires equality with the codec's minimum,
  rejects undersized settings, and records the horizon/cadence assumptions. The deployment draft
  specifies the defaults per chain and requires deploying the codec before the requester.
- Owner expiry requires `now > uint256(ask.deadline) + 300 + 1 days`. At equality a conforming
  true or false answer can still arrive; both transaction orders are covered.
- Requester-only `topUpReserve(jobId, amount)` exactly pulls the original asset for an unspent,
  committed, uncancelled Delivered/None job. It requires a positive amount and total reserve
  within current `maxPrice`, protects the additional escrow, and refreshes the native start and
  deadline. It preserves the job, ask and artifact, never repays the build, and cannot revive
  NotPassed. Tests cover cap reductions, overflow, token failure/reentrancy, protocol rotation,
  eight-block maturity, retries and refunds.
- `verdictFunding(askId)` quotes the snapshotted Intake/action/asset. SDK/UI combine phase
  readiness with an available positive price within reserve. The SDK emits unsigned bounded
  approval and top-up transactions. Separate UI buttons recheck eligibility and read back the
  allowance after approval and job/reserve/readiness after funding.
- Deterministic question/window/panel/canonical-bool checks moved into the existing immutable
  codec's `validateReview`. Signatures, consumer domain, ERC-1271 caller context, epochs,
  revocation, replay and settlement remain in the requester. Shared ownership/lifecycle checks
  reduce duplicate runtime code. The codec runtime pin, site ABIs and fingerprints are refreshed.

## RED / GREEN

`red.log` records the initial regressions before production edits. Two initial Robinhood cases
hit the existing fixture's native-clock emulation problem instead of the age failure. The local
Foundry 1.8.5 runtime emulates ArbSys even when code is etched at address 100. The fixture now
redirects that selector with `vm.mockFunction` to a real storage-reading mock, keeps L1/native
heights distinct, and cools both addresses for isolated gas tests. Malformed/reverting clock
tests alter that mock's runtime. No production clock fallback was added.

`full-horizon-red.log` then repeats all six horizon cases against the original contracts from the
pinned commit, using the corrected clock fixture. Every case fails with **full-horizon valid
answer lost**, including both true and false on Ethereum and Robinhood. The baseline source URLs
and SHA-256 hashes are in `baseline-sources.json`. Copies were compiled in `test/scratch` under
distinct Solidity names with imports adjusted; the original codec runtime hash still matched the
original requester's pin. Those scratch copies are not submission dependencies.

`tooling-red.log` records the old SDK accepting an unaffordable/unavailable quote and preflight
accepting an undersized or mismatched policy. `green.log` is the 20-test regression suite excerpt
from the full successful Foundry run. The delivered tests also retain previous signature,
canonicalization, epoch, replay, recovery, gated deployment, listing/ad and escrow regressions.
Old expiry and stale-age expectations were updated to the new specified boundaries.

## Checks

Compiler/configuration/dependencies are unchanged: solc **0.8.26**, Cancun, optimizer 200,
no via-IR, no metadata hash/CBOR, no FFI or filesystem permissions. All commands below are local;
the Python integrations use disposable Anvil instances, and Node tests use wallet-provider mocks.

| Check | Result / log |
|---|---|
| `forge build` | Pass, `build.log` |
| `forge test` | **660 passed**, repository seed, `foundry.log` |
| `forge test --fuzz-seed 0x496abaac78906e29834a9e8c6092ebc83fe50f2785c67161be04f9cee38e1ef2` | **660 passed**, `assignment-seed.log` |
| `forge test --isolate --match-contract 'AutomaticGasTest\|ReviewReceiptGasTest\|JobProtocolGasTest' -vv` | **27 passed**, `cold-gas.log` |
| `forge build --sizes` | Pass, `sizes.log` |
| `forge fmt --check` | Pass, `fmt-check.log` |
| `python3 -m unittest discover -s test -p 'test_*.py'` | **74 passed**, `sdk.log` |
| `node --test test/*.test.cjs` | **37 passed**, `ui.log` |
| `python3 script/check_automatic_vectors.py` | Four captured signature/question vectors and current body/codec pin agree, `vectors.log` |
| `sh script/verify-vendored.sh` | Pass, `vendored.log`; reported format-only differences predate this change |
| `git diff --check` | Pass, `diff-check.log` |

Isolated minimum forwarded callback gas, including a cold codec/pin and the mock native clock:

| Clock | EOA | 5-of-7 ERC-1271 | 22-cold-read ERC-1271 |
|---|---:|---:|---:|
| Ethereum | 127,301 | 172,362 | 189,444 |
| Robinhood native mock | 130,509 | 175,570 | **192,652** |
| Local | 127,122 | 172,182 | 189,264 |

Runtime bytes: **AutoHookJobRequester 24,468**, **HookRequestCodec 16,966**,
**GatedHookDeployer 20,967**. The requester has 108 bytes remaining under EIP-170.
Codec runtime hash: `0xfb28d0432fba1c6ee9e6ec8d3ae5896d1a36c708c7ee6eccc701eb07dc6611ea`.
The historical audited-build artifact remains unchanged; `deployment/current-build.json` and
`docs/build-fingerprints.json` describe this local build.

## Operational limits

Cadence floors are policy assumptions, not live guarantees. Operators must monitor native
cadence and latency, record preflight/configuration, and raise the age allowance if needed;
existing triggered asks keep their snapshots. A price above the current ceiling needs an owner
cap change before sufficient top-up is possible. Quotes and allowances can change before mining;
the contracts enforce the final limits atomically. Read state again after each transaction.

The existing panel, signer and mutable ERC-1271 registry remain trusted. Gas measurements cover
the recorded mocks, not every possible production registry. Requalify production callback gas,
clock behavior, action availability and signer policy before a separately authorized pilot.
Full-horizon callback acceptance does not extend the deployer's separate approval-freshness
policy. Tests are not an independent security audit; Slither/Mythril were not run.
See [the deployment and workflow runbook](../../AUTOMATIC_BINDING.md) for actual configuration
inputs, owner responsibilities and recovery procedures.
