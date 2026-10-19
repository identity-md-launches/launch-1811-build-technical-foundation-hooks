# Audit 2218802d remediation evidence

Continues `205fa11271ab17a26630154815fae4c390aac624`. The [audit](audit.md) was retrieved
from its public report endpoint; it is input, not a new audit of these changes.
This assignment changed source, tests, SDK/UI and documentation only. No deployment,
public signing, payment, backend or new trusted signer was introduced.

## RED and GREEN

Before production edits, nine regressions failed against the original contracts: see
[red.log](red.log) and [baseline reproducer](red-regression.sol.txt). The reproducer uses
the baseline fixture's `_ready(true)`; the updated fixture now uses `_ready()` because
delivery must always precede commitment. The submitted tests are
[Audit2218802d.t.sol](../../../test/Audit2218802d.t.sol).

| Audit issue | Failing baseline behavior | Fix and successful/failing coverage |
|---|---|---|
| 1: stranded reserve | Late delivery/commit could not mature before expiry; expired build could not ask | Delivery/commit extend the deadline without shortening it. Requester renewal refreshes an expired unspent ask, preserving funds and identity. Tests cover original and retry reserves, eight-block maturity on both clocks, clock failure, cancellation, refunds and forbidden states/callers. |
| 2: paid answer lost | +1/+300s skew and 3601s delay rejected | Explicit signed issuance/expiry bounds accept valid true and false answers. Tests cover +1/+300/+301s, ask deadline +300/+301s, issuance before ask, expiry equality/+1s, zero/negative/overlong lifetime, widened arithmetic, delayed false finality and receipt-time clamping. |
| 3: rotation loses answer | EOA/ERC-1271 callback uses the replacement signer | Signer/epoch recorded at trigger; ECDSA-first/ERC-1271 checks in requester context. Tests reject the new signer for old asks and revoked pending epochs; preserve packing, receipt views, finalized revocation, guarded recovery, consumed UUIDs and history. |
| 4: premature immutable candidate | Open job accepted commitment before the result arrived | Commitment requires Delivered and an uncancelled reserve. Contract and SDK/UI reject early commitment; valid delivered artifacts still authorize exact deployment. |

[green.log](green.log) includes 34 focused regression/composition tests and four captured
public signature/preimage vectors. Existing tests additionally cover exact ArtifactV2
substitution, domain/panel/question/window tampering, replay, fees, spend rollback,
genuine PoolManager swaps and deployment authorization. The original legacy requester,
listing/ad escrow and invariant suites remain included.

## Completed local checks

| Check | Result / evidence |
|---|---|
| `forge build` with pinned solc 0.8.26 | Pass; [build.log](build.log). Compiler/lint warnings are retained. |
| `forge test` with repository seed | 640 passed; [foundry.log](foundry.log). |
| `forge test --fuzz-seed 0xe1cee08ccc29120111028768a3aec176c1fef4b508e16a2c358555bd62e98669` | 640 passed; [assignment-seed.log](assignment-seed.log). |
| `forge fmt --check` / `git diff --check` | Pass; empty success logs [fmt-check.log](fmt-check.log), [diff-check.log](diff-check.log). |
| Full Python SDK/tool suite | 66 passed; [sdk.log](sdk.log). Disposable Anvil only, including unsigned renewal simulation and the automatic deployment path. |
| Full Node UI/ABI suite | 32 passed; [ui.log](ui.log). Calldata matches cast/compiler, early commit is blocked, renewal refreshes displayed deadline. |
| Isolated cold callback and size tests | 27 passed; [cold-gas.log](cold-gas.log). Includes automatic EVM/Ethereum/ArbSys paths and unchanged legacy callback orders. |
| Offline captured protocol vectors | Pass; [vectors.log](vectors.log). No new signature or public transaction. |
| Fresh emitted Ethereum/Robinhood bodies | [protocol-bodies.log](protocol-bodies.log), [body-parity.json](body-parity.json). Independent sorted JSON reproduces both question hashes; codec composition preserves consumer, body and pin bytes. |
| Vendored dependencies / protected paths | [vendored.log](vendored.log): 96 files verified. Protected paths unchanged; configuration hashes in [summary.json](summary.json). |

Reproduce the suites offline with `bash script/check_automatic.sh`. ABI and build evidence
can be refreshed after building with `python3 script/update_build_evidence.py`. Historical
`deployment/audited-build.json` remains unchanged. The current build is not independently audited.

## Runtime and callback limits

Unchanged compiler: solc 0.8.26, Cancun, optimizer 200, no via-IR, metadata hash or CBOR.
Runtime sizes from [sizes.log](sizes.log): requester **24,258**, codec **15,292**, official
gate **20,967** bytes, each below 24,576. Requester margin is 318 bytes.
Codec runtime pin is `0x859f399b399577f66ec08206409147fbab279c93545cd77f9aaa447e4faddcc5`.
ABIs and creation/runtime fingerprints are refreshed in `site/`, `deployment/current-build.json`
and `docs/build-fingerprints.json`.

Minimum forwarded cold callback gas, measured with `forge test --isolate` and explicit cooling,
including ordinary signer rotation after each measured ask:

| Local modeled clock | EOA | ERC-1271 5-of-7 | ERC-1271 22 cold policy reads |
|---|---:|---:|---:|
| Ethereum `block.number` | 126,557 | 171,617 | 188,699 |
| Robinhood external ArbSys mock | 132,223 | 177,283 | 194,365 |

All fit the 200,000-gas stipend, also exercised through one-shot MockIntake completion.
The narrowest measured margin is 5,635 gas; arbitrary live registries are not covered by this
measurement. Job result/failure callbacks and oversized-URI omission also pass.

## Assumptions and operational responsibilities

The [updated runbook](../../AUTOMATIC_BINDING.md) documents constructor inputs, owner powers,
fees, reserve lifecycle, signed timing bounds, registry trust and
[per-chain maxWindowAgeBlocks sizing](../../AUTOMATIC_BINDING.md#per-chain-maxwindowageblocks-policy).
The unchanged 7,200 default is a native-block count, not a universal latency allowance. The
operator must measure cadence/latency, choose and record a policy per deployment, check the
exact codec, qualify the actual signer gas cost, and independently establish non-delivery
before owner expiry recovery. Registry key membership remains mutable under its existing trust
model even though the ask records its address.

Captured public vectors, mocked ArbSys, disposable Anvil and local gas checks do **not** prove
a live Hooks Store build/review/oracle/deployment workflow. No live proof is claimed. Independent
review and a separately authorized pilot remain outstanding. Slither/Mythril were not run.
