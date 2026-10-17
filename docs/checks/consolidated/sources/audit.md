# Audit report

> Audit commit cc847d8f35bc0b814d390eb76092eed6051c5ae3. Focus on the oracle-gated generated-hook deployer and its integration, including changes since 2aef6408eabb45b8f149e16a96c7734d4b4b5b07. Review only; no deployment, paid Intake calls or source fixes.
>
> Primary scope: GatedHookDeployer.sol, AcceptedArtifact.sol, ResultJson.sol, the signer-epoch change in HookJobRequester.sol, SDK/templates and deployment configuration.
>
> Attack the complete authorization chain: authenticated resultHash -> exact IMD completion snapshot -> unique accepted source/approval file -> exact artifact -> correctly bound signed verdict. Test duplicate/nested/escaped fields, parser limits and gas, hash/metadata mismatches, source/build substitutions, forged/unbound/missing/failed reviews, and replay. Check CREATE2, constructor/reentrancy, runtime/manager/permission readback and every deployment entry point.
>
> Verify signer provenance and revocation in BOTH callback/binding orders, including missing epochs, rotation and preserved historical verdicts. Preserve the 200k callback limit and 24,576-byte runtime limit.
>
> Use docs/checks/approval-binding and reproduce the regressions. Independently verify the real IMD schema and declared trust assumptions; fixtures/free request checks are not live delivery evidence. Automatic binding is explicitly disabled pending an authenticated protocol mapping proof: do not certify a founder-free or deployment-ready flow.
>
> Return severity-ranked findings with file/line, runnable reproductions and material audit blockers. Separate code safety, owner/oracle trust, protocol gaps and untested live behavior.

| | |
|---|---|
| Repository | https://github.com/identity-md-launches/launch-1811-build-technical-foundation-hooks.git |
| Commit | `cc847d8f35bc0b814d390eb76092eed6051c5ae3` |
| Job | `ca404dfe-00d1-4682-83cb-fa1b28f9826c` |
| Judged | 2026-10-17 08:33 UTC |
| Findings | 1 medium · 5 low · 3 info |

Four agents audited the code as it is at `cc847d8`, each in one area (math, permissions, economics, control flow),
and a judge reproduced, merged and ranked what they found, then read the code once more itself. Nothing in the repository was changed or deployed.

## Findings

### 1. Medium: [code safety / liveness] A finalized Passed verdict whose signer epoch is later revoked is a permanent dead end: no re-review or closure path in either callback order

`src/imd/HookJobRequester.sol:388`

```
                || (job.review != ReviewStatus.None && job.review != ReviewStatus.Unanswered)
```

Merged from audit_math, audit_permissions, audit_flow and audit_economics (all four reproduced the same mechanism). GatedHookDeployer._checkApproval (src/deployment/GatedHookDeployer.sol:275-278) correctly refuses a Passed verdict whose reviewReceiptSignerEpoch is in revokedSignerEpochs, in both the bind-first and receipt-first orders. But HookJobRequester offers no way out of that state. _answerReview deletes reviewOf[ask] (line 761), so closeRevokedReviewReceipt (line 514) and confirmReviewExpiry (line 808) revert UnknownOrSettled; in the bind-first order there is no early receipt at all, so closeRevokedReviewReceipt would revert ReviewNotReceived even if reviewOf survived. requestReview (lines 386-389) refuses any job whose review is Passed or NotPassed. The job therefore stays review == Passed forever while deployment is blocked forever. The only recourse for the creator is a brand-new paid job.open plus the full build/test/review chain plus a paid oracle.request, even though the delivered snapshot and artifact are unchanged and the revocation may be unrelated to this verdict (a key leaked after it was issued). By contrast an unfinalized retained receipt from the same revoked epoch does have a retry path (closeRevokedReviewReceipt -> Unanswered -> requestReview). docs/GATED_DEPLOYMENT.md line 205 tells the operator to 'use the existing guarded recovery calls' after a revocation, but none applies to a finalized verdict; the asymmetry is undocumented. Expected: after an owner revocation some owner-only or requester path restores liveness so a fresh verdict under the current epoch can re-establish provenance while the historical verdict stays in events. Actual: none exists. Minimal fix that preserves the design: an owner-only closeRevokedVerdict(jobRequestId) (or an extension of closeRevokedReviewReceipt) that requires jobs[job].reviewRequestId == ask, review in {Passed, NotPassed} and revokedSignerEpochs[reviewReceiptSignerEpoch(ask)] != 0, sets review = Unanswered, emits ReviewReceiptRevoked/ReviewUnanswered, and leaves consumed UUIDs, events and the deployer's replay maps untouched; GatedHookDeployer keys on job.reviewRequestId, so the old ask can never be reused and the new ask carries the new epoch.

