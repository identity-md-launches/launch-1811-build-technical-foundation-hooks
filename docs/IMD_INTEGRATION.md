# IMD request integration (no backend)

`src/imd/HookJobRequester.sol` lets a creator's wallet buy an IdentityMD `job.open` for standalone-hook code and lets any static website show that job's status, read straight from the chain. Nothing here was deployed, and no paid request was submitted. Everything was exercised locally against `test/helpers/MockIntake.sol`, which stands in for the Intake.

## Flow

1. **Wallet-approved request.** The creator approves `intake.priceOf(jobAction, IMD)` IMD (0.5 IMD in the supplied reference) to `HookJobRequester`, then calls `openJob(specHash, brief)`. The contract pulls exactly that price, but never more than the owner's ceiling `maxPrice` (a constructor argument, moved with the asset by `setPayment`): if the Intake's price rose above it, the call reverts `PriceAboveCeiling` before anything is pulled, so a wallet that gave an unlimited allowance is not exposed to a price move. It approves the price to the Intake and calls Intake v2 `requestWithFailure(jobAction, body, {this, onJobResult}, onJobFailure, IMD, price)`. With the owner's `failureHook` off (for a version 1 Intake, which has no `requestWithFailure`) it calls `request(...)` instead and a refused job is closed only by its deadline. It then resets the allowance to zero and holds nothing. The price is spent once the request is made. There is no refund.
2. **Body.** The body is `jobBodyPrefix ++ "0x<specHash>" ++ jobBodyMiddle ++ brief ++ jobBodySuffix`. The owner's template must contain `forge build`, `forge test` and `adversarial review`, so every job names the build, test and adversarial-review steps. `setJobTemplate` refuses a template without them. The brief is untrusted: it must be 1–2000 bytes of strict UTF-8, with no `"`, `\`, `<`, `>`, control characters or DEL. It sits between `<brief>`…`</brief>`, which the template declares to be data, not instructions. The whole body is capped at 16 KiB.
3. **Request-ID tracking.** The Intake's returned id keys `getJob(id)`, `jobIds[]`, `jobsOf(wallet)` and the `JobOpened(requestId, requester, specHash, price, body)` event. A zero id or any Intake id previously used by a job or review ask is refused, including failed, expired, discarded and settled reviews. The used-ID record is never deleted. Job/review lifecycle events carry the job ID as their first indexed topic; configuration and reservation-release events are monitored separately.
4. **Result or failure: authenticated and one-time.** `onJobResult` and `onJobFailure` accept calls only from the configured Intake (`msg.sender`), only for an `Open` job this contract created, and only once. After either one, every later result or failure call reverts `UnknownOrSettled`. A failure (status 1 = refused, 2 = no result) records `status` and `reason`. Its values are unsigned and only close the job. A job with no answer can be expired by its requester after `jobTimeout` (7 days by default). A late callback after that is refused.
5. **Review receipt and verdict.** A job delivery is not a review verdict. `requestReview(jobId)`, by the job's requester and allowed once the job is `Delivered` or `Expired`, buys an `oracle.request` asking whether that job's adversarial-review step passed. The answer arrives in `onReviewResult` as the protocol's `OracleAttestation`, signed by the IdentityMD oracle signer in **this contract's** EIP-712 domain. Receipt requires:
   - it comes from the Intake,
   - its Intake ID names a still-pending ask with no previous receipt; an expiry request alone does not close it,
   - nonzero signed oracle UUID, question hash and question chain, with `fromBlock <= toBlock`,
   - the panel meets the minimum size and quorum/agreement snapshotted when the ask was paid for, with `minAgreed ≤ quorum ≤ agreed ≤ panelSize`,
   - the signature is valid on arrival, `now <= expiresAt`, `issuedAt <= now + 300`, and `issuedAt + 300 >= askedAt`,
   - the answer decodes as bool and the oracle UUID is not consumed. Another ask's reservation does not block an unbound receipt; it still blocks binding/finalization.

   If the owner already bound the ask, every signed identity/question/window field must match and the callback consumes the UUID and sets `Passed` or `NotPassed`. Otherwise it stores a `ReviewReceipt` and emits `ReviewReceived`, **without consuming/reserving the UUID or setting a verdict**. A later matching `bindReview` finalizes that receipt atomically, with no second callback, signature submission or Intake fee. The digest matches the protocol vector (`test/OracleConformance.t.sol`).

   A refused or unagreed ask (`onReviewFailure`, before a receipt) sets `Unanswered` and permits a new paid ask. After `reviewTimeout`, the requester can call `expireReview(jobId)` **only without a receipt**, but this now requests closure: the ask stays `Pending`, accepts delivery/binding, and blocks retries. Only the owner's `confirmReviewExpiry(intakeId)` closes it, after independently checking that no valid answer will be delivered. Both callback/expiry-request orders preserve a late valid answer. Owner-confirmed closure is terminal for that Intake ID. A retained answer can only be finalized or closed through guarded owner recovery below.

