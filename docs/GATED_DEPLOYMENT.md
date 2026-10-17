# Oracle-gated deployment of generated hooks

`src/deployment/GatedHookDeployer.sol` is the official Store deployment route for **generated**
hooks (any job-produced Uniswap v4 hook, BoundedSwapHook included). The approval is enforced
in the contract. The website and the SDK only prepare calldata. This is local code and local
tests. Nothing has been deployed, no paid request was made, nothing was signed, and this is
**not an audit or a claim of live readiness**.

## Flow

1. **Build/test/adversarial review job.** The creator calls `HookJobRequester.openJob` (unchanged).
   The job template must tell the worker to put this into the result document:
   `"hooksStoreArtifact":"0x<artifactDigest>"`, where the digest covers the exact artifact they built.
2. **Delivery.** The Intake calls `onJobResult(requestId, resultHash, uri)`. `resultHash` is the
   keccak256 of the result document's bytes. This is a delivery, not an approval.
3. **Separate oracle confirmation.** The creator calls `requestReview` (unchanged). Both orders
   still work: the owner binds first and then the signed callback arrives, or the signed callback
   arrives first, is kept as a receipt, and the owner's `bindReview` finalizes it. Only a signed
   `true` from the oracle sets `ReviewStatus.Passed`.
4. **Unsigned calldata.** `python3 -m sdk.gated_deploy ...` reads the job, checks the result
   document's hash and its artifact line, and mines a salt for the permission mask with
   `mine` (`eth_call`). It then runs the contract's complete `check(...)` gate as an `eth_call`
   and prints an unsigned `deploy(...)` transaction from the job requester, plus an evidence list.
5. **Deployment.** The job requester signs and sends the transaction with their own wallet.
   `deploy` runs every check again. It consumes the approval before CREATE2, deploys, then reads
   back the runtime code hash, `poolManager()` and `getHookPermissions()`.

## What the artifact digest binds

`artifactDigest = keccak256(abi.encode(ARTIFACT_TYPEHASH, Artifact))`, where the `Artifact`
fields are:

| Field | Meaning |
|---|---|
| `jobRequestId` | the Intake job id. Its stored `resultHash` must hash the supplied result document |
| `sourceHash`, `buildHash` | the source bundle and build identity (compiler, settings) the reviewers checked |
| `creationCodeHash` | keccak256 of the creation code |
| `constructorArgsHash` | keccak256 of the ABI-encoded constructor arguments |
| `runtimeCodeHash` | the expected deployed code hash. This catches constructors whose output depends on the environment |
| `chainId`, `deployer` | must be `block.chainid` and this deployer |
| `poolManager`, `poolManagerCodeHash` | must be enabled here and match the live code hash |
| `permissions` | the 14-bit callback mask. The CREATE2 address and the readback must both match it |

The salt is not part of the digest. Any mined salt is accepted if the address carries exactly
`permissions` and has no code. Each job deploys at most once (`deployedHookOf`), and each digest
deploys at most once (`usedArtifact`).

## Rejections (each one is tested in `test/GatedHookDeployer.t.sol`)

- No review, a pending review, an unbound early receipt, `NotPassed`, `Unanswered` or a forged
  signature: `ReviewNotPassed`.
- A job that was not delivered: `JobNotDelivered`. A caller who is not the job requester: `NotJobRequester`.
- A changed result document: `ResultHashMismatch`. A changed source, build, mask, or another job's
  approval: `ArtifactNotInResult`. Swapped creation code or constructor arguments:
  `CreationCodeMismatch` / `ConstructorArgsMismatch`.
- The wrong chain, deployer or manager, a disabled manager, or a manager code-hash mismatch: rejected.
  An unsupported chain is rejected outright.
- An invalid mask (zero, outside the 14 bits, or a return-delta bit without its base callback),
  an unmined salt, a wrong expected address, or an occupied address (collision): rejected.
- Replay of the same job (even with a new salt) or the same digest: rejected. A job opened more
  than `maxJobAge` ago (default 30 days, owner-set within 1–180 days): `ApprovalStale`.
