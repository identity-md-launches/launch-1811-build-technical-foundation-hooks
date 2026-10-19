# Token caps and wallet context: local verification

Base: `e69e04f63832b9fa1e84c7d58c685ce37924a490`.
Report: [dde20fdc](https://api.imd.fun/jobs/dde20fdc-3a82-44e1-bde7-143f6a6f28c5/report.md).
No public deployment, payment, new dependency, backend or trust root was introduced.

## Delivered behavior

- `AutoHookJobRequester.maxPriceOf(token)` holds each token's live cap in its own base units.
  Constructor and `setProtocol` write only the selected token entry. `maxPrice()` returns the
  current asset's entry; new builds use it, while top-ups and retries use the job's original asset.
  Same-token reductions remain effective for new funding, and an already-funded trigger still
  uses its reserve. Shared `_nextAskId()` preserves the exact chain/consumer/incremented-nonce
  preimage at both call sites. Fees, roles, pausing and settlement policy are unchanged.
- SDK/UI top-up reads `maxPriceOf(reserve.token)` without fallback. The browser selector is
  `0xc9638491`; preflight requires `maxPrice() == maxPriceOf(asset()) > 0`.
- UI Connect pins provider, request function, account, chain and requester. Every action takes
  an immutable raw/form snapshot before awaiting anything. Input/change and wallet events
  advance a revision; requester/wallet changes invalidate the connection. RPC operations check
  local state and wallet account/chain before and after every operation, including estimates,
  sends, receipt polling and readbacks. All buttons share one busy lock.
- Sends specify from/chainId/to/data/value and use a separate estimate copy. A returned hash is
  saved before post-send checks and retained in errors. Success waits for final context checks.
  Approvals are separate transactions with exact allowance readback. Top-up additionally checks
  unchanged job/ask/candidate/context, exact reserve increase and refreshed maturity/deadline.
- Site ABI, current build fingerprints, deployment draft and operational documentation are
  updated. Compiler/dependencies and historical audited-build evidence are unchanged.

## RED / GREEN

`red-foundry.log` records the new seven-test `AuditDde20fdcTest` on the unmodified production
contracts: five failures, two passes. Both 18→6 top-up/retry cases reject valid original-token
funding. Both 6→18 cases wrongly permit funding above the original token's cap. The missing
mapping getter also fails. `green-foundry.log` records all seven passing after the patch.
Additional cases preserve same-token reductions, funded triggering, selected-entry-only writes,
new-job caps and shared nonce identity.

`red-ui.log` reproduces five failures against the exact base `site/automatic-ui.js`: both decimal
rotations, changed approval spender, changed top-up target and missing explicit chain ID.
The mock deliberately serves the automatic interface at both requester addresses, reproducing
the case where an interface read does not detect a changed deployment. `green-ui.log` passes
those same proofs with the current file. To reproduce from the repository root:

```sh
mkdir -p test/scratch
git show e69e04f63832b9fa1e84c7d58c685ce37924a490:site/automatic-ui.js > test/scratch/dde20fdc-baseline-ui.js
node docs/checks/audit-dde20fdc/red-ui-proof.cjs test/scratch/dde20fdc-baseline-ui.js
node docs/checks/audit-dde20fdc/red-ui-proof.cjs
```

The full Node suite includes form whitespace/ABA edits, all captured fields, provider and request
replacement, silent account/chain changes, wallet events, every transaction button, Connect and
Status races, busy-lock exclusion, mutated estimate copies, unavailable cap reads, exact allowance
mismatches, identity/reserve/maturity readback failures, pending/reverted receipts and drift after
submission through the final readback. Returned hashes survive errors. Existing behavioral tests
remain; their mock wallet setup now connects and supplies the required chain/context getters.
The Python suite includes actual disposable-Anvil 18→6 and 6→18 rotation transactions and unit
checks for missing/malformed/zero caps and preflight getter disagreement.

## Checks

Compiler is still **solc 0.8.26**, Cancun, optimizer **200**, **no via-IR**, no metadata hash/CBOR,
no FFI or filesystem permissions. The pinned repository fuzz seed is
`0x936d89b088020ddf36122a88c4c9aed7130c7a410f5c44680a7d121950c99345`.
The assignment seed was also explicitly run. Test fixtures use local mocks/Anvil only.

| Command | Result / log |
|---|---|
| `forge build` | Pass, `build.log` |
| `forge test` | **667 passed**, pinned seed, `foundry.log` |
| `forge test --fuzz-seed 0x570e3760c7b3cd25a809ed002933b826699ace6868976bebf2a57dafff68df81` | **667 passed**, `assignment-seed.log` |
| `forge test --isolate --match-contract 'AutomaticGasTest\|ReviewReceiptGasTest\|JobProtocolGasTest' -vv` | **27 passed**, `cold-gas.log` |
| `forge build --sizes` | Pass, `sizes.log` |
| `forge fmt --check` | Pass, `fmt-check.log` |
| `python3 -m unittest discover -s test -p 'test_*.py'` | **80 passed**, `sdk.log` |
| `node --test test/*.test.cjs` | **167 passed**, `ui.log` |
| `python3 script/check_automatic_vectors.py` | Four captured signed question vectors and codec/body pin pass, `vectors.log` |
| `sh script/verify-vendored.sh` | 96 vendored files verified, `vendored.log` |
| `git diff --check` | Pass, `diff-check.log` |

Foundry **1.8.3**, commit `cae51ad458f6abb64852b7709eb784352429825d`.
Minimum forwarded callback gas under isolated, cold conditions:

| Clock | EOA | 5-of-7 ERC-1271 | 22-cold-read ERC-1271 |
|---|---:|---:|---:|
| Ethereum | 127,303 | 172,364 | 189,446 |
| Robinhood native mock | 133,011 | 178,072 | **195,154** |
| Local | 127,100 | 172,160 | 189,242 |

The largest measured case leaves **4,846 gas** below the 200,000 stipend. The old
[audit-7db42bb7 table](../audit-7db42bb7/README.md) used Foundry 1.8.5; its Robinhood mock numbers
are historical and are not this release's qualification. As the report observes, the native-clock
mock redirect can incur different cold-account accounting between Foundry versions. Neither
version models the real ArbSys precompile or every production ERC-1271 registry.

Runtime: **AutoHookJobRequester 24,529 bytes** (47-byte EIP-170 margin), **HookRequestCodec 16,966**,
**GatedHookDeployer 20,967**. Codec runtime hash remains
`0xfb28d0432fba1c6ee9e6ec8d3ae5896d1a36c708c7ee6eccc701eb07dc6611ea`.
`deployment/current-build.json` and `docs/build-fingerprints.json` record the new requester build;
immutables make deployed requester hashes differ from compiler templates. No existing live
contract is upgraded by these source changes.

## Operational assumptions

The [runbook](../../AUTOMATIC_BINDING.md) documents constructor inputs, owner settings and duties.
Caps are raw token units, and operators must inspect every live token's entry when rotating.
Changing a legacy token's cap requires deliberately selecting it via `setProtocol`; it also
changes the asset for new jobs. Triggered work retains its original protocol/signer snapshots.
The panel/signer and mutable ERC-1271 registry remain trust assumptions. Native cadence floors
remain 12s/50ms/1s policy assumptions, not live guarantees. Monitoring, production callback gas
qualification, actual Intake availability/pricing and finality checks remain operator duties.

The wallet UI trusts its provider's responses. Separate latest-state reads are observations;
contracts enforce inclusion-time limits. A context error cannot cancel a submitted transaction:
inspect its saved hash on the original chain before resubmitting. No live end-to-end pilot or
independent security audit was performed here. Slither/Mythril were not run.

Logs retain check output with only the absolute workspace prefix normalized to `<repo>/`.
