# Hooks Store foundation

Current revision: fixes for audit `dde20fdc`, continuing `e69e04f63832b9fa1e84c7d58c685ce37924a490`. Automatic requester caps are live per token, so rotations preserve legacy reserve units. The SDK and UI use the original reserve token's cap; the UI binds wallet and form context through receipts and readbacks. Fees, roles, pausing, confirmed windows and exact-artifact authorization are preserved. The [automatic workflow and runbook](docs/AUTOMATIC_BINDING.md) covers assumptions, deployment parameters and operator responsibilities. [RED/GREEN regressions and checks](docs/checks/audit-dde20fdc/README.md) are local evidence. No deployment or public payment was performed.

Deployment preparation from `b157921` is in the [executable runbook](docs/DEPLOYMENT_PREPARATION.md) and
[manifest](deployment/manifest.json). Owner and ad-recipient approvals remain open; no public deployment
or paid request is authorized. That runbook is historical; this revision changes requester and
gated-deployer Solidity while preserving compiler settings and dependencies.

A versioned HookSpec, one standalone Uniswap v4 hook, and a shared CREATE2 deployment path for chat and visual creators. The implementation is locally tested. No public-chain transaction was submitted, and no hosted Store, chat creation service, visual builder or production deployment is claimed.

The Store now also has a [free onchain listing registry and refundable featured ads](docs/LISTINGS_AND_ADS.md).
Listings record chain/address, owner, evidence references, callback/fee/admin disclosures and searchable
labels. References remain unverified: supplying an audit URL never grants an audited badge. Optional
**#ad** placements cost **0.1 IMD for seven days**, ordered by purchase ID, with pro-rata cancellation
refunds and depositor-only withdrawal of unused deposits. After a listing transfer, the buyer can
cancel the seller's ad; its refund still belongs to the seller. The [static reader](site/listings.html) displays
the purchased revision and the ad disclosure. No hosted deployment is claimed.

`BoundedSwapHook` serves any number of **new static-fee pools on one PoolManager**. It rejects swaps whose requested `amountSpecified` is zero or outside an immutable raw-unit limit, then counts successful swap callbacks separately by PoolId. It neither holds swap funds nor changes fees or accounting deltas. Anyone may use it when initializing a new pool. A pool's hook is part of its PoolKey; this does not retrofit hooks onto existing pools.

**Decision (audit follow-up): the limit caps only `amountSpecified`, never both sides.** It applies to the input of an exact-input swap and the output of an exact-output swap. The unspecified side is not capped: the input of an exact-output swap and the output of an exact-input swap can exceed the limit. `testLimitCapsOnlySpecifiedSideNotUnspecifiedSide` shows an exact-output swap of exactly the limit paying more than the limit in input. Reasons:
- The field is `maxSpecifiedAmount` in HookSpec v1.
- One raw-unit ceiling applied to two currencies with different decimals would make one side meaningless.
- Changing it would change the template's bytecode and break existing plans.
- A user who needs an input bound uses the router's slippage limit (`amountInMaximum`).

The limit applies to input for exact-input swaps and output for exact-output swaps. It is **not** a dollar-value limit, an input cap for exact-output swaps, a cumulative limit, an oracle, a slippage control or MEV protection. A user can split trades. All pools share the same raw-unit ceiling, so creators must consider each currency's decimals. See [threat model](docs/THREAT_MODEL.md).

## Build and check

Requirements: Foundry (`forge`, `cast`, `anvil`), solc **0.8.26**, and Python 3.10+ for the optional Store adapter tests. Solidity dependencies are ordinary vendored files under `lib/`, with commits and selection recorded in [dependencies.lock.json](dependencies.lock.json). No npm packages, submodules, FFI or Foundry filesystem permissions are needed. Once the pinned compiler and Foundry are installed, all checks run without internet access.

```sh
forge build
forge test
forge test --gas-report
forge fmt --check
sh script/verify-vendored.sh
python3 -m unittest discover -s test -p 'test_*.py' -v
# Optional static listing reader checks (Node.js built-ins only):
node --test test/*.test.cjs
```

The repository fuzz seed is pinned in `foundry.toml`:
`0x936d89b088020ddf36122a88c4c9aed7130c7a410f5c44680a7d121950c99345`.
This audit-fix revision also runs the assignment seed
`0x496abaac78906e29834a9e8c6092ebc83fe50f2785c67161be04f9cee38e1ef2`.
[Current results](docs/checks/audit-7db42bb7/README.md) include the complete Foundry, Python SDK and
Node site suites. Tests do not read or mutate environment variables. Python integration tests start
and stop disposable Anvil instances on loopback; they never use a public RPC or a funded wallet.

