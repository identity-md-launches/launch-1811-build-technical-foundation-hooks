# Audit 648ba2e5 remediation

This change addresses the user-facing findings in audit 648ba2e5-46a0-4759-8439-73a6c9d81af6
against `eb1333775e60fe191acfa5a420e9256feeb4a2b0`. The audit text itself was not among this
job's inputs; the three findings are taken from the request's statement of them. No deployment,
paid request or fund movement was performed. No compiler settings, dependencies, token or
listing/ad economics changed.

| Finding | Resulting behavior | Adversarial evidence |
|---|---|---|
| A retained answer with the ask's own UUID but another signed question, chain or window had no closure: binding and discard reverted `ReviewAttestationMismatch`, every expiry path reverted `ReviewAlreadyReceived`, and the job could never be reviewed again | New owner-only `discardMismatchedReviewReceipt`. The owner supplies the ask's true context (as for binding) and `reviewReceiptHash(intakeId)`, the hash of the exact receipt including its verdict. A receipt matching the true context reverts `ReviewReceiptMatches`: a genuine `Passed`/`NotPassed` can only be bound. Closure is `Unanswered` with reason `receipt context mismatch`, logged with the receipt's UUID and the owner's context; the receipt stays readable, the UUID is neither reserved nor consumed, the Intake ID stays terminal, no fee moves | Fuzzed over every mismatching field and both verdicts: one-shot retention, every pre-existing path stuck, closure events, history/UUID/fee invariants, terminal ID against late result/failure/second discard, retry under its own binding refusing the stale answer. Requester and stranger refused; matching NotPassed refused; wrong body, unacknowledged or opposite-verdict receipt hash, malformed context refused; bound ask refused until reset; finalized ask refused |
| The quorum check compared the signed body threshold with the configured minimum agreement, so a body quorum below `minAgreed` burned a valid answer whose actual agreement met the minimum | `onReviewResult` requires `panelSize ≥ minPanelSize`, `agreed ≥ minAgreed`, `agreed ≥ quorum` (the oracle's own signed threshold) and `agreed ≤ panelSize`. The signed quorum is no longer compared with `minAgreed` | Fuzzed quorum from 0 to the agreement with agreement from the minimum to the panel, bound and unbound, both verdicts; the exact reproduction (quorum 1, agreed 6) now settles. Weak answers (small panel, agreement below the minimum, agreement below the signed quorum, agreement above the panel) still fail closed through the mock's one-attempt call, with no receipt, consumption or refund, and owner closure after the deadline |
| Step markers were checked on the joined template fragments, so a marker split across a fragment boundary passed although the assembled body, with the spec hash and brief inserted at every boundary, never contains it | `setJobTemplate` requires each marker whole inside one fragment. That is equivalent to "every body this template can assemble names all three steps", since the only other places a marker could appear are the hex spec hash (impossible) or the creator's untrusted brief (not the template's) | Fuzzed every marker, both boundaries and every split point: the joined template contains the marker and the template is refused. Fuzzed spec hash and brief: every assembled body contains all three markers. Markers only a brief could supply do not satisfy the template; a marker inside a single fragment, including the suffix alone, does |

The new tests are in [`AuditContextMismatchProof.t.sol`](../test/AuditContextMismatchProof.t.sol).
Two existing assertions encoded the old quorum rule and were changed: `ReviewBinding.t.sol` now
rejects a signed quorum above the panel size instead of one below `minAgreed`, and the invalid
early-answer fuzz in `ReviewDelivery.t.sol` now uses agreement that meets the signed quorum but not
the configured minimum. No binding, replay, escrow or expiry assertion was dropped.

## Synchronous Intake refusal

`MockIntake.setRefusal(code)` makes `request`/`requestWithFailure` revert before taking payment,
as the live Intake does for an unsold action. Fuzzed over the error code and both Intake paths
(`failureHook` on against v2 and off against v1): `openJob` and `requestReview` revert with the
Intake's error, the caller's balance and the contract's allowance are untouched, no job, ask or
Intake ID is recorded, and the same calls succeed once the refusal clears. An asynchronous refusal
after payment is tested separately and spends the fee.

**Compatibility statement.** The contract is compatible with both refusal shapes. Which shape the
live Intake uses for which refusal, whether it can refuse after pulling the price without calling
the failure function, and the exact synchronous error selector are behavior only a live pilot can
prove. The mock's choice of shape is not evidence of the live one; the fee outcome differs between
the shapes, so operators must not promise a refund for a refused body.

## Preserved properties

- Replay protection: consumed UUIDs still fail delivery and binding; used Intake IDs are never
  recycled; the set-aside answer cannot settle a retry under the retry's own binding.
- Owner-trust disclosures: the new recovery is an owner power, explicit and logged, with the receipt
  and its verdict kept readable; it is documented beside the existing ones in the integration guide.
- Exact IMD spending, the owner ceiling and the caller's `userMaxPrice` are unchanged; a synchronous
  refusal rolls the whole ask back.
- Listing and ad escrow contracts and tests are untouched and rerun.
- The 200k callback budget: removing one comparison lowered every measured cold path by about 300
  gas (5-of-7 receipt 170,077; wrong pre-binding 175,123; 22-cold-read stressor 192,286).

## Compatibility and operating decisions

- The ABI gains `discardMismatchedReviewReceipt`, `reviewReceiptHash` and the error
  `ReviewReceiptMismatch`; nothing was removed or renamed. The site ABI was regenerated from the
  compiler artifact and the status page's label for `ReviewReceiptDiscarded` now names the third
  closure reason. Read tuples, constructor inputs and paid selectors are unchanged.
- The runtime is 24,081 bytes, 495 bytes under the limit. Future additions to this contract must
  watch that margin.
- Operators: before setting aside a receipt, publish the independently computed canonical question
  for the ask so the closure can be checked against the signed one by anyone.

Current command results are recorded in [VERIFICATION.md](VERIFICATION.md#follow-up-audit-648ba2e5).
These are contributor self-checks, not an independent audit. The [integration guide](IMD_INTEGRATION.md#after-launch)
lists the new setter beside the existing deployment parameters and owner responsibilities.