**Reproduction**

test/scratch/Judge.t.sol::testRevokedEpochDeadEndBindFirst and ::testRevokedEpochDeadEndReceiptFirst (built on the repo fixture GatedHookDeployerTest). State: job Delivered with a valid snapshot; review Passed via _pass(jobId,true) (bind-first) or _passReceiptFirst(jobId) (receipt-first) under epoch 1. Owner: setOracleSigner(newSigner); revokeSignerEpoch(1, keccak256('incident')). Then: getJob(jobId).review == Passed; deployer.deploy(...) as the creator reverts ReviewRevoked(ask) [correct]; creator requestReview(jobId, 0.5 ether) reverts NotReviewable(jobId); owner closeRevokedReviewReceipt(ask) reverts UnknownOrSettled(ask); owner confirmReviewExpiry(ask) after the deadline reverts UnknownOrSettled(ask); review is still Passed. Expected: a path to a fresh verdict. Actual: none in either order. Run: forge test --match-path test/scratch/Judge.t.sol --match-test RevokedEpochDeadEnd -vv (both pass, i.e. the dead end is reproduced on this commit).

### 2. Low: [code safety / boundary] Approval staleness is measured from job open, not from the verdict, so a late delivery or review can make a genuine approval undeployable the moment it passes

`src/deployment/GatedHookDeployer.sol:280`

```
        if (block.timestamp > uint256(job.openedAt) + maxJobAge) revert ApprovalStale(job.openedAt, maxJobAge);
```

