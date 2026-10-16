# IMD request integration (no backend)

`src/imd/HookJobRequester.sol` lets a creator's wallet buy an IdentityMD `job.open` for standalone-hook code and lets any static website show that job's status, read straight from the chain. Nothing here was deployed, and no paid request was submitted. Everything was exercised locally against `test/helpers/MockIntake.sol`, which stands in for the Intake.

## Flow

1. **Wallet-approved request.** The creator approves `intake.priceOf(jobAction, IMD)` IMD (0.5 IMD today) to `HookJobRequester`, then calls `openJob(specHash, brief)`. The contract pulls exactly that price, but never more than the owner's ceiling `maxPrice` (a constructor argument, moved with the asset by `setPayment`): if the Intake's price rose above it, the call reverts `PriceAboveCeiling` before anything is pulled, so a wallet that gave an unlimited allowance is not exposed to a price move. It approves the price to the Intake and calls Intake v2 `requestWithFailure(jobAction, body, {this, onJobResult}, onJobFailure, IMD, price)`. With the owner's `failureHook` off (for a version 1 Intake, which has no `requestWithFailure`) it calls `request(...)` instead and a refused job is closed only by its deadline. It then resets the allowance to zero and holds nothing. The price is spent once the request is made. There is no refund.
2. **Body.** The body is `jobBodyPrefix ++ "0x<specHash>" ++ jobBodyMiddle ++ brief ++ jobBodySuffix`. The owner's template must contain `forge build`, `forge test` and `adversarial review`, so every job names the build, test and adversarial-review steps. `setJobTemplate` refuses a template without them. The brief is untrusted: it must be 1–2000 bytes of strict UTF-8, with no `"`, `\`, `<`, `>`, control characters or DEL. It sits between `<brief>`…`</brief>`, which the template declares to be data, not instructions. The whole body is capped at 16 KiB.
3. **Request-ID tracking.** The Intake's returned id keys `getJob(id)`, `jobIds[]`, `jobsOf(wallet)` and the `JobOpened(requestId, requester, specHash, price, body)` event. A zero id or any Intake id previously used by a job or review ask is refused, including failed, expired and settled reviews. The used-ID record is never deleted. Every event the contract emits carries the request id as its first indexed topic, so one `eth_getLogs` filter returns a job's whole history.
4. **Result or failure: authenticated and one-time.** `onJobResult` and `onJobFailure` accept calls only from the configured Intake (`msg.sender`), only for an `Open` job this contract created, and only once. After either one, every later result or failure call reverts `UnknownOrSettled`. A failure (status 1 = refused, 2 = no result) records `status` and `reason`. Its values are unsigned and only close the job. A job with no answer can be expired by its requester after `jobTimeout` (7 days by default). A late callback after that is refused.
5. **Review verdict.** A delivery is not a review verdict. `requestReview(jobId)`, by the job's requester and allowed once the job is `Delivered` or `Expired`, buys an `oracle.request` (0.5 IMD) asking whether that job's adversarial-review step passed. The answer arrives in `onReviewResult` as the protocol's `OracleAttestation`, signed by the IdentityMD oracle signer in **this contract's** EIP-712 domain. The contract accepts it only if:
   - it comes from the Intake,
   - its Intake ID names a pending ask whose deadline has not passed,
   - the owner has called `bindReview` for that ask, after independently verifying the mapping and question described below,
   - the signed `requestId`, `questionHash`, `chainId`, `fromBlock` and `toBlock` exactly match that immutable binding,
   - the panel meets the minimum size and quorum/agreement snapshotted when the ask was paid for, with `minAgreed ≤ quorum ≤ agreed ≤ panelSize`,
   - the attestation is still valid, correctly signed and issued no earlier than the ask,
   - it is consumed once and has type bool.

   Only this sets `Passed` or `NotPassed`. A refused or unagreed ask (`onReviewFailure`) or an expired ask (`expireReview`, after `reviewTimeout`) sets `Unanswered` and allows a new ask. The digest matches the protocol vector (`test/OracleConformance.t.sol`).

Callbacks run under the Intake's 200,000-gas stipend. Success tests exercise the mock's stipend with both ECDSA and an ERC-1271 registry; failure tests also call the consumer directly to assert exact revert reasons. This does not establish the gas cost of an arbitrary live registry.

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
panel minimums, and (initially unset) binding. The owner must call:

```solidity
bindReview(
    intakeRequestId, expectedBodyHash, oracleRequestId,
    canonicalQuestionHash, questionChainId, fromBlock, toBlock
)
```

This is a **new per-ask operational responsibility**, not a one-time deployment setting:

1. Read the confirmed `ReviewRequested` event and `getReviewAsk`. Verify the exact body against the
   job ID, intended review wording, chain, definitions and panel requirements. Pass its exact
   `keccak256(body)` as `expectedBodyHash` to protect against selecting the wrong ask in calldata.
2. Independently establish the corresponding oracle UUID and resolved question document from
   authenticated protocol records. Recompute `oracleQuestionHash` using the protocol's actual
   canonicalization. Do not copy a relay-supplied hash without checking what it commits to. Check
   the chain and resolved blocks against the paid body. No canonicalization implementation or
   live mapping endpoint is invented in this repository.
3. As owner, pin that UUID, canonical hash, question chain and block window **before the one-shot
   callback is attempted**. Check the `ReviewBound` event and stored fields. Binding is owner-only,
   nonzero, once per ask, and cannot be overwritten. Oracle UUIDs remain reserved even after an
   unanswered ask, so the next attempt needs a fresh UUID. If the binding was wrong, wait for the
   deadline and expire the ask; there is no rebind escape hatch.

The callback refuses unbound asks with `ReviewNotBound` and any field mismatch with
`ReviewAttestationMismatch`, before consumption or verdict state changes. The same question may
be asked again after failure/expiry, but its new ask must use a fresh Intake ID and oracle UUID.
An old signed answer cannot settle that retry, even if the question hash is identical. Answers
are refused after the ask deadline even before `expireReview` is called; at the exact deadline
they may settle. `issuedAt >= askedAt` is deliberately strict and can reject a slightly skewed
attester clock; the live pilot must check timestamp behavior. Unsigned failure notices still only
close their own pending asks and need no binding.

**Trust and availability:** the owner authenticates the body-to-oracle/question mapping. The
oracle signature authenticates the pinned fields and verdict; it does not independently prove
that the owner chose the correct mapping. A bad owner binding can approve the wrong question,
and a missing/late binding prevents delivery. The owner already controls the trusted Intake and
signer; this responsibility must not be delegated to an untrusted requester or callback writer.
The local mock hash is explicitly synthetic, not evidence of canonical question compatibility.

The current reference does not establish how the mapping and resolved question can be obtained
before callback dispatch. Until a live pilot demonstrates that workflow, review delivery is
**not production-ready**. If no such pre-delivery workflow exists, the protocol needs an
authenticated mapping/preflight facility before this integration can be used. Do not remove the
binding checks, trust equality, substitute a raw-body hash, or spend on unverified production
asks as a workaround. An early callback is refused once by the Intake, which does not retry;
requesters must then expire the ask and the paid price is not refunded.

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