Callbacks run under the Intake's 200,000-gas stipend. `ReviewDelivery.t.sol` and `ReviewReceiptGas.t.sol` use the mock's one-attempt path with cold requester/signer access, including ECDSA, EIP-7702 key signatures, a 5-of-7 ERC-1271 signer and the audit's 22-cold-read stressor. They verify retained answers and irrevocable fee loss for invalid or over-budget callbacks. Direct calls in other tests probe revert reasons; they do not claim that Intake retries. See the callback budget below; the actual production signer and Intake still require a pilot.

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
   overwritten. A bad **pre-binding** cannot be corrected in place; close the undelivered ask via
   failure/expiry and use guarded reservation recovery if needed. Use the receipt-first workflow
   rather than guess. UUID reservations are never released automatically. Every used Intake ID
   remains reserved forever. A retry needs its own independently authenticated mapping even if
   the protocol repeats a UUID or question wording.

The two possible orders are:

```text
ask → verified receipt (Pending, no UUID consumption) → exact owner binding → verdict
ask → exact owner binding (Pending, UUID reserved) → matching verified callback → verdict
```

Unconfirmed receipts do not reserve UUIDs: a swapped or duplicated unbound delivery must not
prevent the real ask from binding that UUID. Matching a receipt is necessary but insufficient;
the owner must verify which ask owns it. While reserved, a UUID cannot be bound elsewhere; once
consumed it cannot be delivered or finalized again, even by the owner. Swapped yes/no receipts
cannot finalize under their independently correct bindings. Blindly confirming the swapped
fields WOULD set the wrong verdict and consume the other ask's UUID: compare independent records
and use recovery on a mismatch. A second callback/failure cannot overwrite or clear a receipt.
Failure notices before receipt still only close their own pending asks, without binding.

Freshness and signer validity are checked **at receipt**, exactly when an already-bound callback
would have settled. Confirmation may happen after the signature's expiry or the local deadline:
it applies an already verified historical answer, rather than accepting a new expired signature.
Signer rotation or ERC-1271 revocation after receipt does not invalidate that stored verification.
No second signature verification or external call occurs during confirmation. Before receipt,
expired signatures still fail, and clock skew exceeding 300 seconds at either checked boundary
still fails. Timestamp arithmetic widens before adding the backward tolerance.

Only the requester can **request** expiry, strictly after the snapshotted deadline and only
without a receipt. `ReviewExpiryRequested(jobId, intakeId)` and `reviewExpiryRequested(intakeId)`
record that request; the flag is historical and does not change status or delivery eligibility.
The request cannot erase an in-flight NotPassed, nor enable an immediate paid retry. Binding may
still precede or follow the callback. The owner can call `confirmReviewExpiry(intakeId)` only for
that exact pending, expiry-requested Intake ID and only while no receipt exists. A receipt arriving
first blocks confirmation; a bound callback settles and makes the approval stale. An approval for
an old ask cannot affect a later retry, even after the retry's deadline.

Owner confirmation is an explicit **trust and availability tradeoff**, not an onchain proof that
Intake has no answer. Before approving, establish that Intake is terminal without a valid pending
callback (for example, an already failed one-shot delivery), and retain the protocol evidence.
Never approve solely because a requester asks or the deadline passed. If that evidence is unavailable,
leave the ask pending. A mistaken or malicious owner confirmation can still discard a later answer;
this cannot be prevented by a finite grace period while arbitrarily late fresh answers are supported.
An unavailable owner can delay retries indefinitely. Intake's authenticated failure callback remains
an independent closure path before receipt.

**Trust and availability:** the owner authenticates the body-to-oracle/question mapping offchain. The contract does not independently authenticate this mapping onchain. The
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

## Owner recovery

For a misdelivered receipt, independently authenticate the **true** context of the paid ask using
the binding procedure above, then call:

```solidity
discardReviewReceipt(intakeId, bodyHash, oracleId, questionHash, chainId, fromBlock, toBlock)
```

The current owner alone can call this. The ask must be pending and unbound, a receipt must exist,
the body fingerprint must match, and the supplied context must be well formed. There are two paths:

| Supplied context | Required checks | Closure reason |
|---|---|---|
| Different UUID from the receipt | The supplied true UUID must be unconsumed and unreserved, just as for a fresh binding | `misdelivered receipt` |
| Same UUID as the receipt | **Every** question/chain/window field must match, and the UUID must be consumed or reserved by a different ask | `receipt UUID conflict` |

A same-UUID field typo reverts `ReviewAttestationMismatch`, even if that UUID conflicts elsewhere.
A same-UUID exact match without a conflict reverts `ReviewReceiptMatches`. A different supplied
UUID that is consumed or reserved reverts `DuplicateRequestId`; even a terminal reservation must
be released before using that UUID as a proposed true context. Negative value, age, signer rotation
or signature expiry alone never justify discarding a receipt. Incorrect same-UUID signed fields
cannot be waved away as a misdelivery: resolve the protocol inconsistency, rather than invent a
replacement UUID. There is no general receipt revocation operation.

A matching receipt whose UUID was consumed/reserved by another ask can thus be closed honestly,
without inventing a mismatch, clearing consumption or stealing the other reservation. If the holder
is terminal without a receipt and the protocol mapping really authorizes UUID reuse, prefer releasing
that unused reservation and binding the retained receipt; this preserves its verdict without a new fee.

Successful discard closes the ask as `Unanswered` without charging a fee, marks
`discardedReviewReceipts(intakeId)`, and emits `ReviewReceiptDiscarded` with the received UUID and
the **owner-supplied** context, followed by `ReviewUnanswered` with the reason above. The complete
original receipt remains readable and the old Intake ID stays terminal and permanently used.
No UUID is reserved, released or consumed by discard. Nothing is retried or rerouted. A replacement
ask costs the normal price; recovery/expiry never refunds a spent fee. The contract checks consistency,
not authenticity of an offchain mapping: a dishonest owner can still invent an available different
UUID or reserve a receipt's UUID to another ask. These powers stay within the owner-trust boundary.

For an unused UUID reservation, close its holder through Intake failure or owner-confirmed expiry,
check the protocol's retry mapping, then call `releaseReservation(oracleId)`. Only the owner may
release, and only if the UUID is reserved and unconsumed, the holder's `reviewOf` is zero, and that
holder has no receipt. Merely passing the deadline or requesting expiry is insufficient.
`ReviewReservationReleased(oracleId, intakeId)` records release; original binding and used Intake ID
history remain unchanged. A second release reverts. Consumed UUIDs can never be released.

An unbound retry's one-shot callback now retains a valid, unconsumed receipt **even before release**;
it makes no reservation or verdict. After release, exact binding finalizes that retained answer with
no callback retry or extra fee. Another ask's still-active reservation likewise does not burn receipt
delivery, but cannot be released: wait for its resolution or use exact-conflict closure. Binding always
requires an available UUID. Already consumed UUIDs still fail callback delivery and cannot be replayed.

## Callback gas budget

The callback stores four full-width context words and one packed metadata word; it does not
truncate UUIDs, chain IDs or question hashes. `requestReview` preallocates bit 255 of the metadata
word (about 22.1k additional request-transaction storage gas). Receipt writes that existing word
once at a nonzero-to-nonzero cost, instead of initializing it and repeatedly updating packed
fields inside the callback. Allocation alone returns an empty receipt and cannot act as an answer.
The already verified EIP-712 digest is reused in `ReviewReceived` instead of rehashed. Read ABIs
remain 15 words for `getJob` and 10 each for `getReviewAsk` and `getReviewReceipt`.

With pinned Solidity 0.8.26/Cancun/optimizer 200, local minimum **forwarded** receipt gas is 123,013
for ECDSA, 168,106 for the 5-of-7 signer (five ECDSA recoveries, membership, per-key expiry and
duplicate checks; 325-byte signature), and 185,260 for the audit's registry with 22 extra cold
mapping reads (65-byte signature). Each also passes the exact 200,000-gas one-attempt Intake call.
Binary-search measurements restore state and cool the consumer/signer for every trial; isolated
transaction checks confirm the metadata write costs 5,000 gas, not a dirty-slot discount. The 5-of-7 receipt also uses 168,106 gas after an expiry request and before a retry reservation is released.

Use **60,000 gas as the maximum cold `isValidSignature` execution budget**, with canonical 32-byte
bool answers and signatures no larger than the tested 325 bytes, then measure the entire callback
with the actual registry/proxy, signature and target chain before enabling paid asks. This is an
operational compatibility ceiling, not an enforced per-signer sublimit or a guarantee for arbitrary
ERC-1271 code. Registry upgrades, more signatures, larger payloads and gas-schedule changes require
requalification. The 22-read fixture leaves about 14.7k headroom; the multisigner leaves about
31.9k. A deliberately excessive 64-read signer exhausts the stipend, produces no partial receipt
or consumption, and loses the one-shot attempt and fee. The Intake must also have enough outer
transaction gas to forward its full stipend under EIP-150. See [AUDIT_EF1F6915.md](AUDIT_EF1F6915.md).