The listings/ads follow-up also checks the supplied seed directly using
`forge test --fuzz-seed 0x897ccfb85f71eb00ada949c5387d8bc41b650fda2a7d704b3960c7edf39b4654`.
The protected Foundry configuration and its existing seed are unchanged. New tests include hostile
token behavior and stateful conservation/withdrawal checks alongside the original suite.

The Foundry suite mines and deploys real CREATE2 hooks, creates a fresh real v4 PoolManager, and initializes two distinct new pools using the same hook. It exercises swaps, limits, both exact modes and directions, per-pool isolation, liquidity withdrawal, failed settlement rollback, permissions, malformed specs and deployment verification. Test tokens and the settlement router exist only in `test/`. Neither deployment script creates tokens, managers or pools.

## Entry points

| Deliverable | Entry point |
|---|---|
| Automatic job/oracle consumer | [AutoHookJobRequester.sol](src/imd/automatic/AutoHookJobRequester.sol), [fixed codec](src/imd/automatic/HookRequestCodec.sol) |
| Automatic wallet/SDK workflow | [wallet page](site/automatic.html), [unsigned SDK](sdk/automatic.py), [preflight](script/preflight_automatic.py) |
| Automatic deployment configuration draft | [constructor/owner handoff](deployment/automatic.draft.json), [runbook](docs/AUTOMATIC_BINDING.md) |
| Shared creator output | [JSON schema](schemas/hook-spec.v1.schema.json), [ABI struct](src/HookSpec.sol), [spec contract](docs/HOOK_SPEC.md) |
| Reusable hook | [BoundedSwapHook.sol](src/BoundedSwapHook.sol) |
| Store-callable contract interface | [IHooksStore.sol](src/interfaces/IHooksStore.sol) |
| Shared factory and verification | [HooksStoreFactory.sol](src/HooksStoreFactory.sol) |
| Mining and script integration | [HookMiner.sol](src/deployment/HookMiner.sol), [HookDeployment.sol](src/deployment/HookDeployment.sol) |
| Configurable scripts | [DeployStore.s.sol](script/DeployStore.s.sol), [DeployHook.s.sol](script/DeployHook.s.sol) |
| Read-only Store client and unsigned transaction builder | [hooks_store.py](sdk/hooks_store.py) |
| Integration instructions | [Store API](docs/STORE_API.md), [deployment operations](docs/DEPLOYMENT.md) |
| IMD job requests and review status | [HookJobRequester.sol](src/imd/HookJobRequester.sol), [deploy script](script/DeployHookJobRequester.s.sol), [integration guide](docs/IMD_INTEGRATION.md), [static status page](site/index.html) |
| Free listing registry | [HookListingRegistry.sol](src/store/HookListingRegistry.sol), [listing and ad API/operations](docs/LISTINGS_AND_ADS.md) |
| Optional featured #ad escrow | [FeaturedPlacements.sol](src/store/FeaturedPlacements.sol), [read-only listing page](site/listings.html) |
| Evidence and limits | [verification](docs/VERIFICATION.md), [chain support](docs/CHAINS.md), [threat model](docs/THREAT_MODEL.md) |

For the legacy template factory, both creator frontends emit the same structured spec. They call `normalize_spec` / `build_spec`, then `StoreClient.plan`; they do not generate arbitrary Solidity or supply arbitrary bytecode. The Store gets a reviewable unsigned transaction. A separately controlled wallet can submit it to an allowed test network, after which a fresh client calls `verify`. Other clients can call the same ABI directly; the automatic workflow requires no backend.

## Legacy template factory configuration

Production protocol address candidates, first-party sources and read-only observations are now recorded in the
[preparation manifest](deployment/manifest.json); no public application deployment address or owner is invented.
An operator must supply the actual chain ID, a reviewed PoolManager address and its runtime code hash, the deployed Store factory address, RPC endpoint and an explicit broadcaster for scripts. The creator supplies the positive raw-unit swap ceiling. Missing or inconsistent settings fail validation. This repository was not supplied a network address manifest and does not copy unchecked addresses from reference tables.

There is no hook owner, proxy, upgrade key, pause key, fee recipient or mutable setting. The factory is permissionless and can deploy only the pinned template. The constructor's settings are write-once storage, with no setters; this makes the entire runtime bytecode independently comparable before and after deployment. A different setting requires a new deployment and new pools.

