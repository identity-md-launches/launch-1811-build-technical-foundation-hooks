# Threat model

The listing registry and ad escrow have their own
[custody model, assumptions and complete admin-powers account](LISTINGS_AND_ADS.md).
Listing text is untrusted, paid placement is never audit evidence, and ads retain their purchased
metadata revision. The escrow isolates unused deposits, refundable fees and earned proceeds;
recipient rotation cannot take prior funds. New hostile-token and stateful conservation tests
cover the escrow specifically. The earlier hook/Intake review below remains scoped to those components.

## Assets, boundaries and assumptions

The hook is noncustodial: the v4 PoolManager and external periphery handle balances and settlement. Assets at risk are pool participants' ability to trade, accurate callback attribution and the integrity of Store deployment plans. Pool funds remain subject to v4, token and router risks. A defective hook can disrupt swaps even without holding funds.

The reviewed factory/build and a correctly identified, compatible, non-substituted PoolManager are trusted. The factory validates the manager's code hash at planning, deployment and later verification; the hook authenticates the manager by stored address on every enabled callback. The hook constructor does not call another contract or require external code. Direct standalone deployers must perform the same manager-identity checks as the factory integration. Code hashing alone cannot identify a malicious contract as canonical or detect upgrades behind an unchanged proxy.

The creator, transaction caller, pool initializer, routers, hookData, RPC results and stored plans are untrusted inputs. The callback `sender` is typically a router and is used only for an informational event, never user authorization. PoolId contains the full PoolKey, including currencies, fee, tick spacing and hook. State has no single-pool assumption.

## Failure modes and controls

| Threat | Control / limitation | Local evidence |
|---|---|---|
| Direct spoofed callbacks | Enabled callbacks require exact manager caller and `key.hooks == this`; unused callbacks always revert | Unauthorized caller fuzzing, wrong hook and all disabled callback tests |
| Cross-pool state confusion | Initialization and counters keyed by full PoolId; unknown IDs fail | Two distinct newly initialized pools and independent counters |
| Unauthorized configuration or asset extraction | No setter, owner, proxy, upgrade, delegatecall, payout, token approval or external asset call in the hook | Source review; deployed settings/runtime comparisons |
| Dynamic pool with silently zero fee | Dynamic fee pools explicitly fail initialization | Wrapped revert and manager/hook state rollback test |
| Wrong signed limit handling | Direct signed comparisons avoid negating int256.min; limit is positive uint128 | Min/max/zero tests, signed fuzzing, four exact-mode/direction boundaries |
| Bypassing economic intent | Limit is only a per-call requested specified-currency bound; splitting swaps is allowed, exact-output input is not capped | Documented template behavior; no claim of economic or MEV protection |
| Reentrancy | Hook enabled callbacks make no external calls. Factory creates fixed known code and verifies through static calls; it never executes caller-supplied bytecode | Control-flow review; downstream settlement failure rolls back counter and pool state |
| Wrong CREATE2 deployer or constructor encoding | Shared formula uses actual factory and full creation code plus constructor ABI; factory checks caller commitments | Independent formula fuzzing, script and SDK integration, real CREATE2 deployment |
| Extra or missing callback permissions | Full low-14-bit equality plus constructor validation, exact fixed spec mask | Permission fuzzing, wrong salt failures, all 14 permissions inspected |
| Tampered artifact, script, RPC response or cached plan | Compare local factory/hook runtime, independently calculate plan, bind chain and constructor args, verify onchain | Changed plan/settings/hash/address, corrupted runtime and storage tests; adapter tampering tests |
| Manager at wrong address or with changed code | Require nonempty expected code hash and matching chain, recheck on deployment/verification | Missing code, changed code, wrong chain and invalid spec failures |
| Copying deployment calldata | Permissionless identical deployment confers no ownership. Duplicate deploy fails; caller can verify existing identical instance | Front-running-equivalent caller and occupied-address tests |
| Salt exhaustion or arithmetic wrap | Bounded paginated search and checked range; explicit exhaustion result | Empty page, successful page, resume index and overflow tests |
| Unexpected ETH or tokens | Nonpayable methods, no payable fallback; unsolicited/forced funds are not part of logic and cannot be recovered | Prefunded CREATE2 address deploys identically |
| Unsettled swap | PoolManager's unlock accounting reverts the transaction; hook count and events roll back too | Deliberately missing settlement and subsequent successful swap |
| Mainnet broadcast | This release's factory constructor/deploy, scripts, shared integration and adapter allow only local/named test chains. The hook template is chain-agnostic by design, and a direct deployment outside the factory is not recognised by `verify` | Named mainnets and fuzzed unknown chain IDs rejected on every release path; direct template deployment on chain 1 shown unregistered |
| Exact-output input exceeds limit | By design: the limit caps only `amountSpecified`. Users bound input with router slippage limits | `testLimitCapsOnlySpecifiedSideNotUnspecifiedSide` |
| Salt mining fails under RPC gas caps | Pages stop early on low gas and return a resume nonce; `InsufficientGas` when no progress is possible | Capped-gas walk equals uncapped result |
| Swapped IMD verdicts, replay, reused IDs | Verdicts require exact owner-bound oracle UUID, canonical question hash, chain and window, snapshotted panel minimums and consumer-domain signature. Unbound verified answers remain receipts with no verdict or UUID reservation. A matching owner confirmation reserves/consumes once; Intake IDs and bound UUIDs remain reserved after failure/expiry | `ReviewBinding.t.sol`, `ReviewDelivery.t.sol`, `OracleConformance.t.sol` |
| Callback arrives before owner binding | Verify on arrival and retain five slots under the pending Intake ID. Later exact binding finalizes with no new callback or fee. A second callback/failure cannot replace the receipt. Incorrect ABI/signature, wrong pairing or insufficient gas can still lose the one-shot answer | Cold 200k stipend, fee accounting, no-retry and mismatched-confirmation tests in `ReviewDelivery.t.sol` |
| Incorrect or missing body-to-oracle mapping | Owner must independently authenticate the mapping and canonical question, including after receipt. Receipt fields alone are not proof of the pairing. Wrong owner mapping can approve the wrong question; missing mapping prevents finalization. Live post-delivery evidence remains unverified | Binding procedure and pilot requirements in `IMD_INTEGRATION.md`; swapped early yes/no receipts cannot confirm under their correct bindings |
| Clock skew or late valid delivery | Allow 300s backward skew from ask time and 300s forward skew from receipt time; signature expiry is checked on arrival. Deadline enables explicit requester abandonment instead of rejecting fresh late answers. Expiry first closes the ask permanently; finalization first settles it | Timing fuzz/boundary tests and both transaction orders in `ReviewDelivery.t.sol` |
| Delayed confirmation after signature expiry or signer revocation | Stored verification is final at receipt; confirmation only matches the immutable context and consumes once. It can apply a historical answer after expiry/rotation. Owner must verify the exact mapping; requester can abandon a receipt after the deadline | ERC-1271 revocation, signer/Intake rotation, signature expiry and retained-answer abandonment tests |
| EIP-7702 signer acquires code | ECDSA recovery first, ERC-1271 fallback; code presence alone does not disable the key. Key signatures can bypass delegated wallet rejection by design | `OracleSigner.t.sol`; Cancun designator simulation, not a live delegation transaction |
| Seller ad blocks buyer after listing transfer | Current listing owner can cancel; all unused fee credit remains with the original payer; escrow admin gains no cancellation power | `FeaturedTransfer.t.sol`, original and transfer-aware conservation invariants |
| Prompt injection via creator brief | Strict UTF-8, no JSON-significant or delimiter characters, quoted as untrusted data inside the owner template | Brief validation and fuzz tests |
| Malicious requester owner | Current Intake/signer authorize future callbacks even for already-open/pending requests. Owner can rotate them, forge a matching answer or completion, and restore them. Received answers cannot be replaced. Binding accuracy is also trusted. Two-step ownership prevents accidental handover loss, not malicious administration. Use a multisig and monitor events | `testOwnerRotationPowersApplyToAlreadyPendingRequestsAsDocumented`; receipt immutability tests; `IMD_INTEGRATION.md` |
| Intake price move drains a wallet's standing allowance | `HookJobRequester` pulls the Intake's current price only up to the owner's `maxPrice` ceiling (constructor input, `setPayment`); above it the ask reverts before anything is pulled | `testPriceCeilingProtectsStandingAllowance` |
| Version 1 Intake has no failure function | Owner-set `failureHook` (on by default) switches asks between `requestWithFailure` and `request`; with it off a refused job is closed only by its deadline | `testVersion1IntakeWorksWithTheFailureHookOff` |
| Intake request id collides with any earlier ask | Both ask paths permanently reserve used IDs, including failed/expired/settled reviews | `testJobIdCollidingWithPendingReviewAskRefused`, `testFuzzIntakeIdCannotBeReusedAfterReviewCloses` |

