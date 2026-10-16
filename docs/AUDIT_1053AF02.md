# Audit 1053af02 remediation

Source-only remediation of [audit 1053af02-a430-49b3-a914-75620c17c801](https://api.imd.fun/jobs/1053af02-a430-49b3-a914-75620c17c801/report.md)
against `64e40684e68c84c21e770bca63206ec9d292f063`. All four actionable findings are addressed;
the two informational choices are retained and explicitly documented. Nothing was deployed and
no paid request was submitted. Compiler, dependencies and build configuration are unchanged.

| Finding | Result | Regression evidence |
|---|---|---|
| 1 / Medium: requester discards retained NotPassed and re-asks | `expireReview` refuses any retained receipt, regardless of bool or age. The owner can still confirm it after the deadline. | `ReviewDelivery.t.sol`: both bools, attempted expiry and re-ask; `ReviewRecovery.t.sol`: fresh negative receipt after deadline, then attempted expiry before confirmation. The report's literal verdict-shopping proof also passes locally. |
| 2 / Low: receipt-first callback exceeds 200k with a heavier ERC-1271 signer | Preallocate the packed receipt metadata slot at payment, write it once on arrival, and reuse the verified digest. Preserve all original full-width context and read ABIs. | `ReviewReceiptGas.t.sol`: cold exact-200k one-attempt calls and minimum forwarded gas for ECDSA, a real 5-of-7 signature validation fixture and the report's 22-cold-read stressor; over-budget/revoked/invalid signatures fail closed. `ReviewReceiptPacking.t.sol`: boundary and fuzz round trips. |
| 3 / Low: swapped receipt strands the true binding | Owner-only `discardReviewReceipt` closes an unbound misdelivery as `Unanswered`, requiring the exact paid-body hash and an independently authenticated valid context that differs from the receipt. The complete receipt stays readable with an explicit discard marker and event. | Swapped yes/no reproduction: true binding fails, second callback fails, owner recovery succeeds without fee, genuine ask can finalize its own UUID. Matching contexts, unauthorized callers, no receipt, bound/terminal asks, invalid fields and wrong bodies are rejected. |
| 4 / Low: undelivered UUID reservation blocks a retry | Owner-only `releaseReservation` permits release only for an unconsumed UUID whose holder is terminal and has no receipt. It does not reopen an Intake ID, rewrite its binding or clear consumption. | Expiry and failure, retry before release rejected, release event, receipt-first and bound retry after release, second release rejected, pending/unknown/consumed rejection and later replay failure. |
| 5 / Info: retained receipt survives signer rotation/revocation | Keep verification final at receipt. No general receipt revocation or blanket freeze is introduced. | Receipt still finalizes after rotation; an undelivered signature from the old key fails. Existing ERC-1271 revocation and signature-expiry tests remain. |
| 6 / Info: missing/pending review means false, and NotPassed is terminal | Keep the existing question and terminal-verdict rule. Wait for final remote evidence before asking. An Expired local job does not imply evidence is ready. | Expired job receives a truthful false; it becomes NotPassed, cannot re-ask and rejects late job completion. |

## Binding, recovery and replay properties

The callback Intake ID and signed oracle UUID remain separate namespaces. The contract does not
guess their relationship or treat the raw JSON body hash as a canonical question hash. Every
verdict still requires both a verified consumer-domain signature and the owner's exact binding
of UUID, canonical question hash, question chain, start block and end block to the paid body.
Panel minimums, 300-second clock tolerances and signature validity on arrival are unchanged.

An unconfirmed receipt neither reserves nor consumes its UUID. Owner confirmation must match
all five fields; a mismatch makes no partial binding or reservation. Recovery instead closes
the wrong ask and emits the independently established correct context. It does not claim the
misdelivered answer belongs to that context, reroute it, overwrite history or retry Intake.
`discardedReviewReceipts(intakeId)` distinguishes a discarded receipt from a confirmed/pending
one. Readers should check the current `getJob` status and follow all lifecycle events, including
the new `ReviewReceiptDiscarded` topic shown by the static reader.

The owner must authenticate recovery values from protocol records, exactly as for binding. A
matching-context negative receipt cannot be discarded, but a dishonest owner can invent a mismatch.
That remains an explicit owner-trust risk, alongside the existing authority to replace Intake and
signer. Recovery is not delegated to requesters. Once an ask closes, its old Intake ID can never
be reused or receive/bind again. Consumed UUIDs can never be released or used for another verdict.
Release is manual, emits `ReviewReservationReleased`, and preserves the old `ReviewAsk` history.

Confirmation, owner closure and release charge no Intake fee and transfer no tokens. A genuinely
new request still costs the current Intake price. No spent fee is refunded; releasing a reservation
after the retry's sole callback has already failed cannot restore that attempt. Arrange release
before delivery using authenticated protocol records. The new owner responsibilities and exact
calls are in [IMD_INTEGRATION.md](IMD_INTEGRATION.md#owner-recovery).

## Gas evidence and compatibility envelope

Measurements use Solidity **0.8.26**, Cancun and optimizer 200 from the unchanged configuration.
`ReviewReceiptGasTest` prepares asks in `setUp`, cools the entire consumer and signer before every
trial, restores state between binary-search trials and forwards an explicit gas cap. No transaction
intrinsic gas or gas refund is counted as callback headroom. Each supported case is then delivered
through `MockIntake.complete`, which always settles its one attempt, including failures.

| Signer | Receipt minimum forwarded gas | Bound minimum forwarded gas | Receipt headroom under 200,000 |
|---|---:|---:|---:|
| ECDSA key, 65-byte signature | 125,266 | — | 74,734 |
| ERC-1271 5-of-7, 325-byte signature | 170,359 | 135,137 | 29,641 |
| Audit stressor: ECDSA registry +22 cold mapping reads | 187,513 | 152,310 | 12,487 |

The report measured 145,701 for the original ECDSA receipt and 207,866 for its +22-read registry;
the latter now succeeds within the exact 200k cap. The new multisigner is a local model with five
real ECDSA recoveries, sorted membership/duplicate checks, threshold, per-key expiry and revocation,
not an always-true ERC-1271 mock or a claim about a deployed registry. Invalid member, duplicate,
revoked member, expired membership and insufficient-signature cases fail without a receipt or
consumption. A 64-read stressor still runs out of gas and demonstrates the remaining fee-loss case.

The receipt stores the same five words, but `requestReview` pays approximately 22,100 extra storage
gas to initialize an allocation bit in the metadata word. The callback performs four new-word
writes and one nonzero-to-nonzero metadata write. Isolated execution and opcode traces verify
that write is charged 5,000 gas. The allocation bit is not exposed as receipt data and does not
enable confirmation or suppress expiry. No timestamps, UUID bits or chain-ID bits are dropped.
The verified EIP-712 digest is returned internally and used directly for the unchanged receipt event.

The operational ceiling is **60k gas for cold `isValidSignature`**, with canonical 32-byte bool
answers and signatures up to the tested 325 bytes, followed by qualification of the **entire**
callback with the actual production registry/proxy on the intended chain. No arbitrary ERC-1271
implementation is guaranteed to fit, and the contract does not impose that sublimit. Requalify
after registry/policy upgrades, signature-shape changes or gas-schedule changes. Intake must
provide enough outer transaction gas to forward 200k. See the reproducible checks in
[VERIFICATION.md](VERIFICATION.md#follow-up-audit-1053af02).

## Informational choices and operating responsibilities

1. **Historical verification stays final.** Signature expiry, signer rotation and ERC-1271
   revocation after receipt do not undo it. A compromised-signer rotation is not a freeze of
   retained answers. Stop owner confirmations during investigation; independently verify each
   mapping. The mismatch recovery path is not a general revocation mechanism. Confirmation remains
   owner-only, including after an ownership handover.
2. **NotPassed stays terminal.** The existing question includes missing or pending evidence in
   false. Ask only once final review evidence is available; neither local Delivered nor Expired
   proves that. A later remote result cannot revise a confirmed false. The legitimate `Unanswered`
   retry paths do not let a requester erase a retained negative answer.

Constructor parameters remain launch owner, verified Intake, IMD asset, oracle signer and maximum
ask price. No new parameter or external service is needed for these fixes. The owner must configure
and validate the job/review templates and chain-specific action IDs before paid asks, authenticate
the mapping for each review/recovery, monitor configuration and recovery events, qualify callback
gas, and manage two-step ownership. Use the existing [after-launch checklist](IMD_INTEGRATION.md#after-launch).

Live Intake callback ABI/action/schema, authenticated post-delivery mapping and canonicalization,
remote review-evidence availability, UUID reuse policy, actual signer gas and chain contracts remain
unverified. No live pilot, public-chain deployment, token change, Slither/Mythril run or new independent
audit was performed. This immutable source update does not modify any already deployed instance;
independent review and any future deployment remain separate work.
