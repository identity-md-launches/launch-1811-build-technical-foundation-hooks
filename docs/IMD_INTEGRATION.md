# IMD request integration (no backend)

`src/imd/HookJobRequester.sol` lets a creator's wallet buy an IdentityMD `job.open` for standalone-hook code and lets any static website show that job's status, read straight from the chain. Nothing here was deployed, and no paid request was submitted. Everything was exercised locally against `test/helpers/MockIntake.sol`, which stands in for the Intake.

## Flow

1. **Wallet-approved request.** The creator approves `intake.priceOf(jobAction, IMD)` IMD (0.5 IMD today) to `HookJobRequester`, then calls `openJob(specHash, brief)`. The contract pulls exactly that price, but never more than the owner's ceiling `maxPrice` (a constructor argument, moved with the asset by `setPayment`): if the Intake's price rose above it, the call reverts `PriceAboveCeiling` before anything is pulled, so a wallet that gave an unlimited allowance is not exposed to a price move. It approves the price to the Intake and calls Intake v2 `requestWithFailure(jobAction, body, {this, onJobResult}, onJobFailure, IMD, price)`. With the owner's `failureHook` off (for a version 1 Intake, which has no `requestWithFailure`) it calls `request(...)` instead and a refused job is closed only by its deadline. It then resets the allowance to zero and holds nothing. The price is spent once the request is made. There is no refund.
2. **Body.** The body is `jobBodyPrefix ++ "0x<specHash>" ++ jobBodyMiddle ++ brief ++ jobBodySuffix`. The owner's template must contain `forge build`, `forge test` and `adversarial review`, so every job names the build, test and adversarial-review steps. `setJobTemplate` refuses a template without them. The brief is untrusted: it must be 1–2000 bytes of strict UTF-8, with no `"`, `\`, `<`, `>`, control characters or DEL. It sits between `<brief>`…`</brief>`, which the template declares to be data, not instructions. The whole body is capped at 16 KiB.
3. **Request-ID tracking.** The Intake's returned id keys `getJob(id)`, `jobIds[]`, `jobsOf(wallet)` and the `JobOpened(requestId, requester, specHash, price, body)` event. A zero id, an id already used by a job, or an id already used by a pending review ask is refused. Every event the contract emits carries the request id as its first indexed topic, so one `eth_getLogs` filter returns a job's whole history.
4. **Result or failure: authenticated and one-time.** `onJobResult` and `onJobFailure` accept calls only from the configured Intake (`msg.sender`), only for an `Open` job this contract created, and only once. After either one, every later result or failure call reverts `UnknownOrSettled`. A failure (status 1 = refused, 2 = no result) records `status` and `reason`. Its values are unsigned and only close the job. A job with no answer can be expired by its requester after `jobTimeout` (7 days by default). A late callback after that is refused.
5. **Review verdict.** A delivery is not a review verdict. `requestReview(jobId)`, by the job's requester and allowed once the job is `Delivered` or `Expired`, buys an `oracle.request` (0.5 IMD) asking whether that job's adversarial-review step passed. The answer arrives in `onReviewResult` as the protocol's `OracleAttestation`, signed by the IdentityMD oracle signer in **this contract's** EIP-712 domain. The contract accepts it only if:
   - it comes from the Intake,
   - it answers this contract's own pending ask,
   - the panel meets the owner's minimum size and agreement (and `agreed ≥ quorum`),
   - the attestation is still valid and correctly signed,
   - it is consumed once and has type bool.

   Only this sets `Passed` or `NotPassed`. A refused or unagreed ask (`onReviewFailure`) or an expired ask (`expireReview`, after `reviewTimeout`) sets `Unanswered` and allows a new ask. The digest matches the protocol vector (`test/OracleConformance.t.sol`).

Callbacks run under the Intake's 200,000-gas stipend. The tests run every callback through the mock with that stipend.

## Showing status on a static website

