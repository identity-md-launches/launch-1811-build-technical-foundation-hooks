# IMD request integration (no backend)

`src/imd/HookJobRequester.sol` lets a creator's wallet buy an IdentityMD `job.open` for standalone-hook code and lets any static website show that job's status, read straight from the chain. Nothing here was deployed, and no paid request was submitted. Everything was exercised locally against `test/helpers/MockIntake.sol`, which stands in for the Intake.

## Flow

1. **Wallet-approved request.** The creator approves `intake.priceOf(jobAction, IMD)` IMD (0.5 IMD in the supplied reference) to `HookJobRequester`, then calls `openJob(specHash, brief)`. The contract pulls exactly that price, but never more than the owner's ceiling `maxPrice` (a constructor argument, moved with the asset by `setPayment`): if the Intake's price rose above it, the call reverts `PriceAboveCeiling` before anything is pulled, so a wallet that gave an unlimited allowance is not exposed to a price move. It approves the price to the Intake and calls Intake v2 `requestWithFailure(jobAction, body, {this, onJobResult}, onJobFailure, IMD, price)`. With the owner's `failureHook` off (for a version 1 Intake, which has no `requestWithFailure`) it calls `request(...)` instead and a refused job is closed only by its deadline. It then resets the allowance to zero and holds nothing. The price is spent once the request is made. There is no refund.
2. **Body.** The body is `jobBodyPrefix ++ "0x<specHash>" ++ jobBodyMiddle ++ brief ++ jobBodySuffix`. The owner's template must contain `forge build`, `forge test` and `adversarial review`, so every job names the build, test and adversarial-review steps. `setJobTemplate` refuses a template without them. The brief is untrusted: it must be 1–2000 bytes of strict UTF-8, with no `"`, `\`, `<`, `>`, control characters or DEL. It sits between `<brief>`…`</brief>`, which the template declares to be data, not instructions. The whole body is capped at 16 KiB.
3. **Request-ID tracking.** The Intake's returned id keys `getJob(id)`, `jobIds[]`, `jobsOf(wallet)` and the `JobOpened(requestId, requester, specHash, price, body)` event. A zero id or any Intake id previously used by a job or review ask is refused, including failed, expired and settled reviews. The used-ID record is never deleted. Every event the contract emits carries the request id as its first indexed topic, so one `eth_getLogs` filter returns a job's whole history.
4. **Result or failure: authenticated and one-time.** `onJobResult` and `onJobFailure` accept calls only from the configured Intake (`msg.sender`), only for an `Open` job this contract created, and only once. After either one, every later result or failure call reverts `UnknownOrSettled`. A failure (status 1 = refused, 2 = no result) records `status` and `reason`. Its values are unsigned and only close the job. A job with no answer can be expired by its requester after `jobTimeout` (7 days by default). A late callback after that is refused.
5. **Review receipt and verdict.** A job delivery is not a review verdict. `requestReview(jobId)`, by the job's requester and allowed once the job is `Delivered` or `Expired`, buys an `oracle.request` asking whether that job's adversarial-review step passed. The answer arrives in `onReviewResult` as the protocol's `OracleAttestation`, signed by the IdentityMD oracle signer in **this contract's** EIP-712 domain. Receipt requires:
   - it comes from the Intake,
   - its Intake ID names a still-pending ask with no previous receipt; the requester has not explicitly expired it,
   - nonzero signed oracle UUID, question hash and question chain, with `fromBlock <= toBlock`,
   - the panel meets the minimum size and quorum/agreement snapshotted when the ask was paid for, with `minAgreed ≤ quorum ≤ agreed ≤ panelSize`,
   - the signature is valid on arrival, `now <= expiresAt`, `issuedAt <= now + 300`, and `issuedAt + 300 >= askedAt`,
   - the answer decodes as bool and the oracle UUID is neither consumed nor reserved to another ask.

   If the owner already bound the ask, every signed identity/question/window field must match and the callback consumes the UUID and sets `Passed` or `NotPassed`. Otherwise it stores a `ReviewReceipt` and emits `ReviewReceived`, **without consuming/reserving the UUID or setting a verdict**. A later matching `bindReview` finalizes that receipt atomically, with no second callback, signature submission or Intake fee. The digest matches the protocol vector (`test/OracleConformance.t.sol`).

   A refused or unagreed ask (`onReviewFailure`, before a receipt) or explicit requester expiry (`expireReview`, after `reviewTimeout`) sets `Unanswered` and permits a new paid ask. The deadline enables abandonment; it is not a delivery or binding cutoff. After explicit expiry, no callback or binding can revive that ask. The requester can abandon a retained answer too; the receipt remains readable as history, not an actionable verdict.

