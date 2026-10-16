# Re-audit 5f43f94d remediation

This source-only follow-up addresses all four findings in
[re-audit 5f43f94d-4f44-4255-a8c2-e0a2605c4897](https://github.com/Identity-md/research/blob/6bc8133de6a0d7509e1c2d71f7919a0e7531ff0f/jobs/5f43f94d-4f44-4255-a8c2-e0a2605c4897/files/AUDIT.md)
against commit `684c3da344f8f9f3a34ed810e55c243eec485090`. No deployment, paid request, token change,
funded-wallet operation, dependency or build-configuration change was made.

| Finding | Change | Evidence |
|---|---|---|
| High: owner binding misses the only callback and loses the fee | An unbound pending ask verifies the signature, timing, bool type and snapshotted panel requirements on receipt, then stores the signed context/value without a verdict or UUID consumption. A later exact owner binding consumes and finalizes atomically. No callback retry or extra Intake fee is needed. | `ReviewDelivery.t.sol`: early true/false answers, cold 200k callback, post-receipt binding and exact balances; Intake refuses both a second completion and a failure after its one attempt. |
| Low: zero backward clock tolerance | `uint256(issuedAt) + ISSUED_AT_TOLERANCE >= askedAt`; the existing 300-second forward tolerance and signed expiry remain. Widening prevents a hostile uint64 timestamp from overflowing the addition. | One-second skew, exact 300-second boundary, fuzzed backward/forward skew on both paths, uint64 maximum and near-zero timestamp tests. |
| Low: fresh late answers rejected by local timeout | The review deadline only enables explicit requester expiry. Pending asks may receive fresh answers or bind after that time. Expiry/failure/settlement remains terminal. | Fresh late bound and unbound answers, both orderings of expiry versus finalization, expired signatures, exact signature expiry, retries and old answers. |
| Info: relative-window template contradicts pre-binding | Keep `window.hours:1` and use receipt-first confirmation after the plane resolves the window. `validForSeconds:3600` limits receipt, not confirmation. Template comments and the current operating guide explain this order. | The one-attempt test reads the actual emitted JSON's relative window, then delivers a resolved 1000..1300 block window before any binding; confirmation succeeds later. This is a local fixture, not a live canonicalization claim. |

## Security properties

`getJob` remains the same 15-word ABI and the protocol attestation, domain, type hash and callback
selector are unchanged. `getReviewReceipt` and `ReviewReceived` expose the new intermediate state.
The static reader keeps that state pending and labels the receipt event as awaiting confirmation.

Only the configured Intake can deliver a receipt for a pending ask created by this contract.
Only the owner can bind it, checking the original paid body fingerprint and **all five** signed
context fields: oracle UUID, canonical question hash, question chain, start block and end block.
The owner must independently authenticate the mapping; simply copying a signed receipt would
reintroduce the original trust mistake. No UUID conversion or canonical hash algorithm is guessed.

A receipt does not reserve a UUID because its pairing is still unconfirmed. A swapped receipt
therefore cannot reserve the genuine ask's UUID. Once the correct binding reserves a UUID, other
asks cannot use it. Once consumed, it cannot be consumed or received again. Bound UUIDs and all
used Intake IDs stay reserved after failure, expiry or settlement. Tests include swapped yes/no
receipts, duplicates, exact-field mutations, attempts to overwrite a receipt, unauthorized callers,
repeated questions and old answers presented to new asks.

Retaining a receipt is final **signature verification**, not final **request pairing**. Signature
expiry and current signer/Intake authorization are checked on arrival; a matching owner binding
later uses that stored verification without another external call. Thus a receipt can finalize
after signature expiry, ERC-1271 revocation or authority rotation, just as an already-bound answer
would already have finalized before those events. The original panel minimums remain effective.
This deliberate historical-answer behavior is documented and tested; a new expired delivery
continues to fail.

The requester may explicitly abandon any pending ask strictly after its deadline, including one
with a retained answer. That closes its authority permanently but leaves readable receipt history.
If finalization executes first, expiry reverts. If expiry executes first, binding and delivery
revert. There is no automatic expiry and no refund. A failed confirmation transaction makes no
binding changes, so the owner can correct calldata; a successful pre-binding remains immutable.

The existing two-step ownership, EIP-7702/ERC-1271 verification and ad cancellation/accounting fixes
remain in place. Full tests include the unchanged ad conservation invariants and existing protocol
conformance vector. No new verification bypass, public attestation submission, admin rebind or
refund/sweep power was added.

## Remaining live assumptions and responsibilities

[IMD_INTEGRATION.md](IMD_INTEGRATION.md#after-launch) lists all constructor arguments and setters.
The constructor still has five explicit arguments: launch owner, verified Intake, verified IMD,
oracle signer and price ceiling. It performs no external calls. Templates/actions are owner-set;
no live deployment value was invented. The local template's chain ID must be replaced for launch.

Before accepting paid production asks, the operator must establish:

- Authenticated **post-delivery** evidence connecting each Intake ID to its distinct oracle UUID,
  the canonical question document/hash and resolved window. The receipt's own signature does not
  prove that association. No pre-dispatch mapping or dispatch coordination is required anymore.
- Live `job.open` action/body/callback ABI, `oracle.request` body support and review evidence
  accessibility. Callback delivery must be asynchronous after the request call returns and the
  Intake ID has been recorded. The existing `onJobResult(bytes32,bytes)` remains an assumption.
- Actual callback gas with the production signer/registry under the Intake's stipend, signing
  timestamps/lifetime and delivery latency, and ID uniqueness across actions/retries/migrations.
- Current chain contracts/prices, safe token behavior, finality and RPC/log access. This assignment
  did not query live contracts or execute a paid pilot. Supplied references provide no Base Intake.

The owner must verify and confirm receipts, monitor configuration events and use the documented
two-step handover process. Intake/signer rotations affect future deliveries on already-pending
asks; stored receipts retain verification. A malicious owner can still forge a future answer by
rotating those authorities, or approve a wrong pairing. The integration remains owner-trusted.
The requester should check for a retained answer before abandoning an ask; a replacement costs
another fee. Invalid ABI/signatures, wrong delivery pairing, out-of-gas callbacks and guessed
pre-bindings still fail closed and may lose a paid answer. The invalid-signature test demonstrates
that Intake records its single failed attempt, keeps the fee, cannot retry, and a new ask costs again.

See [VERIFICATION.md](VERIFICATION.md#follow-up-re-audit-5f43f94d) for reproducible check results.
Local tests establish these contract properties, not live protocol compatibility or an independent
security audit. Release/source verification, a live integration pilot and independent review of
these changes remain separate operator responsibilities; no deployed immutable contract is upgraded.
