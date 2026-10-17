# Deployment-preparation command evidence

Starting commit: `b157921170c318f8eeee638b06025a81cf768c02` (the clean initial `git rev-parse HEAD`).
This work prepares deployment artifacts and fixes readers/tooling. It changes no audited source,
existing Solidity script, compiler setting or dependency. These logs are local results and
public read observations, not an independent audit or a claim of paid end-to-end service.

## Local commands and actual logs

All commands ran from repository root. The compiler is the existing pinned Solidity 0.8.26,
Cancun, optimizer 200, no CBOR or metadata bytecode hash. No compiler override was used.

| Actual command | Result | Output |
|---|---|---|
| `forge build` before source changes | Pass, pinned 0.8.26; baseline artifacts captured | [baseline-build.log](baseline-build.log) |
| `forge build` after changes | Pass; existing advisory lints | [build.log](build.log) |
| `forge test` | **253 passed**, 28 suites, zero failures/skips; repository-pinned seed | [forge-test.log](forge-test.log) |
| `forge test --fuzz-seed 0x987078825760321852440813e64598edbfcd99df874323a1a45a55bcb5c3e545` | **253 passed**, 28 suites, zero failures/skips | [assignment-seed.log](assignment-seed.log) |
| `forge fmt --check` | Pass | [fmt.log](fmt.log) |
| `forge test --isolate --match-contract 'UriPilotGasTest\|JobProtocolGasTest\|ReviewReceiptGasTest' -vv` | **10 passed**; cold callback measurements, fee loss and runtime bound | [cold-gas.log](cold-gas.log) |
| `node --test test/requester-abi.test.cjs test/listings-reader.test.cjs` | **20 passed**, zero failures/skips | [site-abi.log](site-abi.log) |
| `python3 -m unittest discover -s test -p 'test_*.py' -v` | **30 passed**, stdlib + disposable local Anvil | [python-tests.log](python-tests.log) |
| `python3 script/dry_run_deployment.py --output-directory docs/checks/deployment-preparation` | Pass; local constructor/calldata/readback rehearsal and existing script simulations | [local-dry-run.log](local-dry-run.log), [script argv/output](local-script-dry-runs.log) |
| `python3 script/prepare_deployment.py verify-build` | All source/config fingerprints and all five creation/runtime-template bytecodes **unchanged** | [bytecode-unchanged.json](bytecode-unchanged.json) |

`foundry.toml` still pins seed
`0x936d89b088020ddf36122a88c4c9aed7130c7a410f5c44680a7d121950c99345`.
The supplied assignment seed was exercised explicitly in addition to that seed. Both ad escrow
invariants passed, including their 128,000-call sequences. The new Foundry test reproduces the
URI boundary with the mock's exact 200k one-shot delivery. Existing receipt/signature/conformance,
listing, payment and escrow coverage remains intact.

The final Python run includes delayed/non-automining receipt success, bounded timeout, mined
revert and malformed response failures; constructor dependency ordering; owner and beneficiary
approval gates; price/chain/code rejection; exact immutable bytecode verification and corruption
rejection; free-check blockers and input/approval binding; unsigned setter execution/readback;
idempotence; both read-only transports; and the existing CREATE2 SDK integration tests. Each
Anvil instance uses a fresh loopback port. No tests require public network access or credentials.
An additional transport regression exposed proxy routing of loopback curl requests; the tool now
explicitly bypasses proxies for loopback, and the final 30-test run passes without environment
changes. Earlier focused runs are retained in [sdk.log](sdk.log) and
[deployment-tests.log](deployment-tests.log); the final combined log above is authoritative for
this worktree's local results.

### Local artifacts, never operational addresses or approvals

- [local-dry-run.json](local-dry-run.json) contains the actual unsigned creation calldata for all
  four contracts, local receipts, two ads owner calls, exact state readbacks and zero-repeat-call
  result. The factory and requester scripts were simulated without `--broadcast` and without
  advancing the local chain. The explicit owner differs from the creation sender.
- [local-requester-activation.json](local-requester-activation.json) contains **local mock** free
  checker/approval fixtures, timeout/job-template/review-template calldata and executed readbacks.
  It proves encoding and owner behavior; it does not qualify those bodies for live IMD use.
- [local-script-dry-runs.log](local-script-dry-runs.log) records the exact argv and output for
  `DeployStore.run`, `DeployHookJobRequester.run` and `runConfigure`. None broadcast even to Anvil;
  the separate fixture transactions are what deployed/configured the local application contracts.
- Only local mock protocol contracts are created for this rehearsal. No project token, manager or
  pool is created by it. Existing Foundry/SDK tests retain their own local tokens/pool fixtures.

The baseline in [audited-build.json](../../../deployment/audited-build.json) was captured before
any Solidity test addition. It pins all existing `src/**/*.sol`, `script/*.sol`, compiler config,
remappings and dependency manifest, plus these creation/runtime-template lengths:

| Contract | Creation bytes | Runtime template bytes |
|---|---:|---:|
| HookListingRegistry | 9,063 | 9,035 |
| FeaturedPlacements | 8,606 | 8,232 |
| HookJobRequester | 25,861 | 24,117 |
| HooksStoreFactory | 14,097 | 13,970 |
| BoundedSwapHook | 4,930 | 3,431 |

Requester headroom is 459 bytes below EIP-170. Deployed ads/requester runtime differs from the
artifact only at the constructor-filled immutables. The tool reconstructs **all** of them and
compares the entire live runtime; it never treats masked immutable bytes as verified.

## Live evidence: public HTTP and read-only RPC, no transactions

`python3 script/recheck_official.py --output-directory docs/checks/deployment-preparation`
ran on 2026-10-17. [official-recheck.log](official-recheck.log) summarizes the results;
[official-observations.json](official-observations.json) records timestamps, exact URLs, fetched
content hashes, protocol anchors and excerpts from the actual No token launch-page JavaScript.
The latter evidence confirms UI selection, not execution of a public launch. The
[launcher recipe response](launcher-recipe.json) and [capabilities response](capabilities.json)
are first-party observations. The recipe/documents explicitly rule out post-deployment calls;
they do not grant this worker transaction authority.

[live-rpc.json](live-rpc.json) preserves exact JSON-RPC requests/responses, endpoints, block
numbers, token code/decimals/symbol, signer code and `priceOf` results. All methods are reads.
It confirms 0.5 IMD for job and oracle on 1/4663, and zero job price / 0.5 TestIMD oracle price on
Sepolia at the recorded blocks. Sepolia is missing from the captured Intake capability list,
while the docs describe its oracle service; service eligibility remains unproved. The docs now
describe 1,000,000 callback gas on Sepolia, distinct from the production 200k tests.

The preparation CLI also ran independently against each public chain; exact commands and exit
codes are in [preflight-commands.json](preflight-commands.json). Results are
[sepolia-preflight.json](sepolia-preflight.json), [ethereum-preflight.json](ethereum-preflight.json)
and [robinhood-preflight.json](robinhood-preflight.json). They check current code against the
captured hashes and still report `paidPilotReady=false`. Raw HTTP/RPC evidence does not prove
transfer behavior, writer liveness, authenticated UUID mapping, oracle signature gas, safe
factory deployment or end-to-end paid operation.

No public deployment, wallet signature, paid Intake request, token/pool creation, live template
acceptance, source verification on explorers, Slither/Mythril run, atomic ProjectFactory launch
simulation or independent new audit is claimed. Remaining owner, recipient, pilot and launcher
handoff inputs are listed in the [operator runbook](../../DEPLOYMENT_PREPARATION.md).
