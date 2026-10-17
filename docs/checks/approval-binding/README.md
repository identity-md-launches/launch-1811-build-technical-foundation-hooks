# Approval-binding implementation checks

Base commit: `2aef6408eabb45b8f149e16a96c7734d4b4b5b07` (verified before edits).
The assignment prohibits touching `.git`, so no commit was created here. The submitting system
can assign the resulting commit. `deployment/current-build.json` records the delivered source
hashes and bytecode fingerprints; `sourceCommit: null` does not pretend these changes are the base.

Local implementation and tests, not an audit or live-readiness claim. No public deployment,
paid admission, wallet signature or external fund movement. All contract execution and test
signatures used local Foundry/Anvil fixtures. Network calls were public documentation/catalog
reads and the free request checker only. Compiler settings, dependencies and the 200k stipend
were not changed.

## RED then GREEN

`red-regression.sol.txt` is the exact regression file run **before production edits**. `red.log`
records both expected-revert tests failing because deployment succeeded:

- A signed review covered a document naming A at top level and B under `rejected`; B deployed.
- A bind-first Passed verdict survived signer rotation and revocation of its verification epoch;
  deployment still succeeded.

`green.log` reruns those two tests after the fixes and also proves A deploys from an actual-schema
snapshot naming A in its unique accepted approval file while mentioning B in rejected content.
B is refused. The legacy arbitrary-worker-document format is deliberately refused altogether.
The original artifact, bytecode, constructor, runtime, manager, chain, permissions and replay
checks remain covered in `test/GatedHookDeployer.t.sol`.

## Commands / retained logs

| Command | Evidence |
|---|---|
| `forge build` | `build.log` (Solc 0.8.26) |
| `forge test -vv` | `foundry.log`: 358 passing tests across 31 suites, including existing escrow invariants |
| `forge test --match-test 'testRegression\|testApprovedADeploysFromSnapshotThatAlsoMentionsRejectedB' -vv` | `green.log` |
| `forge test --match-contract 'AcceptedArtifactTest\|ApprovalBindingRegressionTest' --fuzz-seed 0x345090baf5788add2566899a490658fcb1471984505f18b0671c8e41b224bfec -vv` | `assignment-seed.log` |
| `forge test --match-contract 'ReviewReceiptGasTest\|JobProtocolGasTest\|UriPilotGasTest' -vv` | `cold-gas.log` |
| `forge fmt --check` | `fmt.log` (empty output is success) |
| `python3 -m unittest discover -s test -p 'test_*.py' -v` | `sdk.log`: 49 passing tests |
| `node --test test/requester-abi.test.cjs test/listings-reader.test.cjs` | `site-abi.log`: 22 passing tests |
| `python3 script/prepare_deployment.py verify-build` | `build-identity.log` |

The full Foundry run uses the existing pinned fuzz seed
`0x936d89b088020ddf36122a88c4c9aed7130c7a410f5c44680a7d121950c99345`.
The additional focused run explicitly uses the assignment seed. Neither changes `foundry.toml`.
The regression contract inherits the existing 44 deployer tests; the Foundry count includes that
inherited coverage. An old one-hour fixture assertion was updated to match the checked 24-hour
oracle draft; its lifecycle, one-shot and fee-loss assertions remain intact.

Runtime templates: HookJobRequester **24,166 bytes** (410 below 24,576), GatedHookDeployer
**16,890 bytes**. Fingerprints include the compiler runtime templates; constructor immutables
mean deployed code hashes differ. `deployment/audited-build.json` is preserved as historical
baseline evidence, and is not relabelled as an audit of these changes.

## Cold callback gas

These are minimum **forwarded** gas measurements with cold requester and signer access, restored
state for each trial, and paid request allocation in an earlier transaction. The MockIntake
continues to forward exactly **200,000** gas and consumes its sole attempt even if delivery fails.

| Path / signer | Forwarded gas |
|---|---:|
| Early EOA receipt | 124,984 |
| Early 5-of-7 ERC-1271 receipt | 170,077 |
| Bind-first 5-of-7 ERC-1271 verdict, including epoch storage | 139,795 |
| Early 22-cold-read stress signer | 187,231 |
| Bind-first 22-cold-read stress signer | 156,968 |
| Wrong pre-binding / 5-of-7 | 175,123 |
| Wrong pre-binding / 22-cold-read stress signer | 192,286 |
| Job callback with 4,096-byte URI | 67,052 |

The deliberately over-budget signer still fails closed; no partial receipt/provenance is created.
These measurements are local examples, not a universal upper bound on ERC-1271 verification or
URI length. `UriPilotGasTest` retains the URI-ceiling pilot measurements. Artifact JSON verification
occurs during deployment/check, not during the callback.

## Actual protocol / checker evidence

`sources/provenance.json` records first-party URLs, retrieval times and SHA-256 for the preserved
IMD docs, OpenAPI, catalog/skill descriptions and the preceding project's actual result. These
are data sources; no commands from their content were run. The real result is an example of
accepted `source` and empty `files`, not an approval fixture. `fixtures/` is explicitly synthetic
and demonstrates the offline byte/hash chain; it is never presented as a live approval. The
SDK/Anvil tests construct full real-bytecode deployment cases, while Foundry uses the actual
requester and locally signed attestations in both callback orders.

`job.open.body.json` and `oracle.request.body.json` are the exact assembled sample bodies. Both
final checker records have `blockers: []`. The oracle checker accepts only its drafting subset;
`oracle.request.check.json` retains that exact projection and its returned full request, and
`assembledBodyMatchesDraft: true` confirms equality to the full onchain body. The tool and tests
refuse an otherwise unblocked draft that changes any full-body field. The previous full-input HTTP
400 and initial wording rejection are preserved separately; they are not treated as approvals.
No work was admitted, and sample ids are local schema fixtures, not existing paid requests.

## Changed trust and unresolved live gates

The deployed gate now trusts only the accepted source entry and unique canonical named approval
file committed by the control-plane snapshot, plus the correctly bound signed oracle verdict.
It rejects missing provenance and checks epoch revocation in both delivery orders, preserving
historical verdicts and consumed UUIDs. The owner still selects Intake/signer and authenticates
manual question bindings. The oracle still establishes review semantics and reproducibility.

The automatic route is **disabled**. The inspected public interface has no authenticated binding
proof over Intake chain/address/requester/request id/body hash and oracle UUID/canonical question/
resolved window. Its signed attestation omits the outer Intake id/body. HTTP lookups, callbacks or
an app-operated signer are not substituted for that missing protocol proof. See
[the precise interface gap and operating responsibilities](../../GATED_DEPLOYMENT.md).

Remaining gates: that official binding interface; actual worker publication of the named files
and earlier reviewed source bundle; actual completion encoding/URI availability; authenticated
canonical question/window mapping; live Intake/signer callback gas; per-chain manager/deployment
gas checks; and independent adversarial review. Passing local checks and free schema checks do
not resolve these gates.