Callbacks run under the Intake's 200,000-gas stipend. `ReviewDelivery.t.sol` uses the mock's one-attempt path, including cold requester/signer access and five-slot receipt storage, with ECDSA, EIP-7702 key signatures and an ERC-1271 registry. It verifies both successful recovery and irrevocable fee loss for invalid callbacks. Direct calls in other tests probe revert reasons; they do not claim that Intake retries. An arbitrary live registry's gas use and the actual Intake stipend still need verification.

## Binding each review to its signed answer

The Intake callback's first `bytes32` identifies the paid ask. The signed attestation's `requestId`
identifies an oracle request UUID. The supplied protocol reference says these differ; the audit's
suggested equality check assumed otherwise. This implementation makes **neither an ID-format
assumption nor a conversion guess**. Likewise, `keccak256(reviewBody)` is only a fingerprint of the
submitted JSON; it is **not** the protocol's canonical `questionHash`, which includes the question,
resolved block window and definitions. The relative `window.hours` in the example template cannot
be resolved by this contract when it asks.

`requestReview` records a `ReviewAsk` separately from `Job`, preserving the existing 15-word job
read ABI. `getReviewAsk(intakeRequestId)` returns the body fingerprint, ask timestamp, deadline,
panel minimums, and (initially unset) binding. `getReviewReceipt(intakeRequestId)` returns a retained
answer's UUID, canonical question hash, question chain, panel job ID, resolved blocks, receipt time,
panel size/agreement and bool value. A zero receipt UUID means no receipt. A nonzero one is **not**
proof of a finalized verdict; always consult the job's current review status. The owner must call:

```solidity
bindReview(
    intakeRequestId, expectedBodyHash, oracleRequestId,
    canonicalQuestionHash, questionChainId, fromBlock, toBlock
)
```

This is a **per-ask operational responsibility**, not a one-time deployment setting. The recommended
relative-window workflow is receive first, independently authenticate the mapping, then bind:

1. Read the confirmed `ReviewRequested` event and `getReviewAsk`. Verify the exact body against the
   job ID, intended review wording, chain, definitions and panel requirements. Pass its exact
   `keccak256(body)` as `expectedBodyHash` to protect against selecting the wrong ask in calldata.
2. Independently establish the corresponding oracle UUID and resolved question document from
   authenticated protocol records. Recompute `oracleQuestionHash` using the protocol's actual
   canonicalization. Do not copy a relay-supplied hash without checking what it commits to. Check
   the chain and resolved blocks against the paid body. No canonicalization implementation or
   live mapping endpoint is invented in this repository.
3. Compare those independently established values with the retained receipt, then pin them as
   owner. Do **not** just copy the callback or receipt fields: the signature authenticates an answer,
   not its pairing with this Intake ask. A matching `bindReview` emits `ReviewBound` and
   `ReviewAnswered`, consumes the UUID and finalizes the verdict in one transaction. A mismatch
   reverts before any binding/reservation/consumption, so a mistyped confirmation can be corrected.
   Binding may also precede delivery if the owner already has authenticated values; it then emits
   only `ReviewBound`, and the callback must match them exactly.
4. Check the events and `getJob`. Binding is owner-only, nonzero, once per ask and cannot be
   overwritten. A bad **pre-binding** still strands an ask; use the receipt-first workflow rather
   than guess. Bound UUIDs remain reserved after failure/expiry, and every used Intake ID remains
   reserved. A retry needs its own independently authenticated UUID even for identical wording.

The two possible orders are:

```text
ask → verified receipt (Pending, no UUID consumption) → exact owner binding → verdict
ask → exact owner binding (Pending, UUID reserved) → matching verified callback → verdict
```