The factory emits after verifying freshly created code. Foundry's generic `reentrancy-events` lint flags this sequence; the verification calls are static reads of the fixed hook whose runtime was just checked, and its constructor has no external calls. There is no untrusted state-changing callback in that sequence. This is reviewed reasoning, not an external audit finding.

`swapCount` counts completed `afterSwap` callbacks, not unique traders, volume or guaranteed nonzero fills. Counts/events roll back if a later part of the transaction fails. An initializer pays for its own per-pool storage entry; there are no loops over all pools. Checked uint256 counter overflow is practically unreachable but would revert that pool's swap. Limit rejection does not prevent liquidity removal because no liquidity callback is enabled.

## Residual risks and responsibilities

There is no admin recovery from an incorrect manager, limit or defective immutable implementation. Redeploy a reviewed hook and use new pools. This template intentionally accepts arbitrary new static-fee PoolKeys; it has no currency allowlist or decimal normalization. A pool creator must judge the limit for each pair. The hook ignores hookData. Applications must separately enforce deadlines, output minima/input maxima and token compatibility.

RPC identity, censorship and reorgs are not secured by a bytecode hash. Operators must use trustworthy chain data, validate successful receipts, retain plans and apply chain-specific finality. A backend using this adapter must restrict RPC destinations, rate-limit mining, authenticate users and keep signing outside the read-only adapter. A forged checker response must never mark a deployment verified.

## Review scope and untested areas

This work includes manual review and Foundry fuzz/success/failure tests, plus a local Anvil adapter test. No independent security audit, Slither or Mythril run, public-chain fork, live testnet transaction, hostile-token suite, native-currency integration, production router test, sequencer-failure test, or hosted-service penetration test was performed. Core/vendor functionality is tested only as used here, not re-audited in full. A separate adversarial review is required before release involving others' funds.
