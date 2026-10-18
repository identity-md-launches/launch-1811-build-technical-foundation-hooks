# Legacy manual oracle-gated deployment

> Historical legacy/manual integration. The current automatic successor, fixed canonical prefix,
> prepaid verdict flow and exact signed artifact authorization are documented in
> [AUTOMATIC_BINDING.md](AUTOMATIC_BINDING.md). Existing manual requesters keep their old behavior.

This revision continues `cc847d8f35bc0b814d390eb76092eed6051c5ae3` and addresses audit
[`ca404dfe`](https://api.imd.fun/jobs/ca404dfe-00d1-4682-83cb-fa1b28f9826c/report.md).
It is locally tested source, not a deployed or independently audited release. The integration
investigation and exact launch blockers are in [INTEGRATION_RESOLUTION.md](INTEGRATION_RESOLUTION.md).
**The legacy requester remains manual.** Its existing owner binding is a trust assumption, not a
contract-verifiable proof of IMD's Intake-to-oracle mapping.

## Authorization and exact evidence

The sole deploying entry point is `GatedHookDeployer.deploy`. It requires the job's creator, a
Delivered job, a Passed review, a nonzero and unrevoked verification epoch, fresh approval, the exact
completion snapshot bytes, accepted source and publication entries, correct context, and unused
job/artifact identities. `check` runs these gates without deploying. No token or pool is created.

ArtifactV2 changes the tuple ABI and domain type hash. Its fields, in order, are:

| Field | Commitment |
|---|---|
| `jobRequestId` | Originating Intake job ID; its immutable resultHash authenticates the snapshot |
| `sourceHash` | SHA-256 of the selected accepted source bundle |
| `sourceSubmissionHash` | Exact accepted submission carrying that bundle |
| `reviewSubmissionHash` | Exact independent adversarial-review submission covering the build |
| `evidenceHash` | SHA-256 of canonical `evidenceDocument(artifact)` |
| `buildHash` | Nonzero keccak256 of the exact build identity file |
| `creationCodeHash` | keccak256 of creation bytecode |
| `constructorArgsHash` | keccak256 of ABI-encoded constructor bytes |
| `runtimeCodeHash` | keccak256 of final runtime, including resolved immutables |
| `chainId`, `deployer` | This chain and deployer address |
| `poolManager`, `poolManagerCodeHash` | Enabled/pinned manager and its current code hash |
| `permissions` | Valid exact 14-bit callback mask, checked in CREATE2 address and readback |

`artifactDigest = keccak256(abi.encode(ARTIFACT_TYPEHASH, artifact))`. The new type is
`HookArtifactV2`; all SDK, site ABI and fixture tuples are updated. Old v1 publications cannot
satisfy the new gate. The contracts are not proxies; this source change does not upgrade any live
contract. `artifactMarker` remains display-only.

The worker first selects the exact reviewed source and accepted independent review, reproduces the
build, and fills every field except `evidenceHash`. `evidenceDocument` computes the artifact digest
with **only evidenceHash zeroed internally** to break self-reference, and returns these exact bytes:

```json
{"schema":"hooks-store-evidence-v1","reviewedBuild":"0x<core digest>","sourceSubmission":"0x<source submission>","reviewSubmission":"0x<review submission>"}
```

Set `evidenceHash = sha256(evidenceDocument(artifact))`, then obtain `approvalDocument(artifact)`:

```json
{"schema":"hooks-store-approval-v2","hooksStoreArtifact":"0x<final digest>","publication":"review-evidence"}
```

The latter is 158 bytes. Both files must be compact, in this key order, lowercase hex, and without
newline. Publish `hooksStoreEvidence` at `artifacts/hooks-store-evidence.json` and
`hooksStoreApproval` at `artifacts/hooks-store-approval.json`, both `application/json`, in the same
accepted publication submission. Neither file says that the oracle has approved it. The independent
reviewer writes a report; a subsequent publication worker emits these files.

The gate requires one selected source hash with the exact source submission, one reserved name/path
for each file, exact SHA-256 and byte lengths, nonzero submission IDs, and equal publication
submission IDs for the two files. Source and review submission IDs must differ. It reconstructs both
files itself; a caller cannot substitute an explanatory JSON file. Duplicate sources, name/path
aliases, escaped duplicates and nested rejected alternatives cannot authorize another artifact.

**A publication is a commitment, not proof of independent-review acceptance or reproducible build.**
The signed oracle question must verify that exact review submission's acceptance and findings, and
that it covers the source and build committed here. The live protocol does not put review-only
submissions into the completion's source array, so no such invented entry is required. Hashes cannot
prove source-to-bytecode compilation on their own. Pending/unbound/negative/missing oracle approval
always blocks deployment. Owner misbinding remains a trust risk until the protocol gap is resolved.

## Recovery and freshness

Both callback orders record `reviewReceiptSignerEpoch` and `reviewVerifiedAt` at successful signature
verification. Ordinary signer rotation preserves historical validity. Revocation permanently blocks
old-epoch deployment in both orders.

After rotating to a safe signer, the owner calls `revokeSignerEpoch(oldEpoch, incidentHash)`. For a
retained pending receipt, use `closeRevokedReviewReceipt(askId)` as before. For a **current finalized
Passed or NotPassed verdict**, use `closeRevokedVerdict(jobId)`. It requires the verdict's actual
verification epoch to be revoked, marks that ask revoked, changes the current review to Unanswered,
and emits `ReviewReceiptRevoked` and `ReviewUnanswered`. The requester can pay for a fresh review of
the same job and unchanged result. No epoch is unrevoked, no UUID is unconsumed, no Intake ID reused,
and no receipt/binding/history is erased. Repeated closure and ordinary NotPassed shopping fail.
Already-deployed jobs remain deployed and cannot deploy again after recovery.

The existing `maxJobAge` getter/setter/event names are retained for compatibility; their documented
meaning is now **maximum age of the signature-verified approval**, not time since job opening.
The default is 30 days; the owner bounds remain 1–180 days. Deployment requires
`now <= reviewVerifiedAt(currentAsk) + maxJobAge`. Late job delivery or a fresh review of an old job
therefore gets a usable full policy window starting at verification. Tests cover 180-day job delay,
both orders, and the exact minimum-window endpoint. Missing timestamps fail closed.

Owner binding does not reset that clock. A **positive** receipt must be confirmed within 23 hours
of verification to become a usable Passed approval. Thus even the latest permitted confirmation
leaves at least one hour under the minimum one-day age policy (24 hours for immediate binding).
After 23 hours, exact binding still consumes the UUID, preserves the receipt and emits its historical
`ReviewAnswered(true)`, then leaves the current job **Unanswered** with reason `positive receipt aged`.
The creator can buy a fresh review of the same job; a stale positive cannot acquire a new timestamp.
**Negative receipts always finalize NotPassed, however old**, and remain non-retryable except for the
explicit revoked-epoch incident path. The old expiry/fee-loss security assertions remain in place.

The guarantee assumes manager/signer policy is not revoked or disabled; those owner veto powers
remain unchanged. A previously usable approval still expires after its policy window. The SDK's
final `check` enforces the policy at its read block; state can change before a transaction is mined.

## JSON semantics and resource limits

`resultHash` is checked against the exact original bytes **before** parsing. The parser decodes into
its own memory copy; callers' bytes are unchanged. UTF-8 must be well formed, without overlong
encodings or surrogate scalars. All standard JSON escapes and valid surrogate pairs are accepted.
Escaped selectors compare by decoded bytes. Duplicate decoded keys at any depth are rejected,
including `files`/`fi\u006ces`. Unicode normalization is not applied. Unknown well-formed values and
irrelevant source/file entries with missing/null/non-string selector fields are ignored. A selected
source or reserved name/path must still have exact, valid metadata. Hashes remain lowercase hex;
case aliases of a selected source cannot hide duplicates.

| Limit | Contract and SDK |
|---|---:|
| Exact document bytes | 12,288 (12 KiB) |
| Total tokens, counting keys and containers | 512 |
| Members in one object | 32 |
| Items in one array | 128 |
| Maximum value/key depth, root = 0 | 16 |

These limits combine: 128 seven-field files do not fit 512 tokens. No claim says every container
maximum fits simultaneously. Document/token/container overflows have distinct Solidity errors.
Duplicate checks cache each decoded key hash and compare at most 32 keys per object, removing the
previous unbounded-by-document-shape quadratic cost. Source hash selection uses fixed 64-byte
ASCII hex folding; matched hashes still pass strict decoding.

`test/ParserGas.t.sol` measures maximum bytes, 512 tokens, widest objects, long numbers/whitespace,
surrogate escapes and 128 source entries. A combined full deployment also exercises a 24,576-byte
runtime. The enforced test budgets are 9M for the parser corpus and 15.5M execution gas for the
combined deployment corpus. Recorded measurements and qualifications are in
[checks/consolidated](checks/consolidated/README.md). Allow intrinsic/calldata gas too. Arbitrary
constructor code can spend additional gas; these measurements are not a cap on all generated
constructors or a guarantee about every RPC provider. The SDK supplies an explicit 10M gas limit
for its full `check` call; a provider with a smaller cap will fail
closed. No particular provider's maximum has been established. A paid completion outside the limits cannot
be rewritten to pass; validate actual completion size/shape before enabling a pilot.

## Use, parameters and responsibilities

`python3 -m sdk.gated_deploy --help` describes the read-only preparation command. Supply the real
requester/deployer context, exact result bytes, code/constructor bytes, source/build/runtime hashes,
**source submission and review submission hashes**, manager and permissions. The SDK reconstructs
canonical evidence, verifies the snapshot, checks signer provenance, mines in bounded pages and
calls the contract's full `check` before returning unsigned calldata. Default automatic mode fails
before RPC; explicit `--binding-mode owner-confirmed` denotes manual trust only.

No fee, recipient, manager pin, token, factory or store-admin policy changed. Both owners still have
two-step ownership. The requester owner controls Intake, signer, templates, payment ceilings,
timeouts and recovery; the deployer owner controls permitted managers and age policy. They can veto
use and the requester owner can manufacture approvals through those existing trust powers. Prefer
an independently operated multisig and monitoring, but no governance redesign was added here.

### After launch

No launch is authorized or performed by this assignment. For any later independently approved
launch, use the real `$owner`, the official chain-specific Intake/IMD/signer, and the existing
reviewable deployment tools. Keep requester templates unset while blockers remain. The owner must
configure payment/action/template/timeout policy, enable the pinned manager with `setManager`, and
optionally set `maxJobAge`. FeaturedPlacements keeps its existing token/recipient configuration and
0.1 IMD economics; the previously proposed recipient still needs the existing approval process.
Do not replace it with a new recipient. Monitor signer epochs, Intake/template changes, bindings,
revocations and manager/age changes. Incident recovery is exceptional; it does not supply a routine
founder-free authentication route. There is no post-deployment call hidden in the launcher.