Unconfirmed receipts do not reserve UUIDs: a swapped or duplicated unbound delivery must not
prevent the real ask from binding that UUID. Matching a receipt is necessary but insufficient;
the owner must verify which ask owns it. Once bound, a UUID cannot be bound elsewhere, and once
consumed it cannot be delivered or finalized again. Swapped yes/no receipts cannot finalize under
their independently correct bindings. A second callback/failure cannot overwrite or clear a
receipt. Failure notices before receipt still only close their own pending asks, without binding.

Freshness and signer validity are checked **at receipt**, exactly when an already-bound callback
would have settled. Confirmation may happen after the signature's expiry or the local deadline:
it applies an already verified historical answer, rather than accepting a new expired signature.
Signer rotation or ERC-1271 revocation after receipt does not invalidate that stored verification.
No second signature verification or external call occurs during confirmation. Before receipt,
expired signatures still fail, and clock skew exceeding 300 seconds at either checked boundary
still fails. Timestamp arithmetic widens before adding the backward tolerance.

Only the requester can explicitly expire an ask, strictly after its snapshotted deadline. Expiry
and finalization race by transaction order: expiry first permanently closes that ask; finalization
first permanently settles its verdict. An early receipt alone does not remove the requester's
right to abandon it. Check for a receipt and coordinate with the owner before choosing expiry.

**Trust and availability:** the owner authenticates the body-to-oracle/question mapping. The
oracle signature authenticates the pinned fields and verdict; it does not independently prove
that the owner chose the correct mapping. A bad owner binding can approve the wrong question,
and a missing binding prevents finalization. The owner already controls the trusted Intake and
signer; this responsibility must not be delegated to an untrusted requester or callback writer.
The local mock hash is explicitly synthetic, not evidence of canonical question compatibility.

The shipped template intentionally retains `"window":{"hours":1}` and `"validForSeconds":3600`.
Its canonical hash and blocks become available after the plane resolves the window. This is now
compatible with receipt-first confirmation; no pre-dispatch mapping service or callback retry is
required. The one-hour signature lifetime limits **arrival**, not the owner's confirmation time.
The sample `chainId:31337` is for local tests and must be replaced with the actual question chain.

The availability of an **authenticated post-delivery** Intake-to-oracle mapping and canonical
question document still needs a live pilot; a signature alone does not supply that mapping.
Production readiness is not claimed until that and the other pilot items below are demonstrated.
Incorrect ABI, invalid/expired signature, insufficient callback gas, incorrect delivery pairing or
an incorrect pre-binding can still lose the one-shot answer. The fee remains spent, expiry gives
no refund, and a new ask costs another fee. Those failures must never be bypassed to manufacture
a verdict. No additional fee is charged to confirm a correctly retained answer.

## Oracle signer behavior