`site/index.html` is one HTML file with no dependencies. On a JSON-RPC endpoint the visitor chooses (a public RPC of the chain, or the wallet's injected provider) it calls `getJob(bytes32)` with `eth_call` for one job, `jobsOf(address)` to list a creator wallet's jobs with each one's status, and `eth_getLogs` filtered on the contract address, the eight job/review event topics and the request id for the job's history (block, event, transaction hash). It never contacts api.imd.fun, so browser CORS on that API is irrelevant. The selectors and topic hashes it hard-codes are pinned by `testStaticSiteReadContract`, and the same three RPC calls were replayed from outside the EVM against a disposable local Anvil in this job: the wallet list, the 15-word job decode and the event order (`JobOpened`, `JobDelivered`, `ReviewRequested`, `ReviewUnanswered`) came back as the page expects. Many public nodes cap `eth_getLogs` block ranges, so the page takes a "from block" (give the contract's deployment block); when the range is refused the job status still shows and the history row says so. It shows:

| On chain | Shown as |
|---|---|
| `status` Open / Delivered / Failed (+status, reason) / Expired | Job status, labelled "reported by the Intake". Delivery is an unsigned completion notice. |
| `review` None / Pending / Unanswered | "No verified review result" |
| `review` Passed / NotPassed + `reviewPanelSize`, `reviewAgreed`, `reviewPanelJobId` | "IMD oracle panel attested the review step passed / did not pass (N of M agreed)" |

The page never shows "audited". `Passed` means a signed oracle panel answer that the job's adversarial-review step passed. It is not an audit of the hook, and it is not proof that the code delivered is the code someone deploys.

### Blocker for a static review status

Without the oracle step, a static website **cannot reliably tell whether review passed**. The Intake's job completion is unsigned, carries no review verdict, and its `job.open` callback ABI was not in this task's protocol references. The job page on api.imd.fun cannot be read from an arbitrary origin and would not be chain-verifiable anyway. With the oracle step, review status depends on a live pilot confirming that the panel can read the job's review outcome, the definitions pin it unambiguously, and the owner can obtain and bind the correct oracle identity and canonical question before delivery. Until then, the site shows "No verified review result".

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
| `setReviewTemplate(action, prefix, suffix, minPanel, minAgreed)` | `bytes32("oracle.request@oracle-1")` = `0x6f7261636c652e72657175657374406f7261636c652d31000000000000000000`, the review question with the right `chainId`, and panel minimums no lower than the body's panel size and quorum | Oracle-consumer reference. Fix `chainId` and the definitions for the launch chain. Confirm the wording with `POST /requests/check` from an operator machine. |
| `bindReview(intakeId, bodyHash, oracleId, questionHash, chainId, fromBlock, toBlock)` | Once for each pending review, before callback. Confirm the body fingerprint and independently verify the exact oracle UUID/canonical question/window; see binding procedure above | Authenticated protocol mapping and canonical question document; live availability not yet verified |
| `transferOwnership(proposedOwner)` / `acceptOwnership()` | Two-step owner rotation; zero and self addresses are rejected. The current owner retains authority until the nominee accepts and may replace/cancel (`cancelOwnershipTransfer`) a mistaken nomination | The requester-approved operational wallet/multisig |
| `setTimeouts(job, review)` | Optional; 1 hour to 30 days, default 7 days and 1 day | Owner's operational choice |
| `setPayment(asset, maxPrice)` | The IMD token and the most one ask may cost, together. Raise `maxPrice` when the published price moves up; the contract still pulls only the current price | `Intake.priceOf(action, imd)` on the chain |
| `setFailureHook(on)` | Leave on (the default) against Intake v2. Turn off only if the contract is pointed at Intake v1, which has no `requestWithFailure` | The Intake version in use |
| `setIntake`, `setOracleSigner` | For protocol moves or signer rotation. Operationally, drain pending work first; **the contract does not enforce that**. These settings take effect immediately on previously opened jobs and pending reviews | IdentityMD announcements |
| `sweep(token, to, amount)` | Recovers tokens sent by mistake | — |

The owner can change templates, signer, Intake, asset, price ceiling, timeouts and the failure hook,
and binds each review's identity/question. **Current Intake and signer settings apply to requests
already open or pending as well as future requests.** A malicious owner can set the Intake to its
own address, replace the signer with its own key, report completion/failure for an already-open
job or forge a verdict matching an already-bound pending review, then restore both settings.
There is no timelock or per-ask Intake/signer snapshot. `IntakeSet`/`OracleSignerSet` events expose
rotations; a status badge alone does not explain them. A rotation can also strand pending work.
The deadline, paid body and panel minimums are snapshotted per review; template/timeout changes
apply to later asks. Bindings cannot be rewritten, but signer control still permits forging their
matching fields. Use a multisig, monitor configuration events, and disclose these powers to users.
Two-step ownership protects against accidental loss of control; it does not restrict an accepted
owner's powers or recover an already accepted wrong handover.

## Requires a live Ethereum or Robinhood Chain pilot

- The `job.open` action id, body schema, price and **callback ABI**. `onJobResult(bytes32,bytes)` is this contract's assumption. If the live callback has another shape, it reverts inside the Intake's try, the job stays Open, and the requester expires it after the deadline. That path is tested, and it fails safe, but delivery then never shows.
- Whether `job.open` accepts this contract as the callback target and calls `onJobFailure` on status 1 or 2.
- Whether an oracle panel can answer the review question reliably from public job evidence, and how fast.
- The exact Intake ID ↔ oracle UUID relationship and its authenticated source; canonical question-hash construction and resolved window; whether these are available to the owner **before** one-shot dispatch. Both IDs may differ and the raw-body hash is not a substitute. Unbound/mismatched answers stay pending and can only time out after a missed dispatch.
- Timestamp ordering: signatures must have `issuedAt >= askedAt` and arrive before the stored review deadline.
- The real oracle signature path end to end. Locally, the protocol's EIP-712 vector digest matches, and the protocol's vector key is accepted.
- Gas of real callbacks under the 200,000 stipend on each chain. Local measurement covers the mock path only.
- Public RPC choice, `eth_getLogs` range caps and rate limits for the static page. Reorg and finality display. The page's RPC calls were replayed only against a local Anvil.
- Whether live Intake IDs or oracle UUIDs repeat across actions, retries or protocol migrations. Both histories remain reserved; repeated IDs are refused, including after failed/expired asks.

None of this was run: no paid request was submitted and nothing was deployed. Base has no Intake yet. An independent adversarial review is still needed before this holds anyone's IMD.
