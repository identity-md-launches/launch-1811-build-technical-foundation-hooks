# Automatic-binding evidence

Source changes and local checks continuing `9dd97150d292fee26912f9605e0686e4ddbb1645`.
Nothing here is a live Hooks Store approval or deployment. No paid request or public transaction
was submitted. [Runbook](../../AUTOMATIC_BINDING.md), [machine-readable results](summary.json),
[public-source provenance](provenance.json).

## Final local checks

| Check | Result / evidence |
|---|---|
| `forge build --sizes`, solc 0.8.26 | Passed; [sizes/build log](build-sizes.log) |
| `forge fmt --check` | Passed; [format log](fmt-check.log) |
| Full `forge test`, repository seed | 572 passed; [log](foundry.log) |
| Full `forge test`, assignment seed `0x63141e…f3de` | 572 passed; [log](foundry-assignment-seed.log) |
| Cold isolated callback suites, old and automatic | 15 passed; [gas log](gas.log) |
| Python SDK, deployment preparation and Anvil integration | 61 passed; [log](sdk.log) |
| Node/browser ABI, encoder and display checks | 27 passed; [log](site.log) |
| Vendored dependency checks | 96 files unchanged, 24 pre-existing formatting-only differences; [log](vendored.log) |
| Public vector reproduction, offline | Four question preimages/signatures match; [JSON](vector-reproduction.json), [Foundry log](live-vectors.log) |

Run all local suites without network using `bash script/check_automatic.sh` from the repository
root. The protected Foundry configuration and dependencies were not edited. Current source/build
pins and published ABIs are refreshed by `script/update_build_evidence.py`; the historical audited
snapshot remains unchanged. Regenerating current pins is an explicit authoring operation, never a
substitute for review.

## Gas and sizes

The automatic oracle callback's minimum **forwarded** gas, with cold consumer, codec, prefix and
signer, was 126,868 for EOA, 171,967 for the real five-of-seven ERC-1271 test signer, and 189,141
for the 22-cold-policy-read ERC-1271 signer. Binary searches restore state and re-cool on every
trial. The mock Intake independently forwards exactly 200,000 gas once. Job success (including
64 KiB URI omission), job failure and oracle failure also complete under that stipend. A deliberately
over-budget legacy signer still fails closed; no claim is made for arbitrary expensive registries.

| Runtime | Bytes |
|---|---:|
| AutoHookJobRequester | 24,303 |
| HookRequestCodec | 13,409 |
| GatedHookDeployer | 20,967 |
| Legacy HookJobRequester, unchanged | 24,559 |
| Example immutable prefix pin, including STOP | 2,714 |

Every production runtime is <= 24,576 bytes. The test suite also enforces these bounds. Compiler
runtime templates with immutables have different final live hashes after constructor substitution;
no addresses or runtime hashes in these fixtures are production deployments.

Actual disposable Anvil transaction gas with MockIntake was 46,152 for approve, 3,347,035 for
openJob, 481,707 for commitArtifact, 3,178,505 for requestVerdict and 1,088,372 for deployment.
These are local costs. MockIntake stores full bodies, whereas live Intake emits them. Estimate
actual wallet transactions; these numbers are not universal gas limits or live gas-price quotes.
The Python test completes the real automatic requester using a local Anvil v2 typed signature,
reads its stored candidate and prepares/deploys that exact hook through the official gate. The
Foundry success path additionally initializes a real v4 PoolManager and executes a genuine swap.

## Genuine public protocol vectors

The public records and signatures are saved as `<uuid>.json` and `<uuid>-attestation.json`.
The upstream generator snapshots are under [reference](reference). Prefixes emitted by that
pinned utility and its public `--verify` MATCH logs are saved alongside them.

| Public request | Evidence / type | Signed questionHash |
|---|---|---|
| `76587543-d7e6-471e-a01f-63e9e0dfc6e7` | chain / uint256 | `0xf4df38bb41d635b3de83f4215612d83e25696f6a40fc040f9de053baba7029df` |
| `a03ae889-4a5d-4300-982a-e4bcf59ecf98` | panel / bool | `0xd3e1daa022412fedbe7b49cb7f2179847fc1d15159ad8c5e7a65ff4835cc8a4b` |
| `43a20eb4-f9ce-4751-8a62-9c8851b12565` | panel / bool | `0x01647b9a756632a15dcd092560b07f9383e1b6b124718c95d7da74eb2bd9b13f` |
| `c65fecb5-2a13-4365-b6de-89f7a2c46bb2` | panel / uint256, definitions | `0x2696c91a75998915c9ee1e31f8a6999c9b9ee68f9ecaed220d7470dadf8ba8af` |

The tests recompute the canonical preimages using signed window bounds, deploy the actual consumer
runtime at each public domain address on chain 1 inside the local EVM, compute its v2 digest, and
recover the existing public oracle signer from each captured signature. They do not present these
unrelated, historical answers as a current hook approval. They establish serialization and signature
conformance, not the truth of a Hooks Store review or the unsigned HTTP Intake-to-UUID mapping.

`script/check_automatic_vectors.py` also independently canonicalizes the current contract-emitted
body, compares its pinned prefix byte-for-byte, checks limits/full worker context, and checks the
codec runtime hash against the consumer's compiled-code pin. `--generate` regenerates the committed
Foundry vector fixture from the saved public records; run forge fmt afterward.

## Free preflights and actual local bodies

[job.open.body.json](job.open.body.json) and [oracle.request.body.json](oracle.request.body.json)
are exact compact bytes emitted by the real contracts in the local fixture, without a trailing
newline. [bodies.log](bodies.log) records their origin. [question-prefix.txt](question-prefix.txt)
and [current-payload.json](current-payload.json) reproduce that same local question; their identity
values are generated by tests, never proposed launch addresses.

The public free job body checker returned no blockers for the actual assembled job body:
[job.open.check.json](job.open.check.json). The oracle free drafting checker accepts a subset,
not the complete body with definitions/window/consumer. The final
[supported-chain wording example](supported-chain.wording-example.json) changes only the local
chain fields/text to supported chain 1 and uses fixture identities. Its
[free response](supported-chain.wording.check.json) has **no blockers** and retains a
`not_answerable` suggestion for non-live fixture records. This is a wording check, not admission
of the full body. A chain-31337 free call was refused for lack of a public RPC; local unit success
is not public-chain service support. [Captured capabilities](capabilities.json) record current
public action IDs, chain support and panel bounds.

No live build, accepted review, full oracle body admission, Hooks Store callback, signed hook
verdict or deployment was purchased or demonstrated. The operational pilot and independent
adversarial review remain separate responsibilities. The delivered contracts implement automatic
binding now; those limitations are not replaced with a manual per-hook owner allowlist.