- A retained verdict whose receipt or signer epoch was revoked on the requester: `ReviewRevoked`.
- Malicious constructors. A reverting one leaves the approval unused. Empty runtime, a lying
  `poolManager()` or `getHookPermissions()`, or runtime that depends on the environment: the whole
  call reverts. A constructor that reenters `deploy` is blocked by the reentrancy lock.

`deploy` is the only gated entry point. `check`, `mine`, `predict` and `verifyDeployment` are views.

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

## Trust assumptions (changed and unchanged)

- **New: the result-document marker.** The oracle verdict is about the job's review. The artifact
  is bound because the reviewed result document (committed by `resultHash`) names its digest.
  The deployer does not re-derive the digest from source. The panel and reviewers must check
  that the digest named in the result is the artifact they reviewed, so the review template
  should ask exactly that.
- **Unchanged: the requester owner.** They bind the Intake-to-oracle mapping (`bindReview`), set
  the oracle signer, and can revoke receipts and epochs. `bindReview` is owner-only and is not
  automatic. **Blocker for full automation:** the Intake id → oracle UUID/canonical question
  mapping has no authenticated onchain or signed source today, so a person or process holding
  the requester's owner key must check it offchain and call `bindReview`. This tool does not
  fake that step. Founder approval of the hook itself is not required: the owner binds the
  question context, and the verdict comes from the oracle.
- **Oracle signer.** It is one hot key that the panel's answer depends on (see IMD_INTEGRATION.md).
  Revocation is checked only for verdicts kept as early receipts, because a verdict finalized
  bind-first stores no signer epoch.
- **Deployer owner.** They can enable or disable managers within the pin policy and set
  `maxJobAge`. They cannot change the requester (immutable), approve a hook, or bypass any check.
  An owner allowlist is not an oracle proof, and none is treated as one.
- **No contract change to HookJobRequester.** Its runtime size is 24,117 bytes, 459 bytes under
  the EIP-170 limit, which leaves no room for a new artifact-review function. Artifact binding
  therefore goes through the result document, which needs no requester change. All requester
  protections (one-shot callback, receipts, replay, expiry, revocation) are reused unchanged.

## Legacy route

`HooksStoreFactory` stays as it was: an **ungated**, testnet/local-only, BoundedSwapHook-only
route that is useful for template tests. Its deployments are not Store-approved and do not appear
in `GatedHookDeployer.deployedHookOf`.

## Deployment parameters / After launch

- Constructor: `(owner_, requester_)`. `owner_` is the launch owner (`$owner`). `requester_` is the
  deployed `HookJobRequester` on the same chain.
- `setManager(manager, codeHash, true)`: on pinned chains, the pair from the table above. Before
  calling it, recheck with `script/recheck_gated_managers.sh`.
- `setMaxJobAge(seconds)` (optional, default 30 days).
- The requester owner updates the job template so the worker emits the `hooksStoreArtifact`
  line, and the review template so the question asks whether the review covered that digest.
  Run each new question through the IMD `/requests/check` before setting it.

## Remaining live-pilot gates

1. The live job worker emits the marker line with a digest it computed correctly.
2. A real paid review on a pilot chain, with an authenticated `bindReview`.
3. A Sepolia deployment of the deployer and requester, plus a gated deploy against the pinned manager.
4. A per-chain gas check (local measurement: `deploy` 375k gas on average and 1.1M at most,
   excluding the hook's own constructor size. Mining is an `eth_call` and runs up to 32M gas per
   131,072-candidate page).
5. An independent adversarial review of `GatedHookDeployer` before any value relies on it.

## Local evidence

```
forge build && forge test                                  # 297 tests, includes 44 in GatedHookDeployer.t.sol
python3 -m unittest discover -s test -p 'test_*.py'        # 35 tests, includes test_gated_deploy.py on Anvil
node test/requester-abi.test.cjs && node test/listings-reader.test.cjs
script/recheck_gated_managers.sh                           # read-only, needs network
```

Sizes: GatedHookDeployer has a 10,342-byte runtime (limit 24,576). HookJobRequester is unchanged at 24,117.
The ABI is in `site/GatedHookDeployer.abi.json`.
