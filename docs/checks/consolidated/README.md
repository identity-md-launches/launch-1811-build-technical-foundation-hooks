# Consolidated integration and audit fixes — 2026-10-17

Continues `cc847d8f35bc0b814d390eb76092eed6051c5ae3`, addressing
[audit ca404dfe](https://api.imd.fun/jobs/ca404dfe-00d1-4682-83cb-fa1b28f9826c/report.md).
These are contributor self-checks, not an independent audit or evidence of a deployed service.
No public transaction, deployment, paid Intake request, or live signature was made. Local signature
fixtures and disposable Anvil transactions exercise the existing security suite.

## Integration decision

**Automatic binding is disabled.** The official protocol and deployed Intake expose no authenticated
commitment relating the originating Intake/body to the oracle UUID, canonical question and artifact.
The signature authenticates an answer, but the HTTP admission mapping and writer-supplied pairing
are not authenticated by that signature. The owner-confirmed route remains an explicit legacy trust
assumption, not a proposed founder-free workaround. No backend, hot wallet or trusted signer was added.

[INTEGRATION_RESOLUTION.md](../../INTEGRATION_RESOLUTION.md) traces the full HookSpec, originating
Intake ID, chain, requester, gated deployer, manager/code hash, source, accepted review and build.
It identifies unavailable input delivery and the exact missing protocol primitive. Templates refuse
to publish when this context is missing; that is not a claim that input delivery is implemented.

## Findings and disposition

| Audit finding | Result and principal regression |
|---|---|
| 1: finalized revoked epoch has no recovery | Owner-only `closeRevokedVerdict(jobId)` requires the current verdict's actual revoked epoch. Both callback orders and both verdicts allow a fresh paid review; historical receipts/bindings, consumed UUIDs, used Intake IDs and deployed-job/artifact guards remain. `ConsolidatedSecurity.t.sol` tests ordinary NotPassed refusal, unrelated/live epochs, permissions, repeated closure and already-deployed jobs. |
| 2: approval stale immediately | Age starts at signature verification in both orders. Positive confirmation must occur within 23 hours, leaving at least one hour under the minimum one-day policy. Older positives preserve signed history and consumption but require a fresh review; negatives remain terminal regardless of age. No timestamp is refreshed by binding. |
| 3: irrelevant entries poison the snapshot | Missing/null/non-string selectors are skipped. Selected sources/files still require exact metadata, unique source identity and unique reserved name/path. |
| 4: JSON escapes/UTF-8 rejected | Strict UTF-8 and all standard JSON escapes, including valid surrogate pairs, are decoded into a private copy. Exact input/resultHash bytes remain untouched. Decoded duplicate keys, malformed scalars and case aliases fail closed. Escaped controls in irrelevant source hashes cannot alias hex digits. |
| 5: excessive parser gas | Contract and SDK enforce 12,288 bytes, 512 tokens, 32 object members, 128 array items and depth 16. Cached key hashes bound duplicate scans. Maximum-shape parser, full-check and deployment measurements are below. |
| 6: publication not tied to reviewed build | ArtifactV2 commits exact source and independent-review submissions, build identity, code/arguments/runtime, chain/deployer/manager/mask, and canonical evidence bytes. Both publication files must come from the same accepted publication submission. The oracle must establish review acceptance and build coverage; a worker file alone cannot approve deployment. Review-only submissions do not appear in live `source[]`, so no invented source-array entry is required. |
| 7: owner trust | Preserved and documented. The requester owner can change Intake/signer/templates and assert bindings; the deployer owner can veto managers/age. Incident recovery does not remove this trust. |
| 8: worker lacks originating context | Traced and explicitly blocked pending a supported authenticated delivery route. No guessed origin, deployer or manager is inserted. |
| 9: unverified live behavior | Deployed ABI/runtime and one unrelated real v2 signature verified read-only. The Hooks Store completion/answer pilot, exact live resultHash snapshot, canonicalization and founder-free binding remain blockers. |

Three existing delayed-confirmation tests now use a one-hour ask timeout, retaining their original
post-expiry, no-discard, no-repeat and fee-loss assertions inside the new positive freshness window.
New tests separately enforce stale-positive retry, 365-day negative finalization, and the exact
23-hour confirmation plus one-hour deployment boundary. No existing security assertion was removed.

## Reproduce local checks

From the repository root, with Foundry, pinned solc 0.8.26, Python 3.10+ and Node installed:

```sh
bash script/check_consolidated.sh
forge build --sizes
```

No network is needed for these checks. Dependencies remain the existing ordinary vendored files;
no package, submodule, compiler setting, remapping or dependency was added or changed. Python tests
use standard-library modules and disposable loopback Anvil instances. Tests do not read/set environment
variables, use a fork, or depend on a funded wallet. The explicit second seed is supplied by CLI,
without changing the protected configuration.

| Check | Final result | Evidence |
|---|---|---|
| `forge build` | Pass, solc 0.8.26, existing Cancun/optimizer settings | [build.log](build.log) |
| `forge test` | 536 passed, 38 suites, no failures/skips | [foundry.log](foundry.log) |
| Assignment seed full suite | 536 passed, no failures/skips | [assignment-seed.log](assignment-seed.log) |
| `forge fmt --check` | Pass | [fmt.log](fmt.log) |
| Python SDK, tooling, snapshot parity | 54 passed | [sdk.log](sdk.log) |
| Node site and ABI tests | 22 passed | [site.log](site.log) |
| Isolated oracle callback suite | 8 passed, 200k stipend | [callback-gas.log](callback-gas.log) |
| Isolated job callback suite | 1 passed, 200k stipend | [job-callback-gas.log](job-callback-gas.log) |
| Parser/combined deployment resource corpus | 7 passed | [max-deployment-gas.log](max-deployment-gas.log) |
| Captured live v2 signature, offline verification | Pass; unrelated price answer, not a Hooks review | [live-vector.log](live-vector.log) |
| Vendored checksum verification | 96 files, 24 previously recorded formatting-only differences | [vendored.log](vendored.log) |

The assignment seed is
`0x40bbcf769875f858aac6849e21037c680c23d3811f18267f1b80562a06409c89`; the repository seed remains
`0x936d89b088020ddf36122a88c4c9aed7130c7a410f5c44680a7d121950c99345`.
Both full runs include the pre-existing escrow conservation/withdrawal invariants and all security,
hook/pool, deployment, oracle, recovery, fee and admin-policy suites. Advisory compiler lints are
not errors. Slither/Mythril and independent adversarial review were not run.

`deployment/audited-build.json` remains historical. [Current build fingerprints](../../../deployment/current-build.json),
the refreshed site ABIs and [sizes.log](sizes.log) describe this local source. Compiler/dependency
configuration and unchanged store economics/admin source hashes match the historical record in
[preserved-policy-and-config.json](preserved-policy-and-config.json). Fees, recipients and ownership
policy were not changed.

## Runnable before/after regressions

[red-regression.sol.txt](red-regression.sol.txt) is the exact regression source run before the fixes.
In a separate checkout of the base commit, copy it to `test/ConsolidatedRegression.t.sol` and run:

```sh
forge test --match-path test/ConsolidatedRegression.t.sol --match-test testRegression -vv
```

[red.log](red.log) records five expected failures: finalized revocation in each callback order, late
approval, irrelevant entries, and legitimate UTF-8/escapes. The production code was unchanged for
that run. On this revision, the same regression behaviors pass; the fixture now supplies ArtifactV2
evidence. [green.log](green.log) includes all five plus inherited deployment/parser security tests
(58 passes). The regression files live under `test/`, not disposable `test/scratch/`.

Files with `initial` in their names and `window-refinement.log` are intermediate diagnostics, not
the final full-suite result. Final authoritative self-check logs are the ones linked in the table.

## Gas and size budgets

All figures below are local measurements with the unchanged compiler/settings. They do not assert
an arbitrary live signer, arbitrary constructor or provider is safe. The gas in Forge's test headline
also includes fixture construction/mining and is not the measured deploy-call gas.

| Cold forwarded callback | Minimum gas |
|---|---:|
| Job result, 4,096-byte URI | 67,030 |
| EOA, retained oracle receipt | 124,962 |
| 5-of-7 ERC-1271, retained / bound | 170,055 / 140,113 |
| 5-of-7, wrong pre-binding retained | 175,101 |
| Stress verifier with 22 extra cold reads, retained / bound | 187,209 / 157,006 |
| Stress verifier, wrong pre-binding retained | 192,264 |

The last successful path leaves 7,736 gas under the live Ethereum Intake's observed 200,000 stipend.
The existing deliberately excessive verifier still fails closed with one-shot fee loss and no partial
receipt. Its failure is expected and tested. No arbitrary verifier-gas guarantee is made.

| Maximum-shape corpus | Measured execution gas |
|---|---:|
| 12,288 bytes plus 512 parser tokens | 7,404,560 |
| 12,288 bytes plus broad 32-member objects | 7,531,419 |
| 12,288 bytes of surrogate escapes | 6,905,962 |
| Long number / whitespace | 6,611,262 / 4,099,623 |
| Full artifact check: max bytes/tokens, broad objects and escaped pad | 8,999,236 |
| Same snapshot plus 24,576-byte runtime deployment | 14,298,632 |
| 128 source entries plus max bytes: check / max runtime deployment | 7,670,768 / 12,961,145 |

Tests enforce parser <9M, full check <10M and combined deployment <15.5M execution gas. The SDK
sends an explicit 10M gas budget for its final `eth_call` check; smaller provider caps fail closed.
The parser has finite byte/token/width/depth bounds; this adversarial corpus is empirical gas
evidence, not a formal proof that it enumerates every possible JSON shape. Invalid bounds reject
before unbounded work, and SDK/Solidity acceptance parity is exercised on Anvil.

Do not size against block gas alone: [EIP-7825](https://eips.ethereum.org/EIPS/eip-7825) specifies a
16,777,216 per-transaction cap, and [Base's transaction documentation](https://docs.base.org/specifications/transactions/transaction-ordering)
also describes its approximately 16.7M transaction ceiling. The captured Ethereum block limit was
60M and Sepolia's 200M; those larger block limits do not establish a safe transaction budget.
The conservative 15.5M fixture ceiling leaves room for intrinsic/calldata gas. Real creation code
and constructor arguments need their own full transaction simulation; arbitrary constructors can
consume additional gas. The test uses a real CREATE2 deployment with maximal runtime and inert
padding, not arbitrary expensive constructor execution. Provider-specific `eth_call` limits are not
claimed as measured. A real completion outside any parser limit cannot be rewritten to pass its hash.

| Application runtime | Bytes | Margin below 24,576 |
|---|---:|---:|
| HookJobRequester | 24,559 | 17 |
| GatedHookDeployer | 20,427 | 4,149 |
| HooksStoreFactory | 13,970 | 10,606 |
| HookListingRegistry | 9,035 | 15,541 |
| FeaturedPlacements | 8,232 | 16,344 |
| BoundedSwapHook | 3,431 | 21,145 |

Requester size is tight; any future change must rerun the size check. Runtime templates with
immutables are build fingerprints, not hashes of an unspecified deployed instance.

## Live evidence and free checks

[binding-evidence.json](binding-evidence.json) compares the explorer's verified Intake runtime
byte-for-byte with the public RPC at block `0x18ffb7e`. The getter and verified source contain no
request/question binding. [sources](sources/) preserve the audit, official documentation/reference,
deployed ABI/source, request logs, unsigned admission record, oracle record and captured signature.
[provenance.json](provenance.json) identifies URLs, derivations and local SHA-256 hashes.
[live](live/) contains timestamped public capabilities, prices, code hashes and launcher observations.
These are observations, not authority to change deployment or payment settings.

The captured signature is for another consumer's uint256 price answer. Its successful offline
recovery proves the inspected v2 encoding/signature, not a Hooks Store review, canonical question
preimage, Intake association or successful delivery through this requester.

Both exact assembled request bodies were submitted only to the free `/requests/check` endpoint:

| Body | Raw bytes | Raw keccak256 | Checker result |
|---|---:|---|---|
| [job.open](job.open.body.json) | 2,705 | `0xdb375bd28c2ae544fcafdca756644767c81f4f450b3f3431cef2b68aef151fbe` | No blockers; `earlier_work` suggestion retained |
| [oracle.request](oracle.request.body.json) | 1,453 | `0x1aea626ac5d881f852139f5d73579098d9dfba5c76e35530cf3e605e4517fdea` | No blockers; exact normalized draft matches the full assembled body |

The check records retain raw SHA-256, raw keccak256, byte length, checker input, full response and
timestamp. Template tests reconstruct the same bytes and reject projection drift. Sample IDs/hashes
in these free-check fixtures are explicitly synthetic, never launch parameters or claimed live work.
No quote, payment or admission endpoint was called. A schema check is not proof of worker input
availability: the job check's `earlier_work` suggestion is consistent with the unresolved input gap.

## Unresolved launch blockers and responsibilities

Before activation: protocol-authenticated origin/question/artifact binding and canonicalization;
demonstrated delivery of the complete HookSpec and real context to workers; an actual accepted
source/review/build publication; a byte-identical bounded completion snapshot; and a Hooks Store
oracle pilot with the real domain, signer/panel and stipend. None is replaced by the captured price
answer or a public API lookup. Independent adversarial review and the existing final owner/recipient
approvals remain required. Keep templates unset while these blockers remain.

[GATED_DEPLOYMENT.md](../../GATED_DEPLOYMENT.md) records constructor/configuration parameters,
age policy, manager pins, migration to ArtifactV2, owner responsibilities and incident recovery.
[IMD_INTEGRATION.md](../../IMD_INTEGRATION.md) records payment, template, signer, expiry, monitoring
and handoff obligations. No launch manifest, token, pool or new recipient was introduced.