Verification tries low-s ECDSA recovery against `oracleSigner` first, including when that address
has code, then uses ERC-1271 if recovery did not match. This preserves a key's ordinary signatures
when [EIP-7702](https://eips.ethereum.org/EIPS/eip-7702) adds a delegation designator. It also means a
delegated wallet's ERC-1271 rejection cannot revoke a valid signature by its underlying key.
Use a separately configured ERC-1271 registry when registry policy should control validity.
Wrong keys, malformed ECDSA, invalid ERC-1271 magic values, short responses and reverts fail closed.
The attestation struct, type hash, domain and callback selector are unchanged. Tests retain the
independent protocol digest/signature vector. The pinned Cancun tests emulate the 23-byte
`0xef0100 || delegate` code with `vm.etch`; they do not claim to execute a live type-4 transaction.

## Showing status on a static website

`site/index.html` is one HTML file with no dependencies. On a JSON-RPC endpoint the visitor chooses (a public RPC of the chain, or the wallet's injected provider) it calls `getJob(bytes32)` with `eth_call` for one job, `jobsOf(address)` to list a creator wallet's jobs with each one's status, and `eth_getLogs` filtered on the contract address, the nine job/review event topics and the request id for the job's history (block, event, transaction hash). It never contacts api.imd.fun, so browser CORS on that API is irrelevant. The selectors and topic hashes it hard-codes are pinned by `testStaticSiteReadContract`. Earlier local Anvil verification covered the unchanged wallet-list and 15-word job reads; the receipt event is an addition in this follow-up. Many public nodes cap `eth_getLogs` block ranges, so the page takes a "from block" (give the contract's deployment block); when the range is refused the job status still shows and the history row says so. It shows:

| On chain | Shown as |
|---|---|
| `status` Open / Delivered / Failed (+status, reason) / Expired | Job status, labelled "reported by the Intake". Delivery is an unsigned completion notice. |
| `review` None / Pending / Unanswered | "No verified review result"; Pending may mean awaiting an answer **or owner confirmation**; Unanswered means closed without a finalized verdict |
| `ReviewReceived` history event | Signed answer retained, awaiting owner confirmation; no verdict yet |
| `review` Passed / NotPassed + `reviewPanelSize`, `reviewAgreed`, `reviewPanelJobId` | "IMD oracle panel attested the review step passed / did not pass (N of M agreed)" |

The page never shows "audited". `Passed` means a signed oracle panel answer that the job's adversarial-review step passed. It is not an audit of the hook, and it is not proof that the code delivered is the code someone deploys.

### Blocker for a static review status

Without the oracle step, a static website **cannot reliably tell whether review passed**. The Intake's job completion is unsigned, carries no review verdict, and its `job.open` callback ABI was not in this task's protocol references. The job page on api.imd.fun cannot be read from an arbitrary origin and would not be chain-verifiable anyway. With the oracle step, review status depends on a live pilot confirming that the panel can read the job's review outcome, the definitions pin it unambiguously, and the owner can authenticate the exact oracle identity and canonical question after receipt. A receipt by itself remains "No verified review result" until the owner confirms it.

## After launch

The constructor is `HookJobRequester(owner, intake, imd, oracleSigner, maxPrice)`. The launch's owner must be passed explicitly, never the deploying factory. The constructor calls no other contract; `script/DeployHookJobRequester.s.sol` (`check`, `deploy`, `configure`, tested directly in `DeployHookJobRequester.t.sol`) is where an operator's deployment refuses an Intake or IMD address without code and an action the Intake does not sell within the ceiling. The published values (oracle-consumer reference, 2026-10-10) are:

| Argument | Ethereum (1) | Robinhood Chain (4663) |
|---|---|---|
| `intake` (Intake v2) | `0xa43e6f75ee006411f79ac1c84120606c2330de82` | `0xa43e6f75ee006411f79ac1c84120606c2330de82` |
| `imd` | `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7` | `0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127` |
| `oracleSigner` | `0x5598aa9146215bc13eb26f2c692ad1461fd32982` | `0x5598aa9146215bc13eb26f2c692ad1461fd32982` |
| `maxPrice` | `500000000000000000` (0.5 IMD, the published price) | same |

These addresses were not checked with `cast code` in this job. Check each one on the target chain before deploying.

Until the owner calls these setters, `openJob` reverts `NotConfigured("jobTemplate")` and `requestReview` reverts `NotConfigured("reviewTemplate")`:

| Setter | What to set | Where the owner gets it |
|---|---|---|
| `setJobTemplate(action, prefix, middle, suffix)` | `job.open` action id and body template. The proposed template is in `test/helpers/ImdTemplates.sol`. | The action id string and the `job.open` body schema come from IdentityMD's `docs/onchain-intake.md`. They are **not** guessed here: the tests use `"job.open@test"`. Check the price with `Intake.priceOf(action, imd)`. |
| `setReviewTemplate(action, prefix, suffix, minPanel, minAgreed)` | `bytes32("oracle.request@oracle-1")`, the review question with the right `chainId`, and panel minimums matching the body (7 seats / 5 agreement in the example). Relative `window.hours:1` uses receipt-first confirmation; `validForSeconds:3600` limits arrival | Oracle-consumer reference. Fix `chainId` and the definitions for the launch chain. Confirm the wording with `POST /requests/check` from an operator machine. |
| `bindReview(intakeId, bodyHash, oracleId, questionHash, chainId, fromBlock, toBlock)` | Once per pending review, normally **after receipt**: independently verify the exact UUID/canonical question/window and confirm the body fingerprint. A matching retained receipt finalizes immediately; no additional Intake fee | Authenticated protocol mapping and canonical question document; live post-delivery availability not yet verified |
| `transferOwnership(proposedOwner)` / `acceptOwnership()` | Two-step owner rotation; zero and self addresses are rejected. The current owner retains authority until the nominee accepts and may replace/cancel (`cancelOwnershipTransfer`) a mistaken nomination | The requester-approved operational wallet/multisig |
| `setTimeouts(job, review)` | Optional; 1 hour to 30 days, defaults 7 days / 1 day. Review timeout enables requester abandonment; it does not reject a fresh late answer or confirmation | Owner's operational choice; communicate expiry consequences to requesters |
| `setPayment(asset, maxPrice)` | The IMD token and the most one ask may cost, together. Raise `maxPrice` when the published price moves up; the contract still pulls only the current price | `Intake.priceOf(action, imd)` on the chain |
| `setFailureHook(on)` | Leave on (the default) against Intake v2. Turn off only if the contract is pointed at Intake v1, which has no `requestWithFailure` | The Intake version in use |
| `setIntake`, `setOracleSigner` | For protocol moves or signer rotation. Operationally, drain pending work first; **the contract does not enforce that**. These settings authorize future deliveries even for previously opened jobs and pending reviews; retained receipts keep their completed verification | IdentityMD announcements |
| `sweep(token, to, amount)` | Recovers tokens sent by mistake | — |

The owner can change templates, signer, Intake, asset, price ceiling, timeouts and the failure hook,
and binds each review's identity/question. **Current Intake and signer settings apply at callback receipt, including requests
already open or pending. Already verified receipts keep their original verification.** A malicious owner can set the Intake to its
own address, replace the signer with its own key, report completion/failure for an already-open
job or forge a verdict matching an already-bound pending review, then restore both settings.
There is no timelock or per-ask Intake/signer snapshot at payment. A retained receipt is immutable
and cannot be replaced by a new Intake callback or invalidated by later signer rotation/revocation. `IntakeSet`/`OracleSignerSet` events expose
rotations; a status badge alone does not explain them. A rotation can also strand work that has not yet received its answer.
The deadline, paid body and panel minimums are snapshotted per review; template/timeout changes
apply to later asks. Bindings cannot be rewritten, but signer control still permits forging their
matching fields before receipt. The current owner may confirm a retained receipt, but cannot rewrite it. Use a multisig, monitor configuration events, and disclose these powers to users.
Two-step ownership protects against accidental loss of control; it does not restrict an accepted
owner's powers or recover an already accepted wrong handover.

## Requires a live Ethereum or Robinhood Chain pilot

- The `job.open` action id, body schema, price and **callback ABI**. `onJobResult(bytes32,bytes)` is this contract's assumption. If the live callback has another shape, it reverts inside the Intake's try, the job stays Open, and the requester expires it after the deadline. That path is tested, and it fails safe, but delivery then never shows.
- Callbacks must be asynchronous, after `request`/`requestWithFailure` returns and this contract records its Intake ID. A synchronous callback during payment is unsupported.
- Whether `job.open` accepts this contract as the callback target and calls `onJobFailure` on status 1 or 2.
- Whether an oracle panel can answer the review question reliably from public job evidence, and how fast.
- The exact Intake ID ↔ oracle UUID relationship and an authenticated **post-delivery** source; canonical question-hash construction, full canonical document and resolved window. Both IDs may differ and the raw-body hash is not a substitute. The retained callback is evidence to compare, not authority for its own pairing. The owner must establish the mapping independently before binding.
- Timestamp behavior: at receipt, `issuedAt + 300 >= askedAt`, `issuedAt <= now + 300` and `now <= expiresAt`. The local review deadline only enables explicit expiry. Confirm actual signing time/lifetime and delivery latency fit those checks.
- The real oracle signature path end to end. Locally, the protocol's EIP-712 vector digest matches, and the protocol's vector key is accepted.
- Gas of real callbacks under the 200,000 stipend on each chain, including the five-slot receipt write and the actual signer/registry. Local cold-access tests cover both bound settlement and early receipt, not arbitrary live registries.
- Public RPC choice, `eth_getLogs` range caps and rate limits for the static page. Reorg and finality display. The page's RPC calls were replayed only against a local Anvil.
- Whether live Intake IDs or oracle UUIDs repeat across actions, retries or protocol migrations. All used Intake IDs and bound oracle UUIDs remain reserved, including after failed/expired asks. Unconfirmed receipts deliberately do not reserve UUIDs; only the independently verified owner binding does.

None of this live pilot was run: no paid request was submitted and nothing was deployed. The project's supplied references do not provide a Base Intake; Base support remains unverified. An independent adversarial review is still needed before this holds anyone's IMD.
