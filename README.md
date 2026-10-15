# Hooks Store foundation

A versioned HookSpec, one standalone Uniswap v4 hook, and a shared CREATE2 deployment path for chat and visual creators. The implementation is locally tested. No public-chain transaction was submitted, and no hosted Store, chat service, visual UI or production deployment is claimed.

`BoundedSwapHook` serves any number of **new static-fee pools on one PoolManager**. It rejects swaps whose requested `amountSpecified` is zero or outside an immutable raw-unit limit, then counts successful swap callbacks separately by PoolId. It neither holds swap funds nor changes fees or accounting deltas. Anyone may use it when initializing a new pool. A pool's hook is part of its PoolKey; this does not retrofit hooks onto existing pools.

The limit applies to input for exact-input swaps and output for exact-output swaps. It is **not** a dollar-value limit, an input cap for exact-output swaps, a cumulative limit, an oracle, a slippage control or MEV protection. A user can split trades. All pools share the same raw-unit ceiling, so creators must consider each currency's decimals. See [threat model](docs/THREAT_MODEL.md).

## Build and check

Requirements: Foundry (`forge`, `cast`, `anvil`), solc **0.8.26**, and Python 3.10+ for the optional Store adapter tests. Solidity dependencies are ordinary vendored files under `lib/`, with commits and selection recorded in [dependencies.lock.json](dependencies.lock.json). No npm packages, submodules, FFI or Foundry filesystem permissions are needed. Once the pinned compiler and Foundry are installed, all checks run without internet access.

```sh
forge build
forge test
forge fmt --check
python3 -m unittest discover -s test -p 'test_*.py' -v
```

The requested fuzz seed is pinned in `foundry.toml`:
`0x936d89b088020ddf36122a88c4c9aed7130c7a410f5c44680a7d121950c99345`.
Tests do not read or mutate environment variables. Python integration tests start and stop their own disposable Anvil instance on loopback; they never use a remote RPC or a private key.

The Foundry suite mines and deploys real CREATE2 hooks, creates a fresh real v4 PoolManager, and initializes two distinct new pools using the same hook. It exercises swaps, limits, both exact modes and directions, per-pool isolation, liquidity withdrawal, failed settlement rollback, permissions, malformed specs and deployment verification. Test tokens and the settlement router exist only in `test/`. Neither deployment script creates tokens, managers or pools.

## Entry points

| Deliverable | Entry point |
|---|---|
| Shared creator output | [JSON schema](schemas/hook-spec.v1.schema.json), [ABI struct](src/HookSpec.sol), [spec contract](docs/HOOK_SPEC.md) |
| Reusable hook | [BoundedSwapHook.sol](src/BoundedSwapHook.sol) |
| Store-callable contract interface | [IHooksStore.sol](src/interfaces/IHooksStore.sol) |
| Shared factory and verification | [HooksStoreFactory.sol](src/HooksStoreFactory.sol) |
| Mining and script integration | [HookMiner.sol](src/deployment/HookMiner.sol), [HookDeployment.sol](src/deployment/HookDeployment.sol) |
| Configurable scripts | [DeployStore.s.sol](script/DeployStore.s.sol), [DeployHook.s.sol](script/DeployHook.s.sol) |
| Read-only Store client and unsigned transaction builder | [hooks_store.py](sdk/hooks_store.py) |
| Integration instructions | [Store API](docs/STORE_API.md), [deployment operations](docs/DEPLOYMENT.md) |
| Evidence and limits | [verification](docs/VERIFICATION.md), [chain support](docs/CHAINS.md), [threat model](docs/THREAT_MODEL.md) |

Both creator frontends emit the same structured spec. They call `normalize_spec` / `build_spec`, then `StoreClient.plan`; they do not generate arbitrary Solidity or supply arbitrary bytecode. The Store gets a reviewable unsigned transaction. A separately controlled wallet can submit it to an allowed test network, after which a fresh client calls `verify`. The Python adapter can be embedded in a backend; other languages can call the same ABI directly.

## Configuration and responsibilities

No production addresses are embedded. An operator must supply the actual chain ID, a reviewed PoolManager address and its runtime code hash, the deployed Store factory address, RPC endpoint and an explicit broadcaster for scripts. The creator supplies the positive raw-unit swap ceiling. Missing or inconsistent settings fail validation. This repository was not supplied a network address manifest and does not copy unchecked addresses from reference tables.

There is no hook owner, proxy, upgrade key, pause key, fee recipient or mutable setting. The factory is permissionless and can deploy only the pinned template. The constructor's settings are write-once storage, with no setters; this makes the entire runtime bytecode independently comparable before and after deployment. A different setting requires a new deployment and new pools.

The deployment policy permits local chain `31337`, Ethereum Sepolia `11155111`, Base Sepolia `84532`, and Robinhood Chain Testnet `46630`. Only local execution has been tested. Ethereum, Base and Robinhood mainnets are explicitly rejected. Full chain-specific status is in [CHAINS.md](docs/CHAINS.md).

## After launch

There are **no after-launch setters** for this template. Before a test deployment, the operator must verify the PoolManager identity and code, review the limit, and preserve the exact build and plan. After deployment, independently verify the transaction receipt, CREATE2 address, runtime code, callback bits and constructor settings; publish the source and constructor arguments. Pool selection, initialization price, liquidity, routing, approvals and user slippage limits belong to separate pool operators and applications, outside deployment.

The Store operator owns wallet integration, RPC security, confirmation/reorg handling, monitoring, indexing and evidence retention. An IMD request-checker response, a mined salt, successful simulation or HTTP 200 response is not evidence of a hosted deployment. Independent adversarial review remains necessary before use with real funds.

Project-authored code is MIT-licensed. Vendored files retain their original licenses, including Uniswap v4's file-specific MIT/BUSL-1.1 terms; see [dependency provenance](docs/DEPENDENCIES.md).