The deployment policy permits local chain `31337`, Ethereum Sepolia `11155111`, Base Sepolia `84532`, and Robinhood Chain Testnet `46630`. Only local execution has been tested. This **release** of the Store tooling explicitly rejects Ethereum, Base and Robinhood mainnets in the factory constructor, `deploy`, both scripts, the shared integration and the SDK.

The restriction is a property of this factory build (`DeploymentPolicy`), not of the hook template. The hook constructor only binds `spec.chainId` to the actual chain, so the public hook bytecode can be deployed directly on any chain. Such a deployment is not a Store deployment: this factory's registry and `verify` do not recognise it. Future mainnet support needs a separately reviewed factory release with an updated policy list. It does not need a new hook template, bytecode or HookSpec version, so the restriction does not permanently block mainnet. Full chain-specific status is in [CHAINS.md](docs/CHAINS.md).

## After launch

The automatic consumer/deployer settings and constructor inputs are in [AUTOMATIC_BINDING.md](docs/AUTOMATIC_BINDING.md#after-launch--operational-responsibilities) and [automatic.draft.json](deployment/automatic.draft.json). The listing/ad settings below remain unchanged.

For the new advertising contract, the explicit launch owner calls `configureToken(token)` once with
the verified, 18-decimal IMD address for the settlement chain and `setProceedsRecipient(recipient)`
with the requester-approved treasury address. Neither address is guessed or defaulted; deposits
require the token and purchases require both settings. **Proposed recipient: `0x3f252e859a277a86A3967c11D4E054B2f07a1F22`, pending final requester approval before live use.**
This is not the Intake payee; its ownership/control model has not been verified.
Recipient changes affect future purchases only. There is no admin sweep, upgrade, pause, pricing
control or access to users' credit. Full [settings, admin powers and responsibilities](docs/LISTINGS_AND_ADS.md#after-launch)
are documented separately from the existing Intake integration. The registry has no global admin.

The hook template and factory have **no after-launch setters**. `HookJobRequester` does; they are listed under "After launch" in [IMD_INTEGRATION.md](docs/IMD_INTEGRATION.md). Until `setJobTemplate` and `setReviewTemplate` are called, its request functions revert `NotConfigured`. Before a test deployment, the operator must verify the PoolManager identity and code, review the limit, and preserve the exact build and plan. After deployment, independently verify the transaction receipt, CREATE2 address, runtime code, callback bits and constructor settings; publish the source and constructor arguments. Pool selection, initialization price, liquidity, routing, approvals and user slippage limits belong to separate pool operators and applications, outside deployment.

The Store operator owns wallet integration, RPC security, confirmation/reorg handling, monitoring, indexing and evidence retention. An IMD request-checker response, a mined salt, successful simulation or HTTP 200 response is not evidence of a hosted deployment. Independent adversarial review remains necessary before use with real funds.

Project-authored code is MIT-licensed. Vendored files retain their original licenses, including Uniswap v4's file-specific MIT/BUSL-1.1 terms; see [dependency provenance](docs/DEPENDENCIES.md).

## Legacy manual IMD request integration

`HookJobRequester` buys an IdentityMD `job.open` for standalone-hook code and a separate signed
oracle review. Paid calls are now `openJob(specHash, brief, userMaxPrice)` and
`requestReview(jobId, userMaxPrice)`; there are no uncapped overloads. Each quote must fit both the
caller's submitted limit and the owner's ceiling. Exact incoming transfers and exact Intake spending
are checked atomically: partial spending reverts the request, leaving no caller funds to sweep.
The full [site ABI](site/HookJobRequester.abi.json) is checked against compiler output.
Job delivery now uses the protocol tuple `onJobResult(bytes32,bytes32,string)`: the supplied
result-document hash is stored exactly, and the URI is emitted as `JobResultURI` without string
storage. The status page shows the URI as unverified text in event history, with no link or fetch.
Delivery remains separate from signed review approval. [RED/GREEN traces and check results](docs/checks/job-protocol-tuple/README.md)
cover the regression, malicious/malformed inputs, late completion, callback gas and runtime size.

Local job expiry still accepts the first late Intake result/failure. Delivered, failed and expired
jobs are equally reviewable; unsigned callback ordering cannot dictate a signed verdict. A review
requires an exact owner-asserted Intake-to-oracle UUID and canonical question/window binding.
The current protocol does not authenticate that association for the contract.
Valid answers arriving before binding **or against a wrong pre-binding** are retained without a
verdict or UUID consumption. The owner can explicitly reset a pending binding and confirm the
retained answer without another callback. A positive answer confirmed after 23 hours instead requires
a fresh review and fee; negative answers stay terminal. Swapped answers cannot settle under correct bindings.

Requester review expiry only requests closure; delivery stays open and retries stay blocked.
After the deadline the owner can close an ask without a receipt, including an abandoned ask whose
requester never requested expiry, after authenticating that no valid delivery remains in flight.
For signer compromise, rotate to safe authority, explicitly revoke the old signer epoch, and close
affected retained receipts as `Unanswered`. Ordinary rotation preserves verification; explicit epoch
revocation blocks confirmation and deployment. Receipt history and consumed UUIDs remain intact;
`closeRevokedVerdict(jobId)` permits a fresh review after the current finalized verdict's actual epoch
is revoked. Ordinary negative verdicts cannot be reset. These are logged owner powers requiring
independent offchain evidence.

A retained answer carrying the ask's own UUID but another signed question, chain or window can now
be set aside by the owner alone, explicitly and logged, naming the exact receipt and its verdict; a
receipt matching the ask's true context can only be bound, so a genuine `NotPassed` cannot be
discarded this way and a requester cannot discard anything. The panel check compares the signed
panel size and actual agreement with the configured minimums and the oracle's own signed quorum; a
body quorum below the configured minimum no longer burns an agreed answer. Job templates must carry
each step marker whole inside one fragment, which is exactly what every assembled body contains.

Cold one-shot callback tests fit 200k gas, including wrong-prebinding retention: **175,101 gas** with
a realistic 5-of-7 ERC-1271 signer and **192,264** with the 22-cold-read stress signer. Arbitrary live
registries still require qualification. The static status page shows receipt revocation and recovery
history; `Passed` is a signed panel opinion about the review step, never an audited-hook badge.

The full local suite includes listing/ad escrow, refunds, transfers and conservation invariants.
See [audit 648ba2e5 remediation](docs/AUDIT_648BA2E5.md), [audit 6b607200 remediation](docs/AUDIT_6B607200.md)
and the [integration guide](docs/IMD_INTEGRATION.md) for deployment parameters and operator duties.
A synchronous Intake refusal rolls the whole ask back without debit; an asynchronous one spends the
fee. Which shape the live Intake uses is something only a live pilot can prove.
Real IMD Intake testing remains necessary for the job action/body, live delivery of the documented tuple, exact spending,
authenticated post-delivery mapping and canonicalization, and production signer gas under 200k.
No deployment, paid request or fund movement was performed.

## Salt mining under eth_call gas caps

A full 131,072-candidate page costs about 46M gas, more than common RPC `eth_call` caps. `HookMiner.mine` now stops early when gas runs low and returns `found = false` with `nextNonce` at the first unchecked nonce. Callers resume there and no candidate is skipped. A call with too little gas for even one candidate reverts `InsufficientGas`. Tests walk the whole search under a 10M-gas cap and get the same salt as an uncapped search.

## Oracle-gated generated-hook deployment

`AutoHookJobRequester` prepays the build and verdict reserve, exposes the full spec/context, and
accepts one creator-selected ArtifactV2 plus reviewed commit. Anyone can trigger its fixed
`requestVerdict(askId)` after both candidate and job delivery are confirmed. It reconstructs the
canonical question hash from immutable prefix bytes and signed window bounds, verifies the v2
attestation, and records an exact artifact approval without a per-hook owner binding call.

The official `GatedHookDeployer` verifies that exact digest, unrevoked signer epoch, freshness,
chain/deployer/manager, bytecode, constructor, runtime and permission bits, with deployment replay
guards. The automatic path uses no result JSON parsing. Legacy requesters retain their exact
accepted-file parser and explicit `--binding-mode owner-confirmed` compatibility route.

`python3 -m sdk.gated_deploy --rpc ... --deployer ... --job ... --creation-code ...
--constructor-args ...` reads the stored candidate, checks the gate and prints unsigned calldata.
Use the [automatic wallet page](site/automatic.html) and [operational runbook](docs/AUTOMATIC_BINDING.md).
`HooksStoreFactory` remains a legacy ungated testnet-only template route. All work is source and
local tests; no live deployment or paid request occurred.
