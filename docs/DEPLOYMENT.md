# Deployment and operations

This assignment executed local tests only. The factory and supplied scripts reject all chains except `31337`, `11155111`, `84532` and `46630`. Mainnet deployment is disabled in the release. See [chain support](CHAINS.md) for untested items.

## Build identity

Use solc 0.8.26, Cancun, optimizer enabled with 200 runs, metadata hash disabled and CBOR metadata omitted, exactly as in `foundry.toml`. Dependencies are pinned in `dependencies.lock.json`. Runtime templates have no immutable substitutions or linked libraries. Constructor settings use write-once storage, with no setters; no configuration is read from the factory or caller by the hook constructor.

Keep the source revision, compiler configuration, vendored dependency hashes, creation bytecode, runtime bytecode and constructor arguments with each plan. Rebuild and re-mine after any change to compilation output. Do not substitute a newly compiled hook into an old mined plan.

## Required parameters

| Parameter | Who supplies it and how it is checked |
|---|---|
| Target chain ID | Operator chooses a supported local/test chain; spec, RPC and EVM must agree. |
| PoolManager | Operator supplies the actual deployed compatible manager from approved network configuration and protocol references. |
| PoolManager code hash | Operator reviews the manager implementation and records `keccak256(eth_getCode(manager))` on that chain. Factory requires code and hash equality. |
| Hook limit | Creator supplies a positive uint128 raw-unit limit after considering currency decimals and exact-output behavior. |
| Factory address | Operator bootstraps this factory or selects an existing deployment of the exact local build; integration compares its full runtime. |
| Broadcaster | Explicit script argument, nonzero; signer is controlled by the operator's wallet, never the hook or Store factory. |
| RPC endpoint | Explicit operator argument; use trusted infrastructure and independently confirm chain identity and receipts. |
| Search range | Explicit start nonce and bounded attempts; exhaustion requires a new page. |

A nonempty hash does not prove a manager is canonical: a counterfeit manager can also have code and a hash. Resolve identity before populating the spec, and avoid upgradeable substitutes whose proxy code stays constant while logic changes. No target deployment address is guessed in this repository. The address reference input contained no task-specific network manifest.

## Scripts

`DeployStore.run(address broadcaster)` deploys only `HooksStoreFactory`. This is a bootstrap operation; it does not deploy a PoolManager or initialize a pool. On a local test chain, the test fixtures independently provide their own manager. On a named testnet, the operator must supply an already deployed, reviewed compatible manager.

`DeployHook.run(address broadcaster, address factory, HookSpec spec, uint256 startNonce, uint256 attempts)` calls the same `HookDeployment.prepare/execute` integration tested in `Deployment.t.sol`. It validates the factory code, mines before broadcasting, checks the plan immediately before deployment and verifies afterwards. Constructor settings and the actual factory address feed the search. No environment variable is read by either script.

To simulate with Foundry, use explicit arguments and omit `--broadcast`:

```sh
forge script script/DeployStore.s.sol:DeployStore \
  --sig 'run(address)' "$HOOKS_BROADCASTER" --rpc-url "$HOOKS_TEST_RPC"

forge script script/DeployHook.s.sol:DeployHook \
  --sig 'run(address,address,(uint32,bytes32,uint256,address,bytes32,uint160,uint128),uint256,uint256)' \
  "$HOOKS_BROADCASTER" "$HOOKS_FACTORY" "$HOOKS_SPEC_ABI_TUPLE" 0 131072 \
  --rpc-url "$HOOKS_TEST_RPC"
```

`DeployHookJobRequester` deploys and configures the IMD requester (see [IMD_INTEGRATION.md](IMD_INTEGRATION.md)). Its units are `check(config, jobAction, reviewAction)`, which refuses an Intake or IMD address without code and an action the Intake does not sell within the price ceiling; `deploy(config)`; and `configure(requester, templates)`, which must run as the owner. `run(broadcaster, config)` and `runConfigure(owner, requester, templates)` wrap them in a broadcast. `DeployHookJobRequester.t.sol` calls the units directly. The requester is not chain-gated by `DeploymentPolicy`: the Intake exists only on Ethereum, Robinhood Chain and Sepolia, and `check` is what refuses a chain without it. Nothing was broadcast in this assignment.

```sh
forge script script/DeployHookJobRequester.s.sol:DeployHookJobRequester \
  --sig 'run(address,(address,address,address,address,uint256))' \
  "$HOOKS_BROADCASTER" "($HOOKS_OWNER,$IMD_INTAKE,$IMD_TOKEN,$IMD_ORACLE_SIGNER,500000000000000000)" \
  --rpc-url "$HOOKS_TEST_RPC"
```

All `HOOKS_*` and `IMD_*` values are explicit operator inputs; there are no supplied keys or default addresses. `sdk.hooks_store.abi_tuple(spec)` produces the exact tuple. Simulation does not persist the factory, so it cannot supply a real deployed factory address for a subsequent run. An operator who later elects to submit a testnet transaction must use their own signing workflow and preserve the receipt; no such transaction was submitted in this assignment. The client in [STORE_API.md](STORE_API.md) instead gives the Store a complete unsigned transaction for its wallet integration.

## Evidence and lifecycle

Before submission, review the spec, limit units, allowed chain, exact factory, manager code hash, salt, predicted address, init-code hash, expected runtime hash and transaction destination/data/value. Re-simulate against current state. Mining output from a prior block can become stale if someone has deployed the same plan or if dependencies have changed.

After submission, check a successful transaction receipt and the emitting factory, then run verification from a fresh RPC snapshot. Independently retain runtime bytes, the spec, constructor arguments and the emitted hashes. Observe the chain's required confirmations and rollup finality, then verify again if a reorg removes the receipt. Source verification on the explorer and provenance publication are operator work after an actual deployment.

Pool operators separately choose currencies, static fee, tick spacing and initial price, initialize **new** PoolKeys using the hook, and add liquidity through appropriate periphery. None of this is called by deployment. A hook address cannot migrate an existing pool to a new policy. A bad immutable manager/limit requires a new hook; pool users must explicitly choose new pools. Existing liquidity can still be removed because the hook has no liquidity callbacks or pause mechanism.

No funds should be sent to the hook or factory. Methods are nonpayable and there are no recovery methods; forcibly sent ETH or unsolicited tokens may remain inaccessible. There are no operator fees, keepers, payouts or admin responsibilities inside the hook. Operational monitoring and incident communication remain with the Store and pool applications.
