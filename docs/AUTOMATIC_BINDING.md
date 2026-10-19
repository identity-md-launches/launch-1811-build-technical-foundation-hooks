# Automatic oracle authorization

This revision continues `e69e04f63832b9fa1e84c7d58c685ce37924a490`, fixing the token-cap and wallet-context findings in
[audit dde20fdc](https://api.imd.fun/jobs/dde20fdc-3a82-44e1-bde7-143f6a6f28c5/report.md). It preserves confirmed native-chain
windows, automatic binding and exact-artifact authorization. Use `AutoHookJobRequester`, its immutable `HookRequestCodec`, and `GatedHookDeployer`.
The old `HookJobRequester` remains a legacy manual consumer for existing integrations and tests;
its owner-binding methods are not part of the new flow. No live deployment, payment, wallet
signature, token, pool, backend or new trusted signer was created by this work. Local tests use disposable
EOA/ERC-1271 signers and Anvil typed-data signing, as well as independently captured public signatures.

The old requester was 24,559 bytes under the unchanged compiler settings, leaving 17 bytes.
Composition avoids exceeding EIP-170 and preserves the existing recovery and compatibility suite.
The successor reuses `OracleAttestationConsumer`, `ExactStoreToken`, two-step `StoreAdmin`,
HookSpec v1, ArtifactV2, and the official deployment policy. Both requesters expose the same static
15-field `getJob` ABI; the deployer has an immutable requester and detects the automatic surface.

## User transactions and funding

1. Approve the actual build quote plus the chosen verdict reserve in the configured IMD token.
2. Call `openJob(fullHookSpec, gatedDeployer, brief, maxBuildFee, verdictReserve)`. It validates the
   full spec, chain, deterministic codec and deployer/requester relationship. It pulls exactly
   the build price plus reserve, spends only the build price, and records the full spec/context.
   The draft retains a 0.5 IMD cap; historical captured quotes were 0.5 IMD per action (**1 IMD**
   total). Always read the current quotes before approving. The current Intake price
   must be nonzero and within the caller's caps and the configured per-action ceiling. No native
   currency is accepted as the fee asset.
3. Wait for **Delivered**, then obtain the accepted build and independent review from the job's public records. Inspect their
   exact source/build, commit and deployment context. Call `commitArtifact(jobId, ArtifactV2,
   reviewedCommit)` from the job requester. `reviewedCommit` is the full 20-byte git SHA-1, encoded
   as `0x` plus 40 hex digits. A job accepts **one immutable candidate**, only after delivery and
   only if the reserve has not been cancelled. Commitment is a candidate selection, not approval.
4. Once the job is Delivered and the candidate committed, **any wallet** may call
   `requestVerdict(askId)`. The native head must be at least eight blocks beyond candidate
   commitment (or beyond retry creation, renewal or top-up), with an active reserve.
   `verdictReadiness(askId)` reports phase/window readiness, native head, start and closing block.
   `verdictFunding(askId)` returns the live price, reserve and token using the job's snapshotted Intake,
   action and asset. SDK/UI require both phase readiness and an available positive quote <= reserve. Early calls
   revert before quoting, pin creation or payment, and cannot spend reserves.
   The trigger pays native transaction gas only; the contract spends its reserved IMD once.
   The caller supplies no question, prefix, artifact, recipient or price. A lower verdict price
   credits the unused reserve to the original requester. A higher price reverts without spending; the requester can top up the existing unspent ask.
5. The asynchronous oracle callback verifies and records true or false. A genuine false is
   terminal. After Passed, the requester uses `sdk.gated_deploy` in automatic mode, mines a salt
   through `eth_call`, then sends the generated deployment transaction. Deployment is a separate
   user transaction; the callback does not deploy.
6. `withdrawRefund(asset)` withdraws only the caller's refund credit. A failed build, or an
   unspent reserve past its deadline, permits requester-only `cancelReserve(jobId)`. Cancellation
   permanently disables that ask, including after a late build callback. An expired unspent
   reserve cannot be spent by a permissionless trigger. The build price and any already-spent
   verdict price are never refundable by this contract.

Delivery and commitment each refresh the native start block and extend the reserve deadline to
`max(existingDeadline, now + 1 day)`. They never shorten the original seven-day deadline. Late
delivery remains reviewable, including after `expireJob`, unless the reserve was cancelled.
`reserveDeadline(jobId)` exposes this separate deadline, which can differ from the build deadline.

For an **untriggered** expired window the requester may call `renewVerdict(jobId)` instead of
cancelling. Renewal requires Delivered, review None, an uncancelled positive reserve, no Intake
ID on the current ask, and `now > reserveDeadline` (strict). It only refreshes the start/deadline:
no token transfer, quote, new ask, new candidate, pin or oracle request. The same ask must then
mature for eight native blocks. This also repairs an expired untriggered retry. It cannot revive
Pending, Passed, NotPassed, Unanswered or cancelled attempts. After the renewed deadline the
requester may still cancel and withdraw the same unused funds.

For an **unspent committed ask**, `topUpReserve(jobId, amount)` requires the original requester,
Delivered, review None, a committed candidate, no cancellation, no current ask Intake ID, and
`amount > 0`. The resulting total reserve must not exceed the **live original-token cap**
`maxPriceOf(reserve.token)`. The exact transfer uses the job's **original asset**,
credits both its reserve and protected escrow, and refreshes the same native window/deadline.
It works before or after the reserve deadline and does not require a current quote. It cannot
repay the build, replace the candidate, create an ask, revive NotPassed/cancelled work, or fund a
spent ask. Unanswered still requires `retryVerdict` first; that fresh unspent retry may be topped up.
`ReserveToppedUp(jobId, amount, reserve)` records funding. Surplus at trigger and cancellations
remain pull-refunded exactly once; the owner cannot sweep them. Transfer failure, an inexact
transfer or a reentrant funding attempt reverts atomically.

`maxPriceOf(token)` is denominated in that token's base units. The constructor and
`setProtocol(Intake, asset, cap, jobAction, reviewAction)` update only the selected asset's entry;
rotating to another asset leaves all other caps intact. `maxPrice()` remains a compatibility view
of `maxPriceOf(asset())` for new jobs. An unconfigured token has cap zero. Top-ups and retries
always use their job's original token entry; there is no fallback to the current asset's cap and
no automatic decimal conversion. For example, rotating from an 18-decimal token capped at `1e18`
to a 6-decimal token capped at `2e6` does not block a `0.5e18 + 1` legacy reserve. Rotating the
other way cannot permit a reserve above the 6-decimal token's own cap.

Caps are live per token, not frozen per job. A same-token reduction limits later top-ups and
retries, including after rotating away again. It does **not** prevent spending an already-funded
reserve at its original snapshotted Intake/action/token: permissionless triggering still compares
the quote only with that reserve. Fees, refund accounting, roles and existing pausing behavior
are unchanged. Shared `_nextAskId()` retains `keccak256(abi.encode(chainId, requester, ++nonce))`
for both opening and retrying; it does not reset a nonce on rotation.

If a price rise exceeds the original token's ceiling, the owner must deliberately update that
entry via `setProtocol` before sufficient top-up or retry is possible. There is no separate
legacy-token setter: selecting a token also selects it for new jobs, so plan configuration changes
and admission accordingly. A later rotation must retain the intended cap for its selected token.
These changes affect funding limits, never review authorization. A requester may instead wait,
renew an expired window, or cancel after its deadline; top-up and renewal never repay the build.

Every wallet transaction needs the chain's native gas currency. The UI estimates gas before asking
the wallet to send. Local Anvil transaction measurements using **MockIntake, which stores entire
bodies**, were approximately 46k for approval, 3.34m for openJob, 485k for commitArtifact, 3.18m
for requestVerdict and 1.09m for deployment. These are local measurements, not live quotes or gas limits: the live Intake
emits its body instead of storing this mock's full copy, and compiler, token behavior and calldata
change costs. Use a fresh wallet/RPC estimate for every transaction. The immutable prefix accounts
for about 0.54m code-deposit gas in the trigger. See the saved SDK and callback gas logs.

## Question binding and canonicalization

The implementation follows [SwarmFeed.sol](https://github.com/fa11up/infer-protocol/blob/790493d99ee164a4d86779079a788b0c096b49e4/src/SwarmFeed.sol)
and [question-prefix.mjs](https://github.com/fa11up/infer-protocol/blob/790493d99ee164a4d86779079a788b0c096b49e4/oracle/question-prefix.mjs).
The protocol hashes a sorted-key JSON question document, not the Intake body. `consumer`,
`panelSize`, quorum and validity policy are outside that document; `evidence` is included only
for `panel`, and definitions are included. This revision always requests `bool` and `panel`.

At openJob the contract creates a unique `askId` from chain, consumer and monotonic nonce. The
question contains the exact origin chain, Intake address and job Intake ID, consumer address,
ask ID, specHash, completion resultHash, full reviewed commit, and **full ArtifactV2 digest**.
The full candidate is available from `getCandidate(jobId)`. Its digest uses the unchanged
`HookArtifactV2` type hash and all fourteen fields, including initcode identity (creation code plus
constructor bytes), final runtime, source/build identities, source/review submissions, evidence,
chain, deployer, PoolManager/code hash and permissions.

The codec emits the canonical prefix through `"window":{"fromBlock":`. The trigger stores it
immutably as `STOP || prefix` in a small data contract. The callback reads it with EXTCODECOPY,
appends decimal **signed** fromBlock, `,"toBlock":`, decimal **signed** toBlock and `}}`, and
requires keccak256 equality with the signed questionHash. It also requires exact equality with
the absolute window requested. There is no owner-supplied question mapping or UUID allowlist.
A writer may mispair Intake and oracle IDs, but a different ask's signed question cannot pass.
Even a separately bought answer to this identical question only approves this identical candidate.

The absolute window starts at candidate commitment following delivery (or at retry creation,
renewal or top-up), and closes at **native head minus eight** (`WINDOW_DEPTH = 8`).
The start must be less than or equal to that closing block before payment. A one-block window
is valid at the first eligible head: for a latest input at native block S, head S+7 is too early;
head S+8 requests [S,S]. This is already eight blocks deep at the trigger, satisfying IMD's
five-block processing requirement without relying on Intake's confirmation delay. The captured
Ethereum Intake setting is only three confirmations; Robinhood's is two. Neither controls this
consumer's depth. The fixed window intentionally ends **before** the oracle trigger; only the
signed issuance time must be at or after that trigger.

Every recorded height uses the same `head()` function: open, commitment, job delivery, retry, renewal, top-up,
trigger and callback freshness. Its implementation is in the immutable, runtime-pinned codec:

| Question chain | Clock |
|---|---|
| Ethereum 1 and Sepolia 11155111 | Solidity `block.number` |
| Robinhood 4663 | `ArbSys(address(100)).arbBlockNumber()` via STATICCALL |
| Local 31337 | Solidity `block.number`, local fixtures only |
| Any other chain | `UnsupportedClock(chainId)`, before build payment, retry funding or verdict spending |

A missing, reverting or malformed Robinhood system-clock response fails with `InvalidClock`,
without any L1 fallback. Values above 2^53-1 are refused (the official OracleQuestion JSON integer
limit), so no narrowing conversion silently truncates a height. Base and other testnets remain
unsupported by this automatic requester; their separate deployer-policy entries do not enable an
Intake or a clock here. Sepolia has a supported clock but still sells no job.open in the captured
capabilities. Adding a chain requires a reviewed codec/requester revision, not an owner clock switch.

At callback, the signed window must equal the requested window exactly. The closing block must
be strictly behind the native head and no more than the snapshotted block-age bound behind it
(chain-specific minima below). Timestamp checks use widened arithmetic and inclusive bounds:

```text
askedAt <= issuedAt <= ask.deadline + 300 seconds
issuedAt <= now + 300 seconds
issuedAt <= expiresAt <= issuedAt + 86400 seconds
now <= expiresAt
```

There is no separate one-hour answer-age cap. Valid delayed true **and false** answers are
accepted, including after the local ask deadline, subject to the exact question/window, native
block-age, domain, panel, signer and replay checks. The receipt time is `min(issuedAt, now)` so
permitted future skew cannot create a future deployment timestamp. The deployment gate retains
its separate approval freshness policy; acceptance of an old answer does not extend that policy.
`setPanel` rejects any age below the codec's chain-specific minimum. The constructor initializes
that minimum; requester `head()` calls `codec.paymentHead(age)` to validate policy **before**
reading the native head. Delayed delivery can still fail if actual cadence violates the assumed floor.
The eight-block margin is admission depth, not a finality or reorg guarantee.

Protocol canonicalization drift fails closed. Updating the prefix algorithm requires a reviewed
new codec/consumer deployment; existing prefix bytes cannot be silently replaced. The codec's
exact runtime hash is checked before a build can take payment. Its prefix, question, definitions
and body encoding retain the previous semantics; composition moves their assembly out of the requester.
`prepareJob` composes the existing `validateOpen`, `validateBrief`, HookSpec hash and jobBody.
`prepareOracle` composes the existing question, prefix, immutable pin creation and oracleBody.
`validateReview` checks the deterministic question, exact window, timestamp bounds, snapshotted
panel policy and canonical 32-byte bool. Its widened context words come from bounded requester
storage; they confer no authority when the helper is called directly. It never verifies signatures,
consumes UUIDs, changes epochs, settles a review or transfers funds.
Both derive the consumer from `msg.sender`; the codec's address never substitutes for the
requester in the body or signed question. Signature verification remains in the requester,
including its EIP-712 domain and ERC-1271 caller context. This retains the 24,576-byte runtime cap.
New prepayments/retries and the total reserve after each top-up still obey
the current maxPrice; a funded verdict still obeys its original reserve cap. Compiler changes require an
explicit code/hash update; the project still pins solc 0.8.26, Cancun, optimizer 200, without IR,
metadata hash, FFI or filesystem access.

## Per-chain maxWindowAgeBlocks policy

This deployment setting is a **native block count** with a minimum that covers the full allowed
trigger-to-delivery horizon: `86400 + 300 + 86400 = 173100` seconds. The codec exposes
`minimumWindowAgeBlocks()`; the constructor sets that value and `setPanel` cannot undersize it.
Changes affect asks triggered afterward; an existing ask retains its age bound.

| Chain | Minimum / constructor default | Assumed fastest cadence |
|---|---|---|
| Ethereum (1) | 14,433 EVM blocks | 12 seconds/block |
| Sepolia (11155111) | 14,433 EVM blocks | 12 seconds/block; clock support alone does not enable paid builds |
| Robinhood (4663) | 3,462,008 ArbSys native blocks | 50 milliseconds/block; never use L1 block.number |
| Local (31337) | 173,108 test blocks | 1 second/block, local testing only |
| Any other chain | Revert | No fallback policy or clock |

The formula is `8 + ceil(173100 seconds / cadenceFloor)`. The eight-block addition accounts for
the already-confirmed closing block at the trigger. These floors are **assumptions**, not measured
live guarantees, finality promises or limits enforced on a sequencer. Faster production cadence
or bursts can exhaust the age allowance before a timestamp-valid answer arrives. Operators must
monitor the native counter and callback latency, record the policy, and choose a larger bound
when warranted. Raising the setting cannot change an already-triggered ask's snapshot.

The read-only preflight independently computes this table, compares it to the deployed codec's
minimum, and rejects undersized settings and unsupported chains. Its output records the chosen
age, minimum, horizon and assumed cadence floor. It still does not prove live cadence, finality,
Intake action availability in the future, or delivery within the 200,000-gas stipend.

## What the panel must establish

The fixed definitions require the panel to resolve the exact origin using Intake Requested logs
and public IMD records; verify acceptance and the immutable completion snapshot against resultHash;
recompute the stored full HookSpec hash; identify the exact accepted source and independent review
submissions; verify the reviewed commit and lack of unresolved findings; and reproduce the source,
compiler/dependencies/settings, constructor bytes, creation code, final runtime including immutables,
manager/code hash, chain, deployer and permissions. Missing, rejected, self-reviewed, unrelated,
ambiguous or unverifiable evidence means false. A worker's JSON, URL or publication cannot approve.

The signature authenticates the panel's answer to this exact question. HTTPS/public records alone
are not onchain authentication; they are evidence the panel must examine. Correctness still trusts
the panel and the existing IdentityMD v2 signer, not a new backend or signer. Default signed policy
requests 7 seats and a quorum of 5. Acceptance requires panelSize >= 7, nonzero signed quorum
<= panelSize, agreed >= both the requested minimum of 5 and the signed quorum, and agreed <= panelSize.
A lower signed quorum with enough actual agreement is accepted, preserving the earlier agreement-policy fix. Both signed panel size and quorum are checked for consistency. The callback
requires the snapshotted same-chain Intake, an outstanding self-created Intake ID, a fresh bool
answer in this consumer's `IdentityMD Oracle` / version `2` EIP-712 domain, and an unused nonzero
oracle UUID and panel job ID. Intake IDs and oracle UUIDs remain distinct namespaces.

## Worker input trace

The actual assembled job body includes the human-readable template behavior, pinned source repository
and base commit, exact solc 0.8.26/Cancun/optimizer/metadata settings, the entire JSON HookSpec, ABI specHash, originating chain,
Intake address, consumer, unique ask and gated deployer. The spec contains manager, code hash,
permissions and the amount limit. It is JSON-escaped before insertion in the job objective.
Creator text is bounded strict UTF-8; JSON/control/delimiter characters are rejected. It is quoted
as untrusted requirements, and no creator text is inserted in the oracle question.

An Intake ID does not exist until request returns. Workers are explicitly told to read
`getOrigin(askId)` on the supplied consumer/chain after admission and match JobOpened with Intake
Requested logs. This gives the actual generated ID without nonce guessing or a backend. The
consumer stores that same ID and the later signed question explicitly names it. Public records
connect it to the control-plane job; the panel must verify that relationship as part of its
signed factual answer. Four explicit job steps preserve build, independent tests, adversarial
review, then publication of source/review/build/commit and artifact fields. They do not inject
control-plane acceptance fields or ask the review worker to alter source.

The worker must publish the complete candidate fields and the actual reviewed commit as job
artifacts/records. The creator can submit those through the SDK/UI. ArtifactV2 evidenceHash keeps
the existing canonical evidenceDocument convention (zero evidenceHash only in that document's
own build preimage). The automatic deployment path does not depend on a named approval file;
the panel verifies the full candidate and acceptance directly. The legacy path retains its exact
accepted-file parser for compatibility.

## Failures, revocation and owner powers

Intake v2 is required. requestWithFailure is used for both actions. Synchronous refusal or
quote/spend mismatch reverts the entire call, preserving reserves. Unsigned failure callbacks
only close an outstanding self-created request, never authorize deployment or pay a recipient.
A failed callback can be lost: Intake attempts it once with 200,000 gas.

A signed true or false is finalized atomically; there is no routine bind-first/receipt-first owner
race in this successor. The legacy suite still tests both old callback/binding orders. A requester
cannot expire a Pending verdict or erase NotPassed. Fresh valid callbacks remain eligible past
the local review deadline. The owner may exceptionally `confirmReviewExpiry` only when
`now > uint256(ask.deadline) + 300 + 1 days` and no verified answer exists. Equality is still a
valid delivery instant, so closure reverts there. This prevents owner expiry from preempting a
still-valid true or false answer. After that boundary, even the latest-issued conforming answer
has expired. The owner still handles incidents and independently checks non-delivery; ordinary
users cannot close Pending or erase NotPassed.

`retryVerdict(jobId, reserve)` is requester-funded and only permitted after Unanswered. It keeps
the same immutable candidate, creates a fresh unique ask and a one-day reserve deadline, and
cannot replay an earlier attempt's question/UUID. NotPassed cannot retry. At trigger, each ask
records `(uint256(uint160(oracleSigner)) << 96) | (uint256(oracleSignerEpoch) << 64)`.
The low 64 bits start at zero and later receive the receipt time by OR, preserving signer and epoch.
`reviewReceiptSignerEpoch(intakeId)` returns zero until an oracle UUID is recorded, then the
recorded epoch, including after recovery/retry.

`setOracleSigner` starts a new epoch; ordinary rotation preserves in-flight answers and past
approvals. Verification tries ECDSA first (even if the recorded signer has code), then ERC-1271
against that **recorded address in the requester context**. The new signer cannot answer an old
ask. Registry membership/implementation remains that registry's current policy; snapshotting an
address does not freeze its keys or code. After rotation,
`revokeSignerEpoch(oldEpoch, incidentHash)` rejects pending callbacks and blocks finalized
deployment immediately. `closeRevokedVerdict`
can close an affected finalized verdict for recovery, preserving the old ask, UUID consumption
and events. It is an explicit compromised-signer exception, not normal review shopping.

Protocol, token and action settings and panel minimums are snapshotted per job. Window-age policy
and signer address/epoch are snapshotted at trigger. `maxPriceOf(token)` caps new
prepayments/retries and total reserves after top-ups in that token's own base units. Two-step ownership and cancelled handovers are preserved. The owner cannot
sweep reserves or refund credits. Job callbacks emit the full untrusted URI only up to 1,024 bytes; larger URIs emit JobResultURIOmitted
with their length, so the result hash/status can still be recorded within the stipend (tested at 64 KiB).
The callback transaction itself retains the original URI. No callback transfers funds or deploys; callback external calls
are STATICCALL verification only, followed by state changes. Fee-spending and withdrawals use
reentrancy guards, exact balance accounting and one-request allowances cleared afterward.

## Exact deployment authorization

The official GatedHookDeployer queries approvedArtifact only after checking Delivered, Passed,
signer epoch/provenance/revocation and freshness. In automatic mode it requires exact digest
equality and does not parse caller result JSON. The signed question already included the exact
completion hash and full artifact. It then checks creation/constructor hashes, current chain,
this exact deployer, enabled pinned manager/code hash, valid mask and mined address bits. It
records job/artifact use before CREATE2 and verifies final runtime, manager and permission readback.
A failed constructor/readback reverts consumption. Every job and artifact deploys at most once.
Legacy mode still requires the exact result snapshot and its unambiguous accepted evidence.

## After launch / operational responsibilities

This assignment provides source and local tests only. No actual deployment addresses are invented.

| Contract / input | Who supplies or checks it |
|---|---|
| HookRequestCodec | Deploy the exact compiled no-argument codec first; check its runtime matches this build. It has no owner or settings. |
| AutoHookJobRequester(owner, Intake, IMD, signer, maxPrice, codec) | The deployment operator supplies the real launch owner and protocol addresses for the selected chain. Deploy the codec first: this constructor reads its chain-specific minimum. It never assigns ownership to the factory. Existing protocol reference addresses are configuration inputs, not hardcoded recipients. |
| GatedHookDeployer(owner, requester) | Deploy with the automatic requester as immutable verdict source. Never substitute the legacy requester when advertising automatic binding. |
| `setProtocol(Intake, IMD, cap, jobAction, reviewAction)` | Launch owner, only when protocol configuration changes. Defaults use published padded action IDs job.open@job-1 and oracle.request@oracle-1; verify priceOf before opening. Existing jobs keep their original Intake/token/actions. Only the selected token's cap is updated; inspect all legacy token caps before changing configuration. |
| `setPanel(panelSize, quorum, maxWindowAgeBlocks)` | Launch owner selects the deployment policy; defaults 7/5 with the chain-specific age minimum in the table above; undersizing reverts. Respect the paid door's current minimum/cap (captured minimum 5, maximum 100); test one-shot callback gas for any signer/policy change. |
| `setManager(manager, codeHash, true)` on deployer | Launch owner performs initial manager-policy activation. Production pins are unchanged. Re-read manager code and check the appropriate chain; this is infrastructure setup, not a per-hook approval. |
| Ad recipients and Store token configuration | Existing listing/featured-placement deployment runbook remains authoritative. This change does not alter ad fees, recipients, tokens or their settings. |
| Worker source/build/review records | IMD workers and independent reviewers must preserve public reproducible source, exact commits and accepted submission identities. The creator submits the one candidate; the panel independently checks it. |
| Monitoring/recovery | Operator verifies `head()` against the question-chain RPC counter before activation and monitors one-shot callback failure, clock availability, signer incidents, expired unspent reserves and confirmed chain state. Owner incident calls are exceptional; users pay their own workflow gas. |

Use `python3 script/preflight_automatic.py --rpc <RPC> --requester <actual address> --deployer
<actual address> --spec <full spec file>` for code/configuration checks without signing/sending.
Preflight also requires `maxPrice() == maxPriceOf(asset()) > 0`; missing or inconsistent getters fail closed.
Automatic deployment CLI reads the exact stored candidate and reviewed commit. Supply only
`--rpc`, `--deployer`, `--job`, `--creation-code` and `--constructor-args` to `python3 -m sdk.gated_deploy`;
it needs no result JSON or manual artifact metadata. It checks the signed approval and final gate
through eth_call before printing unsigned calldata.

Use `python3 -m sdk.automatic --help` for unsigned approve/open/commit/verdict/retry/refund
transactions, `renew <jobId>` for a simulated unsigned renewal, `reserve <jobId>` for the token,
amount, cancellation flag and reserve deadline, and `status <askId>` for native-window readiness.
Use `top-up <jobId> --amount <positive token base units>` to prepare an unsigned **bounded approval
and separate top-up** using the original token. The SDK checks ownership, phase, candidate,
current ask, cancellation and `maxPriceOf(reserve.token)` before printing either transaction. Execute the approval
and top-up separately, then invoke `reserve` and `status` again for readback.
The [wallet UI](../site/automatic.html) provides separate top-up approval and funding buttons.
Both approval buttons require an **exact** allowance readback and never send the funding
transaction themselves. Top-up reads the original token's `maxPriceOf(address)` (selector
`0xc9638491`) with no compatibility fallback. It rechecks eligibility/cap before funding and
requires unchanged job/ask/candidate/ask context, the exact reserve increase, a nondecreasing
deadline and refreshed native maturity after the receipt. An approval alone does not fund the ask.

Connect pins the provider object, its request function, account, chain ID and requester address.
Every button, including Connect and Status, shares one busy lock. Each action freezes all raw
form values before awaiting the wallet; all targets, calldata and readbacks use those snapshots.
Every RPC operation checks local context and the wallet account/chain before and after the call.
Input/change events advance a revision, so editing and restoring a field during an operation
still aborts it. Requester edits and wallet account/chain/disconnect events invalidate the
connection; detected provider, request-function or in-flight form drift also requires reconnecting.
Ordinary edits to other fields between completed actions are captured by the next action.

Send payloads explicitly contain `from`, `chainId`, `to`, `data` and `value: '0x0'`; estimation gets
a separate copy. The UI records a returned transaction hash **before** post-send context checks.
If context drifts after submission, it displays the hash and withholds success: reconnect, inspect
that transaction on its original chain, and read fresh state before deciding whether to submit
again. A rejected UI readback cannot cancel or roll back a submitted transaction. Receipt polling
is bounded to 120 seconds and proves inclusion only; the operator/user still checks finality.
No success is shown before final context and applicable readback checks pass. These checks trust
the installed wallet to report its state and RPC results honestly; they do not make separate
latest-state reads an atomic snapshot or prevent onchain changes after the last read.
SDK and UI check Delivered before commitment. Each SDK invocation reads one pinned
block; make a fresh invocation after any transaction. The UI displays the reserve deadline in Unix seconds, native head, closing block and blocks remaining, and reads readiness again before
requesting a verdict. Both SDK and UI fail closed on unavailable or malformed clock/readiness/funding calls. They
require a positive live quote within reserve and never substitute a current-protocol quote for
the snapshotted context or an RPC/L1 height for the native clock. Readiness is a snapshot; prices
can still change before inclusion, in which case the contract reverts without spending.
The UI uses textContent and never fetches a worker URI or asks a backend to sign.

## Evidence and limitations

[Current audit-fix regressions and checks](checks/audit-dde20fdc/README.md) record this build.
[Full-horizon policy regressions](checks/audit-7db42bb7/README.md) are historical evidence.
[Earlier window regressions and free checks](checks/oracle-window/README.md) are historical evidence. [Earlier automatic-binding vectors and logs](checks/automatic-binding/README.md)
remain historical evidence. Together they distinguish:

- Four genuine public v2 signatures and canonical preimages (price, two panel/bool, panel/uint256
  with definitions). The required 76587543 vector exactly reproduces its live questionHash.
- Offline/local contract tests, including cold callback gas, Delivered-before-commit and renewal,
  legacy callback/binding orders, refund accounting, swaps, tampering and genuine hook execution.
- Free public checks of the exact emitted Ethereum/Robinhood examples. Both job bodies have no
  blockers. Exact oracle-body checks return HTTP 400 because the free endpoint rejects v, window,
  definitions, quorum, validForSeconds and consumer; its documented drafting subset returns no
  blockers and a not_answerable suggestion for local fixture identities. Both exact requests and
  responses, and the separate drafting requests/responses, are retained. Neither proves full
  oracle-body admission or live correctness. The retained prefix encoding is also compared locally with
  the official OracleQuestion implementation and its independent signed-question vector.

A live end-to-end Hooks Store build, accepted independent review, automatic callback and deployment
has **not** been performed or claimed. No live proof can be manufactured from these unrelated
vectors. An independently reviewed release and a separately authorized operational pilot remain
operator responsibilities; tests are not a security audit.
