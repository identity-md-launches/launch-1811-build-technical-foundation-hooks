# Audit ef1f6915 remediation

Source-only fixes for [audit ef1f6915-b9df-441d-b2e5-db5e9d9e9b35](https://github.com/Identity-md/research/blob/main/jobs/ef1f6915-b9df-441d-b2e5-db5e9d9e9b35/files/AUDIT.md)
against `cb6ca724441c9aebf9a38cb4d7426218e0712723`. No deployment, token change or paid Intake request.
Compiler, build configuration and dependencies are unchanged. Earlier audit remediation notes are
historical; this document and [IMD_INTEGRATION.md](IMD_INTEGRATION.md) describe the current behavior.

## Four fixes

| Finding | Implemented behavior | Regression evidence |
|---|---|---|
| 1 / Medium: expiry front-runs a late NotPassed | `expireReview(jobId)` requests owner-assisted closure. The ask stays Pending, accepts a fresh valid callback and blocks retries. Only `confirmReviewExpiry(intakeId)` can close that exact requested ask, and only without a receipt. | Report's literal `AuditExpiryProof.t.sol`; `ReviewAuditRegression.t.sol` tests both transaction orders, both bool values, prebound and receipt-first delivery, retry attempts before/after delivery, stale/unauthorized approvals, owner rotation and failure/expiry retries. |
| 2 / Low: retained receipt stuck when another ask reserves/consumes its UUID | Owner can discard with the **exact matching context** if the receipt UUID is consumed or reserved elsewhere. History stays readable, the other ask's reservation/consumption is untouched, and a new paid ask is possible. | Report's literal `AuditReceiptConflictProof.t.sol`; reserved/consumed cases before/after reservation, no fabricated mismatch, original holder settlement, replay and retry tests. |
| 3 / Low: terminal reservation burns the retry's sole callback | An unbound callback retains a verified unconsumed receipt regardless of reservations, without reserving, consuming or setting a verdict. Release the old unused terminal reservation, then bind the retained retry. | `ReviewRecovery.t.sol` sends the actual one-shot callback **before release**, after both failure and owner-confirmed expiry. `ReviewReceiptGas.t.sol` repeats this with a cold 5-of-7 ERC-1271 signer under 200k. |
| 4 / Low: same-UUID typo or unusable true context discards a genuine answer | Same UUID requires every field to match plus an onchain conflict. Different UUID requires a valid, unconsumed, unreserved proposed context. Invalid body/fields, same-UUID field typos and unavailable replacement UUIDs revert atomically. | Same-UUID question/chain/start/end typos, including with a real conflict; pending/terminal/consumed replacement UUIDs; negative-receipt preservation; existing malformed, unauthorized and matching-without-conflict refusals. |

Both Solidity proofs were extracted from the published report and run against the original source.
They failed with the reported lost-NotPassed assertion and `ReviewReceiptMatches`, respectively.
They now pass and are delivered in `test/`, with only Foundry formatting changes. Findings 3 and 4
have no literal Solidity blocks in the report; their transaction sequences are covered by the
recovery and audit regression tests above. Scratch files are not needed to reproduce any passing test.

## Expiry and owner trust

A requester-controlled final expiry cannot safely coexist with indefinitely late fresh answers:
a requester can observe a false answer and choose to expire first. This fix uses the report's
owner-assisted option, avoiding a timing-dependent grace-period assumption. The existing
`expireReview(bytes32)` selector remains, but **its semantics change**. Integrators must wait for
`ReviewUnanswered` before offering another paid ask; `ReviewExpiryRequested` is not closure.

Only the requester can request expiry after the snapshotted deadline and without a receipt.
`reviewExpiryRequested(intakeId)` is historical, and does not mark the ask terminal or make its
reservation releasable. Only the current owner can confirm that same Intake ID. A stored receipt
blocks confirmation, a settled ask rejects it, and an old approval cannot close a later retry.
Callbacks, binding and Intake failure remain enabled while expiry is requested. The static page
labels the new event and keeps Pending distinct from Unanswered.

The owner must establish from protocol evidence that no valid callback will be delivered before
confirming expiry, such as evidence of a terminal one-shot failure. **The contract does not prove
that absence onchain.** Never confirm solely because the deadline passed or the requester asks.
If evidence is unavailable, the ask remains Pending; owner unavailability can block retries.
A mistaken or malicious owner can still approve premature closure and lose a later callback.
No timeout-only escape is claimed to prevent this owner behavior.

Likewise, **the owner-supplied Intake-to-oracle mapping is not independently authenticated onchain**.
The contract checks body fingerprint, exact receipt/binding equality, availability, signature,
freshness, panel minimums and replay state. The signature covers oracle context and verdict, not
the pairing to the Intake callback ID. The owner must establish that pairing offchain. A dishonest
owner can invent an available different true UUID, create a conflicting reservation, or rotate
Intake/signer to fabricate results. These powers are not removed by consistency checks. Use the
requester-approved operational owner/multisig, monitor events and preserve mapping/closure evidence.

## Recovery rules and invariants

`discardReviewReceipt` still requires the current owner, a pending unbound ask, a receipt, the exact
paid-body fingerprint, and well-formed context. It supports only these two paths:

- Different UUID: it must be available for binding. No same-UUID field mismatch can be used as a
  misdelivery claim; no consumed or reserved replacement UUID can justify closure.
- Same UUID: all five context fields must match and the UUID must be consumed or reserved by
  another ask. This is the honest conflict recovery path, including when both receipts have
  different questions. A field typo reverts even when a real UUID conflict exists.

Success preserves the full receipt and marks `discardedReviewReceipts`. It emits the existing
`ReviewReceiptDiscarded` event and `ReviewUnanswered` with `misdelivered receipt` or
`receipt UUID conflict`. Event context is owner-supplied, not independent mapping proof.
No recovery call changes UUID consumption/reservation or moves tokens. A fresh ask still costs
its normal price; no spent fee is refunded and no callback is retried or rerouted.

For legitimate protocol UUID reuse, prefer `releaseReservation` then binding the retained retry.
Release remains owner-only, only for an unconsumed UUID whose holder is terminal and has no receipt.
Active holders and consumed UUIDs cannot be released. Callback retention cannot steal a reservation.
Binding must still be exact and reserve a currently available UUID; consumption occurs once only.
All used Intake IDs remain permanently used, including after expiry/discard/failure. Closed IDs
cannot be rebound or receive again. Both Passed and NotPassed remain terminal. Receipt verification
is still final on arrival and survives later signer rotation/revocation and signature expiry.

A receipt with the same UUID but genuinely inconsistent signed question/window fields requires
protocol/operator resolution; there is no generic administrative override. Do not fabricate a
new true UUID to bypass these checks. Already consumed UUIDs still fail new callback delivery.

## Callback gas and validation

Cold minimum **forwarded callback gas**, Solidity 0.8.26/Cancun/optimizer 200:

| Fixture | Receipt-first | Pre-bound | Receipt headroom below 200,000 |
|---|---:|---:|---:|
| ECDSA key, 65-byte signature | 123,013 | — | 76,987 |
| ERC-1271 5-of-7, 325-byte signature | 168,106 | 132,880 | 31,894 |
| Audit stressor: ECDSA registry +22 cold reads | 185,260 | 150,053 | 14,740 |

The 5-of-7 receipt also measures 168,106 after requesting expiry and on an unbound retry **before**
reservation release. Each case succeeds through the single-attempt 200,000-gas MockIntake call.
The multisigner performs five actual ECDSA recoveries, threshold/membership/expiry reads, sorted
signer duplicate rejection and revocation checks. Invalid/duplicate/revoked/expired/insufficient
signatures fail. The 64-cold-read over-budget fixture still loses the attempt and fee without
partial receipt/consumption; owner-assisted expiry can then close it.

Asks are prepared in `setUp` before the measurement transaction. Binary search restores state and
cools consumer/signer for every trial. Normal and `--isolate` execution agree. These are not
refunded transaction-gas estimates. The operational envelope remains a cold `isValidSignature`
execution budget of 60k, canonical 32-byte bool answers and signatures up to the tested 325 bytes,
followed by measurement of the entire callback with the real signer/proxy on the target chain.
Arbitrary ERC-1271 implementations are not guaranteed to fit; requalify after upgrades/policy changes.

See [VERIFICATION.md](VERIFICATION.md#follow-up-audit-ef1f6915) for build, full tests, both seeds,
formatting, gas and listing/ad escrow results. The tests and fixtures are ordinary committed
source; no network, keys or environment reads are needed by the Solidity tests.

## Parameters and live blockers

No constructor parameter or external dependency was added. The constructor still takes the launch
owner, verified chain Intake, IMD asset, oracle signer and price ceiling. Review/job templates,
actions, chain identity and panel minimums must be configured and checked before paid use, as in
[After launch](IMD_INTEGRATION.md#after-launch). No deployment addresses were invented here.

The operator additionally handles expiry requests and authenticates Intake terminality before
confirming closure, resolves UUID collisions, releases eligible reservations, and verifies each
binding/discard context independently. Preserve receipts, body/canonical documents, signer/config
history and reasons for recovery. Current signer/Intake still apply to deliveries for older asks.

Live Intake callback ABI/action/schema, asynchronous one-shot 200k delivery, authenticated mapping
and canonicalization, absence-of-answer evidence, UUID reuse policy, timestamp windows, remote
review evidence and actual signer gas remain unverified. No live pilot, public-chain transaction,
paid request, Slither/Mythril run or new independent audit was performed. These local checks are
contributor evidence only. Immutable deployed instances, if any, are unchanged by this source fix.