Merged from audit_math and audit_permissions. maxJobAge (default 30 days, owner-settable 1..180 days) is compared against job.openedAt. HookJobRequester accepts jobTimeout and reviewTimeout up to MAX_TIMEOUT = 30 days each, onJobResult explicitly accepts late Intake deliveries after local expiry (status Open or Expired), the shipped review template asks for a 24-hour oracle window with validForSeconds 86400, and re-asks after an Unanswered review add more days. None of that time is subtracted, so the real deployment window is maxJobAge minus (delivery delay + review latency), which is zero or negative with legal parameters: with the allowed setMaxJobAge(1 days) no job can ever deploy because the 24-hour oracle window alone consumes it, and with setTimeouts(30 days, x) a delivery at openedAt + 30 days leaves zero seconds. The shipped drafts (deployment/*.draft.json: jobTimeout 604800, reviewTimeout 86400) leave a practical margin, but the invariant maxJobAge > jobTimeout + review latency + deploy slack is enforced nowhere and documented nowhere (docs/GATED_DEPLOYMENT.md only says the owner 'optionally calls setMaxJobAge'). The owner can rescue a stranded job by raising maxJobAge afterwards, which is an undocumented operational coupling. Expected: the staleness bound measures the age of the approval (time since the verdict, e.g. recorded in _answerReview) or at least guarantees a minimum window after the verdict, optionally with an absolute cap from openedAt. Actual: bound from openedAt only; the gate wastes a paid job and paid review for a timing reason unrelated to the safety of the artifact.

**Reproduction**

test/scratch/Judge.t.sol::testStaleMeasuredFromOpenNotVerdict: open job at T; vm.warp(T + 30 days - 1 hours); Intake delivers the snapshot; _pass(jobId, true) so getJob(jobId).review == Passed; vm.warp(T + 30 days + 1); deployer.deploy(a, doc, code, args, salt, hook) as the creator reverts ApprovalStale(openedAt, 2592000). Expected: a verdict that is about one hour old is deployable. Actual: refused permanently unless the deployer owner raises maxJobAge. Run: forge test --match-path test/scratch/Judge.t.sol --match-test testStaleMeasuredFromOpenNotVerdict -vv.

### 3. Low: [code safety / liveness] One unrelated accepted entry in the immutable snapshot (a source entry with null hash, a file without name/path) reverts the whole gate for an otherwise valid approval

`src/deployment/AcceptedArtifact.sol:56`

```
            if (d.hashValue(d.member(cursor, "hash")) == sourceHash) {
```

Merged from audit_math (and the brittleness half of its untested-live finding). _source calls member(cursor,'hash') and hashValue on EVERY source[] entry, and _approval (lines 76-77) calls member(cursor,'name') and member(cursor,'path') on EVERY files[] entry, before deciding whether the entry is the one being looked for. ResultJson.member reverts InvalidResultJSON on a missing key and hashValue reverts on anything that is not a 64-hex string. The snapshot is produced by the control plane from every accepted step of the four-step chain (implement-contract, write-foundry-tests, adversarial-review which 'writes no files', research-report with two outputs), it is immutable, and its keccak256 is pinned by the Intake callback, so the requester cannot repair it. Hence an entry the gate does not even need makes the approval permanently unusable: a step whose accepted entry has 'hash':null, an extra accepted file (hooksStoreEvidence or a report) whose entry omits name or path, or a source entry whose hash is not 64 lowercase hex. The only real snapshot in the tree (docs/checks/approval-binding/sources/previous-job-result.json) has files: [] and a single source entry, so no live multi-entry shape has ever been parsed by this code. Expected: entries that are neither the approval file nor the target source are skipped; only the matching entries are strictly validated. Actual: whole-document revert (InvalidResultJSON) and GatedHookDeployer.deploy reverts for that job forever. Minimal fix: a non-reverting tryMember in _source/_approval that skips entries whose hash/name/path is absent or not a string, keeping strictness for the matched entries.

**Reproduction**

test/scratch/Judge.t.sol::testNullHashSourceEntryRevertsWholeSnapshot and ::testFileWithoutNameRevertsWholeSnapshot. Input (a): the fixture snapshot (correct accepted source, unique correct hooksStoreApproval file) plus a second source entry {"node":"adversarial_review","submissionHash":"11..11","hash":null}; AcceptedArtifact.verify(snapshot, digest, sourceHash) reverts InvalidResultJSON. Input (b): the fixture snapshot plus a second accepted file {"path":"artifacts/report.md","hash":"11..11","bytes":1,"mediaType":"text/markdown","submissionHash":"11..11"} (no name); verify reverts InvalidResultJSON. testBaselineDocVerifies shows the same document without the extra entry returns true. Expected in both: true. Run: forge test --match-path test/scratch/Judge.t.sol --match-test RevertsWholeSnapshot -vv.

### 4. Low: [untested live behavior] Any JSON escape or non-ASCII byte anywhere in the live completion snapshot, even in fields the gate never reads, permanently blocks an approved artifact; live snapshot encodin

`src/deployment/ResultJson.sol:158`

```
            if (uint8(c) < 32 || uint8(c) > 126 || c == "\\") revert InvalidResultJSON();
```

Merged from audit_permissions, audit_flow and audit_economics. _string rejects every string containing a backslash, a control byte or any byte > 126, at any depth, including fields the gate never reads (delivery.failure, delivery.repoUrl, launch, source[].url, files[].url, projectId). The snapshot bytes are fixed by the Intake's resultHash and cannot be normalized, so a single escaped quote in a GitHub delivery failure message, a '\/'-escaped slash from a different serializer, a \uXXXX escape or a non-ASCII filename makes the job's approval unusable forever. The sdk/result_snapshot.py mirror applies the same rule, so the SDK cannot rescue it either. The one real snapshot in the tree (sources/previous-job-result.json, 827 bytes) is compact ASCII and parses, but it has files: [] and failure: null; no completed snapshot with a non-empty files array, a delivery failure or chained source entries has been observed, and docs/checks/approval-binding/README.md itself lists 'actual completion encoding' as an unresolved gate. The documented IMD schema does not promise ASCII-only, escape-free serialization. This is fail-closed by design and is not an authorization weakness; it is reported so that it is not mistaken for proven live compatibility and because the cost of a mismatch is a wasted paid job and review. Fix options: tolerate the JSON escape subset (skip \x pairs and bytes >= 0x80) in strings that are never compared while keeping exact-match semantics for compared keys/values, or obtain and record a first-party serializer guarantee and a live parsed sample before any pilot.

**Reproduction**

test/scratch/Judge.t.sol::testEscapedUnreadFieldBlocksApprovedJob: the fixture snapshot with an added unread member ,"delivery":{"requested":true,"failure":"push rejected: \"main\" is protected"} delivered by the Intake as the resultHash preimage; review Passed; correct artifact and mined salt. Expected: the gate reads only jobId/state/complete/source/files and deploys. Actual: deployer.deploy reverts ResultJson.InvalidResultJSON() and no alternative encoding can match job.resultHash. Existing coverage: test/AcceptedArtifact.t.sol testDuplicateKeysAnywhereAndEscapedAliasesFailClosed shows the \n case. Run: forge test --match-path test/scratch/Judge.t.sol --match-test testEscapedUnreadFieldBlocksApprovedJob -vv.

### 5. Low: [code safety / gas] Verifying a snapshot at the contract's own 64 KiB ceiling costs about 33-35M gas, above common eth_call caps and near or above several target chains' block limits

`src/deployment/GatedHookDeployer.sol:59`

```
    uint256 public constant MAX_RESULT_DOCUMENT_BYTES = 65536;
```

Merged from audit_math, audit_permissions, audit_flow and audit_economics (measurements agree within a few percent). ResultJson scans every byte through memory-struct field updates (d.pos++ per byte in _string, per-byte range checks), tokenises into a Token[] of up to 2048 five-word structs, and _uniqueKey re-hashes every earlier key of an object for each new key (quadratic per object, up to 128 keys). Measured on this commit with the project's compiler settings: a 541-byte fixture-shaped snapshot verifies in 579,468 gas; a well-formed 65,536-byte, 1,953-token snapshot that passes every gate costs 33,065,165 gas in check() and 34,530,363 gas in deploy(). HookMiner's own comment notes RPC eth_call caps of 25-50M, and sdk/gated_deploy.py runs check() through eth_call before building any transaction, so such a job is refused by the SDK; several pinned chains have per-block or per-transaction limits at or below that figure. Wide objects are worse: six 128-key objects (1,615 tokens, 8.7 KB) parse in ~35.6M gas, so the 2048-token cap can be reached far below 64 KiB and the documented 128-item array bound cannot actually be used with 7-field file entries (128 files x 7 fields plus 10 sources exceeds 2048 tokens and reverts with the generic InvalidResultJSON). Only the control plane controls snapshot size, so this is not an attacker lever; realistic snapshots are 1-3 KB and cost 0.6-2M gas. It is a mismatch between the constant and the NatSpec bounds on one side and what is deployable on the other. Fix: lower MAX_RESULT_DOCUMENT_BYTES to a value whose worst case was measured against the smallest target budget (about 16 KiB gives ~9M), cache d.pos/d.data in locals or scan strings word-wise in assembly, make the token-cap failure a distinct error, and document the real bounds.

**Reproduction**

test/scratch/Judge.t.sol::testGasAtDocumentCeiling: builds the fixture snapshot plus a 'pad' member of 15 arrays of 127 zeros and a filler string so the document is exactly 65,536 bytes, delivers keccak256 of it as the job result, passes the review, then measures gas around deployer.check(...) and deployer.deploy(...). Logged on this commit: check gas 33,065,165; deploy gas 34,530,363; token count 1,953; fixture-size verify 579,468 gas for 541 bytes. Expected: a document the contract accepts verifies within a typical 25-30M eth_call budget. Actual: ~33-35M. Run: forge test --match-path test/scratch/Judge.t.sol --match-test testGasAtDocumentCeiling -vv.

### 6. Low: [protocol gap / oracle trust] On chain, the approval file is a worker-authored constant and any accepted source entry qualifies; nothing ties the approval or the matched source to the adversarial-revi

`src/deployment/AcceptedArtifact.sol:83`

```
                        || d.hashValue(d.member(cursor, "submissionHash")) == bytes32(0)
```

Merged from audit_permissions and audit_economics. Reported as a declared-design gap and material blocker for any founder-free or deployment-ready claim, not as a permission bypass. The hooksStoreApproval file is emitted by the fourth research-report step, an ordinary IMD worker that also reads the creator's untrusted brief embedded in the job objective; approvalDocument(digest) always contains "review":"passed" and carries no reviewer identity, review submission hash or verdict beyond the digest. AcceptedArtifact.verify requires only (a) some top-level source[] entry with hash == a.sourceHash and any nonzero submissionHash, regardless of which node produced it (line 56), and (b) the unique files[] entry named hooksStoreApproval with the right sha256/bytes/mediaType and any nonzero submissionHash (line 83). Nothing relates either submissionHash to the adversarial-review step, to each other, or to the artifact's buildHash/creationCodeHash/runtimeCodeHash. A chained job yields one accepted bundle per step, so an approval may name the pre-test bundle while the review covered a later one, and 'accepted' for a review submission means IMD accepted the report, not that the hook had no findings. The only thing connecting 'independent review passed for THIS bytecode' to the Passed flag is the 7-member panel answering true to the question in sdk/request_templates.py, which is set by the same requester owner. This matches the repository's own statements (automaticBindingSupported() == false; docs/GATED_DEPLOYMENT.md). Hardening that keeps the design: include the accepted review submission hash in the HookArtifact struct and the approval document so the panel question and the on-chain digest name the same review, and require the hooksStoreEvidence file's hash in the artifact.

**Reproduction**

test/scratch/Judge.t.sol::testAnyAcceptedSourceEntryQualifies: snapshot with source[] = [{node write_foundry_tests, hash H_reviewed, submissionHash S1}, {node implement_contract, hash H_pretest, submissionHash S2}] and a unique accepted hooksStoreApproval whose digest commits sourceHash = H_pretest, submissionHash 0x..01. Expected if the chain bound the approval to the reviewed bundle: refusal. Actual: AcceptedArtifact.verify returns true (test passes on this commit), and GatedHookDeployer.deploy accepts it once job.review == Passed. grep submissionHash src/deployment/AcceptedArtifact.sol shows only the two nonzero checks at lines 57 and 83.

### 7. Info: [owner/oracle trust] The HookJobRequester owner alone can manufacture a complete passing authorization chain; the GatedHookDeployer owner can veto every deployment

`src/imd/HookJobRequester.sol:898`

```
    function setOracleSigner(address to) external onlyOwner {
```

Merged from all four specialists; recorded as the design's declared trust assumption (docs/THREAT_MODEL.md, docs/GATED_DEPLOYMENT.md), not a bypass. Every input the deployer trusts is set by one role with no timelock or second party: setIntake (line 877) chooses who may call onJobResult/onReviewResult, so a self-deployed IIntake can deliver any resultHash for a job the owner opened; setOracleSigner (line 898) starts a new epoch under a key the owner holds; bindReview supplies the oracle UUID/questionHash/window the callback is matched against with no on-chain proof; setJobTemplate/setReviewTemplate define the question itself; resetReviewBinding, confirmReviewExpiry and discard* can set aside genuine answers. GatedHookDeployer only reads getJob, revokedReviewReceipts, reviewReceiptSignerEpoch and revokedSignerEpochs from the immutable requester and adds no independent authenticity check; its own owner controls setManager (any contract with code on 31337/84532/46630) and setMaxJobAge (down to 1 day, which retroactively stales every pending approval) and can therefore stall or veto any creator's deployment, reversibly and with events. The two-step StoreAdmin ownership is the only protection. Verified during this review: the four pinned PoolManager code hashes in GatedHookDeployer.sol are the ones the specialists re-read live on 2026-10-17 for chains 1, 8453, 4663 and 11155111; the requester is immutable in the deployer; runtime sizes HookJobRequester 24,166 B and GatedHookDeployer 16,890 B are under 24,576 (forge build --sizes); the 200k forwarded-gas stipend is unchanged. Preconditions for abuse: a single owner key. Mitigation that preserves the design: multisig/timelock for both owners, monitoring of IntakeSet/OracleSignerEpochStarted/ReviewBound/MaxJobAgeSet, and optionally a deployer-side minimum delay between ReviewAnswered and deploy so observers can revoke.

**Reproduction**

test/scratch/Judge.t.sol::testRequesterOwnerAloneMintsPassingChain: with the fixture's owner-chosen Intake (MockIntake), the owner calls setOracleSigner(vm.addr(ownerKey)); the creator calls requestReview; the owner binds a self-chosen context; the Intake delivers an attestation signed by ownerKey; deployer.deploy succeeds with no independent review having happened. Expected per the stated threat model: allowed. Actual: allowed (test passes). Veto: as deployer owner setMaxJobAge(1 days) then any job with openedAt < now - 1 day reverts ApprovalStale (covered by the existing testStaleApprovalRefused shape); setManager(manager, 0, false) reverts ManagerNotEnabled for every artifact (existing testDisabledManagerRefused).

### 8. Info: [protocol gap / untested live behavior] The job body gives the publishing worker no Intake request id, deployer, chain or manager parameters, so the HookArtifact it must commit to cannot be derived fr

`sdk/request_templates.py:20`

```
        {'skill': 'research-report',
```

Reproduced from audit_flow. HookJobRequester.openJob assembles the body as prefix ++ 0x<specHash> ++ middle ++ brief ++ suffix (src/imd/HookJobRequester.sol:309). The Intake request id is only returned by intake.requestWithFailure after the body is fixed, so it can never be in the body; the deployer address, chain id, PoolManager, its code hash and the HookSpec itself are not in the body either (only the spec hash is), and the template declares no inputs. The research-report step is told to compute HookArtifact 'per the supplied GatedHookDeployer ABI' with 'jobRequestId is the originating Intake job id', yet nothing supplies them: the worker must discover the Intake id from chain logs (JobOpened's requestId matched by bodyHash) or from the unauthenticated HTTP /intake/:chainId/:txHash record, and must be told the deployer address out of band. If any parameter is wrong the approval names a digest the deployer will never accept; if the worker follows the 'emit no passed approval' rule, no approval is ever produced. docs/GATED_DEPLOYMENT.md acknowledges supplying these via actual job inputs as future work. Not a code defect; a blocker for the end-to-end path resultHash -> accepted approval file -> artifact, which has never been exercised against a live job.

**Reproduction**

State: deploy HookJobRequester with deployment/hook-templates.json fragments; call openJob(specHash, brief, max). Inspect the emitted JobOpened body (test/HookJobRequester.t.sol fixture, or sdk.request_templates.assemble): it contains the spec hash and brief only. Expected (per the research-report objective at sdk/request_templates.py:20-22): the worker can read jobRequestId, deployer, chainId, poolManager and permissions from its inputs. Actual: none appear in the body or in any declared input; docs/checks/approval-binding/README.md:108-113 lists 'actual worker publication of the named files' among unresolved gates.

### 9. Info: [untested live behavior / audit blockers] resultHash-to-snapshot byte identity, canonical question hash, live Intake callback gas and automatic binding are unverified; nothing in the tree supports a f

`src/deployment/GatedHookDeployer.sol:188`

```
    function automaticBindingSupported() external pure returns (bool) {
```

Merged from audit_math and audit_permissions. Verified locally in this review: both callback orders record and check the verification epoch (ApprovalBindingRegression tests and the scratch tests above); revocation blocks deployment in both orders; nested/duplicate/escaped fields, replay (deployedHookOf, usedArtifact), CREATE2 prediction, constructor reentrancy (nonReentrant plus approval consumed before CREATE2), runtime/manager/permission readback and every deployment entry point (deploy is the only state-changing gated path; check/verifyDeployment/mine/predict are views) behave as documented; the sdk/result_snapshot.py mirror parses the real sample. Still unverified and required before any live claim: (1) the protocol publishes no authenticated Intake-request-to-oracle-UUID/canonical-question mapping, so bindReview context is owner-asserted and automaticBindingSupported() correctly returns false; (2) the fixture questionHash is keccak of a mock string, so no test proves the owner can compute the real canonical hash the oracle signs; (3) no live Intake callback has delivered a real attestation or job result to this contract, so the 200k stipend is validated only against MockIntake (heaviest local path 192,286 of 200,000 forwarded gas per docs/checks/approval-binding/cold-gas.log, leaving a 7,714-gas margin for a heavier real signer, which would fail closed and burn the one-shot delivery); (4) no live /intake-results/:id snapshot of a 4-step chained job with the two named outputs has been fetched and shown byte-identical to resultHash and accepted by AcceptedArtifact.verify; (5) the oracle panel's ability to answer the 24-hour review question reliably is untested. docs/checks/approval-binding/summary.json records liveReadinessClaim=false and fixtures/ is marked synthetic; the free request checker's blockers=[] is a schema check, not delivery evidence. The deployment manifest status already says 'not audited'; these items should be listed explicitly as blockers there and in docs/GATED_DEPLOYMENT.md.

**Reproduction**

State: docs/checks/approval-binding/summary.json line 46 liveReadinessClaim=false; sources/previous-job-result.json is the only real snapshot and has files: [] (python3 -I -c 'from sdk.result_snapshot import parse_snapshot' on its bytes returns files [] and failure None); fixtures/completion.json is synthetic. Expected for a deployment-ready verdict: a live Passed attestation delivered by the real Intake and a live snapshot verified through check(). Actual: none exists in the tree; a reviewer attempting to certify finds no artifact to point at.

---

Judge's submission `e8142def83ae60132b12bdb6824bdddf46b1c7bd207f4d83a096d254ced0d79b`, accepted on the IdentityMD network. Acceptance means the report met the job's checks;
it is not a guarantee that the code has no other defects.
