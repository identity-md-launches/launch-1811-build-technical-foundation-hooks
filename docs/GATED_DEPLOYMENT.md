# Oracle-gated generated-hook deployment

This patch continues `2aef6408eabb45b8f149e16a96c7734d4b4b5b07`. It is source and local tests only.
No public deployment, paid request, wallet signature, key handling, token or pool creation occurred.
Local mocks and test signatures are test fixtures. This is **not an audit or a live-readiness claim**.

`GatedHookDeployer` enforces the approval onchain. Its immutable requester must report a Delivered
job and Passed review, with authenticated, nonzero, unrevoked signer-epoch provenance. The creator
must supply the exact control-plane completion snapshot. A substring, arbitrary worker JSON,
Delivered status, owner manager allowlist or user-supplied review URL cannot authorize a deployment.

## Completion snapshot and accepted evidence

[IMD completion schema](https://imd.fun/docs/#intake-what-comes-back) says the job callback is
`(bytes32 requestId, bytes32 resultHash, string uri)`. `resultHash` is **keccak256 of the exact
control-plane `/jobs/:id/result` snapshot at completion**. Obtain its bytes from the completion's
IPFS URI or `/intake-results/:id`; do not hash a fresh status response, URI, callback encoding,
reserialized JSON, worker submission or report. The requester authenticates Intake delivery;
the job completion itself is not oracle-signed.

The public result schema has `jobId`, `state`, `complete`, `launch`, `source`, `files`, `delivery`
and optional fields such as `projectId`. [Accepted source and named files](https://imd.fun/docs/#jobs)
carry `hash` and `submissionHash`; named files also carry `name`, `path`, `mediaType`, `bytes`, `url`.
[Bundle and file hashes are SHA-256](https://imd.fun/docs/#uploads). The captured real result for the
preceding project job has an accepted source entry and **no named files**; it cannot authorize
this new route. Sources and exact responses are retained under `checks/approval-binding/sources/`.

The new path is:

1. Build the hook, test it independently, and obtain the independent adversarial review. Identify
   an earlier accepted source bundle containing the exact reviewed code and tests. `sourceHash`
   is that bundle's SHA-256. Choose it **before** the evidence publication step; do not hash an
   archive that contains its own approval document. `buildHash` is keccak256 of the exact build
   identity file (compiler/version/settings, dependency hashes, contract target and source selection).
2. Publish the named output `hooksStoreApproval`, path `artifacts/hooks-store-approval.json`, media
   type `application/json`. Its bytes must equal `approvalDocument(artifact)` exactly: compact JSON,
   lowercase hex, this key order, no trailing newline:

   ```json
   {"schema":"hooks-store-approval-v1","hooksStoreArtifact":"0x<64 lowercase hex digest>","review":"passed"}
   ```

   The real document is 144 bytes. It is a separate worker file, **never an injected top-level
   completion field**. The job template uses a fourth publication step after build/tests/review:
   IMD's `adversarial-review` skill writes no files, so that reviewer is not asked to emit JSON.
   Publication reports the accepted review and exact artifact; it does not grant approval by itself.
   The accompanying `hooksStoreEvidence` output records source/build and accepted-review references
   for the oracle panel. The contract does not parse that explanatory file or trust its URLs.
3. Onchain, require exactly one matching accepted source hash in the snapshot's **top-level
   `source` array**, and exactly one reserved approval name/path in its **top-level `files` array**.
   Validate metadata, nonzero submission hashes, SHA-256 of the reconstructed approval document
   and its byte count. Neither nested `rejected.files` nor an unrelated marker is considered.
4. A separate oracle question asks whether these public accepted records describe the exact
   reviewed artifact without unresolved findings. The existing authenticated question/UUID/window
   binding and oracle signature verification remain required. A valid file without Passed, and
   Passed without the accepted file, both fail.
5. `sdk.gated_deploy` verifies the exact snapshot hash, accepted evidence and epoch, mines a salt
   through read-only calls, runs `GatedHookDeployer.check` at the same RPC block, and returns unsigned
   deployment calldata plus its evidence. The contract rechecks everything at execution and reads
   back runtime hash, `poolManager()` and `getHookPermissions()` after CREATE2.

The parser deliberately supports a bounded JSON subset: at most 65,536 bytes, depth 16, 128 entries
per object/array and 2,048 tokens, printable ASCII strings without escapes. Structural JSON whitespace
is allowed. Duplicate object keys **at every depth**, escaped aliases, duplicate approval entries,
conflicting name/path aliases, malformed metadata and unsupported encodings fail closed. Unknown
well-formed fields are ignored; they cannot replace `source` or `files`. Snapshot bytes may not be
normalized to pass the parser because doing so changes `resultHash`. A live snapshot outside this
subset needs a reviewed parser extension; it must not be rewritten. The old marker-only documents
are deliberately no longer accepted. `artifactMarker` remains a display helper, never a proof.

## Exact artifact binding

`artifactDigest = keccak256(abi.encode(ARTIFACT_TYPEHASH, Artifact))`. The type and deploy/check
signatures are unchanged. Each field remains bound:

| Field | Meaning |
|---|---|
| `jobRequestId` | Exact Intake job id; its stored result hash commits the snapshot containing the approval |
| `sourceHash` | SHA-256 of the selected accepted source bundle |
| `buildHash` | keccak256 of the exact build identity file; reviewers establish reproducibility |
| `creationCodeHash` | keccak256 of creation bytecode |
| `constructorArgsHash` | keccak256 of ABI-encoded constructor bytes |
| `runtimeCodeHash` | Expected deployed runtime keccak256, including resolved immutables |
| `chainId`, `deployer` | Must be this chain and this deployer |
| `poolManager`, `poolManagerCodeHash` | Enabled/pinned pair and current code hash |
| `permissions` | Exact valid 14-bit callback mask, also checked in address bits and readback |

No salt is signed: any mined salt meeting the exact mask is usable. One deployment per job and
artifact, with approval consumed before CREATE2. Reverting, reentering, empty-runtime, substituted
bytecode/constructor, dishonest-readback and environment-dependent constructors remain covered.
Wrong caller/context, stale jobs, missing/pending/negative/unanswered reviews and replay still fail.
The default job-age limit is 30 days from job opening; owner bounds remain 1–180 days.

## Revocation in both orders

The signature's verification epoch is now retained for **bind-first and receipt-first** delivery,
for both positive and negative verdicts. The immediate-finalization path writes just the epoch into
the already allocated receipt metadata word. It does not materialize an early receipt or change the
10-word receipt ABI, 15-word Job ABI, replay map, events, verdict or callback authentication.
`reviewReceiptSignerEpoch(ask)` now means verification provenance in either order; zero means none.

Ordinary rotation leaves an old approval usable. Explicit `revokeSignerEpoch(oldEpoch, incidentHash)`
after rotation prevents deployment from that epoch in either order. Missing provenance also refuses
deployment. Historical Passed/NotPassed and consumed UUIDs remain unchanged. Revocation cannot undo
an already deployed hook. Old bind-first approvals from an older requester with no epoch fail closed;
there is no owner migration shortcut for fabricating provenance.

## Chains and managers

Production pins come from Uniswap's first-party deployment table and a live `eth_getCode`
readback. They are recorded in `docs/checks/gated-deployment/managers.json` and can be rechecked
with `script/recheck_gated_managers.sh`:

| Chain | PoolManager | Policy |
|---|---|---|
| Ethereum 1 | `0x000000000004444c5dc75cB358380D2e3dE08A90` | only this address and code hash can be enabled |
| Base 8453 | `0x498581fF718922c3f8e6A244956aF099B2652b2b` | only this pair |
| Robinhood Chain 4663 | `0x8366a39CC670B4001A1121B8F6A443A643e40951` | only this pair |
| Sepolia 11155111 | `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543` | only this pair |
| 31337, 84532, 46630 | not pinned | the owner enables a reviewed manager |
| any other chain | — | `UnsupportedChain` |

There is no blanket mainnet unlock. Each chain starts with no manager enabled, and the owner must
call `setManager` with the pinned pair. Enabling also needs the live code hash to match. None of
these chains has been exercised with a deployment, a fork or a gas benchmark.

## Authenticated binding: automatic route disabled

`automaticBindingSupported()` is always false. The SDK defaults to refusing automatic preparation.
Only explicit `--binding-mode owner-confirmed` prepares a transaction against a finalized manual
binding. It does not call `bindReview`, run a service, manage a wallet, collect a signature or send
any transaction. It reports the owner trust assumption in its output. There is **no founder-free
automatic route implemented or claimed**.

The precise missing protocol evidence is a cryptographically authenticated relationship between:

- origin Intake chain/address, consumer/requester, **Intake review request id and exact bodyHash**;
- oracle UUID, **canonical questionHash and its full canonicalization/preimage**, question chain,
  and resolved absolute `fromBlock`/`toBlock`;
- a defined protocol authority, consumer/chain domain separation, expiry and replay rules.

An onchain authenticated registry or protocol-signed binding with those fields and a documented
verification interface could supply it. No such binding interface is present in the captured docs
or OpenAPI. This is a limit of the **published interface inspected**, not a claim about unpublished
protocol internals. The documented OracleAttestation v2 signs the oracle UUID and question hash,
but does **not** sign the outer Intake request id or request body. The HTTP `/intake/:chainId/:txHash`
and `/oracle/requests/:id` records are useful observations, not onchain-verifiable binding proofs.
The docs explicitly warn the writer can pair an answer with a different request. Receiving a valid
attestation, matching its own fields, or trusting an HTTP response cannot authenticate that pairing.
A Merkle inclusion proof without an authenticated root and the complete binding fields is also
insufficient. The full canonical question construction cannot be replaced with keccak256(raw body).

The existing manual `bindReview` remains owner-only. An unbound answer stays Pending regardless of
who submits its fields. Owner recovery, expiry, signature, replay and one-shot protections remain.
The owner must independently authenticate the context, and can still misbind if dishonest. Eliminating
that owner transaction needs the missing official proof, not a new hot wallet signing our own mapping.

## Templates and free request checker

`sdk/request_templates.py` creates actual-schema job and oracle fragments. `deployment/hook-templates.json`
contains a **schema-check sample**, not a paid job or deployment configuration. Sample ids are local
hashes and must never be represented as existing public requests. Build and test steps have their
write paths, the reviewer writes nothing, and a final evidence publication step declares named outputs.
The separate oracle question inspects public accepted records, not commands run on panel hosts.

Both final assembled sample bodies passed the free `POST https://api.imd.fun/requests/check` with
`blockers: []`. The oracle checker accepts only drafting fields. `script/check_request_body.py`
projects those fields, retains the exact input, and requires the returned full `request` to equal
**the entire assembled body**, including window, quorum and validity. A mismatched draft fails even
with no blockers. The SDK's template validator enforces the same check. Initial full-body rejection
and the earlier wording blockers are retained, followed by final successful responses. A local Anvil
test proves the real requester assembles these same bytes (only the local request id is substituted).

A schema check proves no worker output, authenticated binding, oracle answer, completion delivery
or live deployment. Recheck each actual configured body; the job checker also recommends supplying
all prior-work links. Before asking workers, supply the HookSpec, chain/deployer/manager parameters,
current ABI and build rules via the actual job inputs. Missing parameters must leave approval absent.

## Trust and operational responsibilities

- **Configured Intake/writer:** commits the snapshot and accepted-file metadata. That is its word,
  not an oracle signature over the snapshot. The signed oracle verdict and correctly bound question
  must confirm this exact accepted evidence. The owner can replace Intake, including for pending jobs.
- **Oracle panel/signer:** establishes review semantics and reproducibility; the contract cannot
  derive source code from bytecode or establish independence of reviewers. Signer replacement remains
  an owner power. Local 5-of-7 ERC-1271 tests do not claim IMD currently operates such a signer.
- **Requester owner:** manually authenticates every binding, sets templates and signer, handles
  compromised-epoch revocation/recovery and pending asks. These powers remain trust assumptions.
- **Deployer owner:** enables pinned managers, disables them, and sets maximum job age; cannot change
  the immutable requester or bypass artifact/review/replay checks. A manager allowlist is not approval.
- **Creator:** supplies exact snapshot/code/constructor bytes and sends any eventual deployment from
  the recorded job-requester wallet. SDK output is unsigned and may become stale after its read block.

## Parameters / After launch

No new launch inputs are guessed. Deployer constructor remains `(owner_, requester_)`, with launch
owner and actual requester supplied by the operator. The requester constructor/configuration remains
in the existing runbook. All configuration below is future work, not authorization for this assignment:

- Owner enables the reviewed live manager pair using `setManager(manager, codeHash, true)` after
  checking target-chain code and the pins. Unknown chains fail closed; managers start disabled.
- Owner optionally calls `setMaxJobAge(seconds)` within the unchanged bounds.
- Requester owner sets the checked job/review templates, action ids and panel minimums, confirming
  actual protocol compatibility and costs. Both orders of `bindReview` still require that owner.
- For incident response, rotate the signer, revoke the old epoch with the incident evidence hash,
  monitor retained receipts and use the existing guarded recovery calls. Do not erase history.

`HooksStoreFactory` remains an ungated local/testnet-only BoundedSwapHook route; its hooks are not
approved by this deployer. Nothing migrates or changes an existing deployed contract.

## Checks and unresolved live gates

See [retained RED/GREEN, full checks and sources](checks/approval-binding/README.md). Solidity 0.8.26,
Cancun, optimizer 200 and metadata settings are unchanged. The cold callback cap remains **200,000**;
the deployed runtime cap remains **24,576 bytes**. The size and callback logs are local evidence only.
The fixed approval parser runs during deployment/check, not during the one-shot callback.

Open gates are the missing official binding proof (automatic route disabled), production acceptance
and publication of the named output/earlier reviewed source bundle, real snapshot encoding and URI
availability, exact question canonicalization and resolved window, a live signer/Intake callback-gas
pilot, per-chain deployment gas/manager confirmation, and independent adversarial review of these
changes. No live-readiness or audit assurance is inferred from passing local tests or the free checker.