`site/index.html` is one HTML file with no dependencies. On a JSON-RPC endpoint the visitor chooses (a public RPC of the chain, or the wallet's injected provider) it calls `getJob(bytes32)` with `eth_call` for one job, `jobsOf(address)` to list a creator wallet's jobs with each one's status, and `eth_getLogs` filtered on the contract address, the seven event topics and the request id for the job's history (block, event, transaction hash). It never contacts api.imd.fun, so browser CORS on that API is irrelevant. The selectors and topic hashes it hard-codes are pinned by `testStaticSiteReadContract`, and the same three RPC calls were replayed from outside the EVM against a disposable local Anvil in this job: the wallet list, the 15-word job decode and the event order (`JobOpened`, `JobDelivered`, `ReviewRequested`, `ReviewUnanswered`) came back as the page expects. Many public nodes cap `eth_getLogs` block ranges, so the page takes a "from block" (give the contract's deployment block); when the range is refused the job status still shows and the history row says so. It shows:

| On chain | Shown as |
|---|---|
| `status` Open / Delivered / Failed (+status, reason) / Expired | Job status, labelled "reported by the Intake". Delivery is an unsigned completion notice. |
| `review` None / Pending / Unanswered | "No verified review result" |
| `review` Passed / NotPassed + `reviewPanelSize`, `reviewAgreed`, `reviewPanelJobId` | "IMD oracle panel attested the review step passed / did not pass (N of M agreed)" |

The page never shows "audited". `Passed` means a signed oracle panel answer that the job's adversarial-review step passed. It is not an audit of the hook, and it is not proof that the code delivered is the code someone deploys.

### Blocker for a static review status

Without the oracle step, a static website **cannot reliably tell whether review passed**. The Intake's job completion is unsigned, carries no review verdict, and its `job.open` callback ABI was not in this task's protocol references. The job page on api.imd.fun cannot be read from an arbitrary origin and would not be chain-verifiable anyway. With the oracle step, review status depends on a live pilot confirming two things: that the panel can read the job's review outcome, and that the definitions in the review template pin it unambiguously. Until then, the site shows "No verified review result".

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
| `setTimeouts(job, review)` | Optional; 1 hour to 30 days, default 7 days and 1 day | Owner's operational choice |
| `setPayment(asset, maxPrice)` | The IMD token and the most one ask may cost, together. Raise `maxPrice` when the published price moves up; the contract still pulls only the current price | `Intake.priceOf(action, imd)` on the chain |
| `setFailureHook(on)` | Leave on (the default) against Intake v2. Turn off only if the contract is pointed at Intake v1, which has no `requestWithFailure` | The Intake version in use |
| `setIntake`, `setOracleSigner` | Only for a protocol move or signer rotation, and only with no job or review pending, because callbacks are accepted only from the current intake | IdentityMD announcements |
| `sweep(token, to, amount)` | Recovers tokens sent by mistake | — |

The owner can change templates, signer, intake, asset, price ceiling and the failure hook. These are trust assumptions: a malicious owner could point the intake or signer at a contract they control and forge review verdicts for jobs opened afterwards. Put ownership behind a multisig.

## Requires a live Ethereum or Robinhood Chain pilot

- The `job.open` action id, body schema, price and **callback ABI**. `onJobResult(bytes32,bytes)` is this contract's assumption. If the live callback has another shape, it reverts inside the Intake's try, the job stays Open, and the requester expires it after the deadline. That path is tested, and it fails safe, but delivery then never shows.
- Whether `job.open` accepts this contract as the callback target and calls `onJobFailure` on status 1 or 2.
- Whether an oracle panel can answer the review question reliably from public job evidence, and how fast.
- The real oracle signature path end to end. Locally, the protocol's EIP-712 vector digest matches, and the protocol's vector key is accepted.
- Gas of real callbacks under the 200,000 stipend on each chain. Local measurement covers the mock path only.
- Public RPC choice, `eth_getLogs` range caps and rate limits for the static page. Reorg and finality display. The page's RPC calls were replayed only against a local Anvil.
- Whether the live Intake's request ids can ever repeat across actions. The contract refuses a repeat either way; a pilot shows whether the check ever fires.

None of this was run: no paid request was submitted and nothing was deployed. Base has no Intake yet. An independent adversarial review is still needed before this holds anyone's IMD.