## Two retained design choices

**Verification is final at receipt.** Rotating a compromised signer or revoking ERC-1271 keys
stops future verification with those keys but does not invalidate answers already retained.
Those receipts can still finalize after rotation, revocation, signature expiry or local timeout.
There is no incident-response blanket freeze or revoke operation. Stop owner confirmations while
investigating a compromise, inspect receipts and independently authenticate their mappings;
recovery requires a different available UUID or an exact matching context with an onchain UUID conflict, never signer distrust alone.
Confirming after rotation remains an explicit act of the current owner.

**Both verdicts are terminal.** The shipped bool question defines missing, pending or failed review
as false. A truthful false becomes permanent `NotPassed` once confirmed, including for an `Expired`
job whose remote review is still pending. Later completion cannot reopen that job or buy a revised
verdict. Wait for final review evidence before paying for `requestReview`; `Delivered`/`Expired`
is an eligibility check, not proof that evidence is ready. `Unanswered` is reserved for a failure,
owner-confirmed expiry before receipt, misdelivery recovery or exact-context UUID-conflict recovery. No requester verdict shopping or
silent reinterpretation of the existing question is introduced. Tests reproduce both choices.

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

`site/index.html` is one HTML file with no dependencies. On a JSON-RPC endpoint the visitor chooses (a public RPC of the chain, or the wallet's injected provider) it calls `getJob(bytes32)` with `eth_call` for one job, `jobsOf(address)` to list a creator wallet's jobs with each one's status, and `eth_getLogs` filtered on the contract address, the eleven job/review event topics and the request id for the job's history (block, event, transaction hash). It never contacts api.imd.fun, so browser CORS on that API is irrelevant. The selectors and topic hashes it hard-codes are pinned by `testStaticSiteReadContract`. Earlier local Anvil verification covered the unchanged wallet-list and 15-word job reads; the expiry-request event is an addition in this follow-up. Reservation-release events are monitored separately by oracle/Intake ID. Many public nodes cap `eth_getLogs` block ranges, so the page takes a "from block" (give the contract's deployment block); when the range is refused the job status still shows and the history row says so. It shows:

| On chain | Shown as |
|---|---|
| `status` Open / Delivered / Failed (+status, reason) / Expired | Job status, labelled "reported by the Intake". Delivery is an unsigned completion notice. |
| `review` None / Pending / Unanswered | "No verified review result"; Pending may mean awaiting an answer **or owner confirmation**; Unanswered means closed without a finalized verdict |
| `ReviewReceived` history event | Signed answer retained, awaiting owner confirmation; no verdict yet |
| `ReviewReceiptDiscarded` history event | Owner closed a misdelivery or UUID conflict; original receipt kept in history |
| `ReviewExpiryRequested` history event | Awaiting owner closure; callbacks remain open |
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
| `discardReviewReceipt(intakeId, bodyHash, oracleId, questionHash, chainId, fromBlock, toBlock)` | Close an unbound misdelivery with a different available true UUID, or an exact matching receipt with an onchain UUID conflict. Preserve history and UUID state | Check mapping offchain as for binding; no mapping proof is verified onchain |
| `releaseReservation(oracleId)` | Recovery only: release an unconsumed UUID whose holder ask is terminal with no receipt, before or after an unbound retry's callback but before retry binding | Authenticate protocol retry/UUID-reuse records, inspect `reviewOf`, `getReviewReceipt` and `consumed`; retain the original binding history |
| `confirmReviewExpiry(intakeId)` | Close that exact expiry-requested ask only if it still has no receipt; permits a paid retry | Owner must establish Intake will not deliver a valid answer, not just observe a deadline. If uncertain, keep pending; absence is not proven onchain |
| `transferOwnership(proposedOwner)` / `acceptOwnership()` | Two-step owner rotation; zero and self addresses are rejected. The current owner retains authority until the nominee accepts and may replace/cancel (`cancelOwnershipTransfer`) a mistaken nomination | The requester-approved operational wallet/multisig |
| `setTimeouts(job, review)` | Optional; 1 hour to 30 days, defaults 7 days / 1 day. Review timeout enables a requester expiry request; closure requires owner confirmation without a receipt; it does not reject a fresh late answer or confirmation | Owner's operational choice; communicate expiry consequences to requesters |
| `setPayment(asset, maxPrice)` | The IMD token and the most one ask may cost, together. Raise `maxPrice` when the published price moves up; the contract still pulls only the current price | `Intake.priceOf(action, imd)` on the chain |
| `setFailureHook(on)` | Leave on (the default) against Intake v2. Turn off only if the contract is pointed at Intake v1, which has no `requestWithFailure` | The Intake version in use |
| `setIntake`, `setOracleSigner` | For protocol moves or signer rotation. Operationally, drain pending work first; **the contract does not enforce that**. These settings authorize future deliveries even for previously opened jobs and pending reviews; retained receipts keep their completed verification | IdentityMD announcements |
| `sweep(token, to, amount)` | Recovers tokens sent by mistake | — |

The owner can change templates, signer, Intake, asset, price ceiling, timeouts and the failure hook,
binds each review's identity/question, closes owner-reported misdeliveries or UUID conflicts,
confirms expiry requests, and releases unused terminal reservations. **Current Intake and signer settings apply at callback receipt, including requests
already open or pending. Already verified receipts keep their original verification.** A malicious owner can set the Intake to its
own address, replace the signer with its own key, report completion/failure for an already-open
job or forge a verdict matching an already-bound pending review, then restore both settings.
There is no timelock or per-ask Intake/signer snapshot at payment. A retained receipt is immutable
and cannot be replaced by a new Intake callback or invalidated by later signer rotation/revocation. `IntakeSet`/`OracleSignerSet` events expose
rotations; a status badge alone does not explain them. A rotation can also strand work that has not yet received its answer.
The deadline, paid body and panel minimums are snapshotted per review; template/timeout changes
apply to later asks. Bindings cannot be rewritten, but signer control still permits forging their
matching fields before receipt. The current owner may confirm a retained receipt, but cannot rewrite it.
An owner who invents a different available true UUID can also close a receipt as Unanswered; this
recovery power remains inside the existing owner-trust boundary and must not be delegated to a
requester. Use a multisig, monitor configuration/recovery events, and disclose these powers to users.
Two-step ownership protects against accidental loss of control; it does not restrict an accepted
owner's powers or recover an already accepted wrong handover.

## Requires a live Ethereum or Robinhood Chain pilot

- The `job.open` action id, body schema, price and **callback ABI**. `onJobResult(bytes32,bytes)` is this contract's assumption. If the live callback has another shape, it reverts inside the Intake's try, the job stays Open, and the requester expires it after the deadline. That path is tested, and it fails safe, but delivery then never shows.
- Callbacks must be asynchronous, after `request`/`requestWithFailure` returns and this contract records its Intake ID. A synchronous callback during payment is unsupported.
- Whether `job.open` accepts this contract as the callback target and calls `onJobFailure` on status 1 or 2.
- Whether an oracle panel can answer the review question reliably from public job evidence, and how fast.
- The exact Intake ID ↔ oracle UUID relationship and an authenticated **post-delivery** source; canonical question-hash construction, full canonical document and resolved window. Both IDs may differ and the raw-body hash is not a substitute. The retained callback is evidence to compare, not authority for its own pairing. The owner must establish the mapping independently before binding.
- Timestamp behavior: at receipt, `issuedAt + 300 >= askedAt`, `issuedAt <= now + 300` and `now <= expiresAt`. The local review deadline only enables requesting owner-assisted expiry. Confirm actual signing time/lifetime and delivery latency fit those checks.
- The real oracle signature path end to end. Locally, the protocol's EIP-712 vector digest matches, and the protocol's vector key is accepted.
- Gas of real callbacks under the 200,000 stipend on each chain, including the actual signer/registry and its signature size. Apply the 60k cold signer budget and measure the entire receipt-first callback, including four new context slots and the preallocated metadata word. Recheck on every signer/proxy/policy change; local fixtures do not qualify arbitrary live registries.
- Public RPC choice, `eth_getLogs` range caps and rate limits for the static page. Reorg and finality display. The page's RPC calls were replayed only against a local Anvil.
- Authenticated Intake terminality/failed-callback evidence for owner-assisted expiry. Neither a deadline nor a requester assertion proves there is no valid answer in flight.
- Whether live Intake IDs or oracle UUIDs repeat across actions, retries or protocol migrations. All used Intake IDs remain reserved. Consumed UUIDs can never be reused. An unused reservation can be released only by the owner after its holder closes without a receipt, with independently authenticated retry mapping. Unconfirmed receipts deliberately do not reserve UUIDs.

None of this live pilot was run: no paid request was submitted and nothing was deployed. The project's supplied references do not provide a Base Intake; Base support remains unverified. An independent adversarial review is still needed before this holds anyone's IMD.
