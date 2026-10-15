# Interface for the Store

The stable contract boundary is [IHooksStore](../src/interfaces/IHooksStore.sol). Generated ABI JSON is available after `forge build` at `out/IHooksStore.sol/IHooksStore.json`. The Python adapter supplies a usable reference integration without package installation. Both creator paths must use the same encoder and planner.

## Contract calls

| Call | Effect |
|---|---|
| `preview(spec, salt)` | Validate target and return deterministic plan. Does not assert the candidate's bits or availability. |
| `mine(spec, startNonce, attempts)` | Read-only, bounded CREATE2 search. Returns `(found, salt, hook, nextNonce)` and skips matching addresses with code. |
| `initCode(spec)` | Return exact template creation code with ABI-encoded constructor arguments. |
| `runtimeCodeHash()` | Return expected hook runtime hash for this factory build. |
| `deploy(spec, salt, expectedHook, expectedInitCodeHash)` | Validate commitments and bits, deploy exactly one hook, verify it and emit `HookDeployed`. Nonpayable. |
| `verify(spec, salt, hook)` | Recompute plan; check registry, exact runtime hash, every stored constructor setting and callback declaration. Reverts on disagreement. |
| `deployedSpecHash(hook)` | Factory provenance record; zero means this factory has not registered the hook. |

A plan contains `chainId`, `factory`, `hook`, `salt`, `specHash`, `initCodeHash`, `runtimeCodeHash` and `permissions`, in that ABI order. `HookDeployed` records the indexed hook and spec hash, plus salt, init-code hash and runtime hash. Treat the log as a locator for verification, not standalone proof.

The actual CREATE2 deployer is **HooksStoreFactory**, regardless of the calling wallet, script or backend. It is not the script contract, broadcaster or a universal CREATE2 proxy:

```text
predicted = low160(keccak256(0xff || factory || salt || keccak256(initCode)))
```

Salt candidates are `bytes32(nonce)` in `[startNonce, startNonce + attempts)`. `attempts` is 1–131072 and overflowing ranges fail. A failed page returns `found=false` and a next nonce; its empty salt/address fields are result markers, never usable deployment parameters. Resume explicitly at `nextNonce`. Mining is probabilistic, about one matching low-14-bit pattern per 16384 candidates; no page is guaranteed to succeed. Do not send mining as a paid transaction.

An occupied address causes deployment to fail. If another user submits the identical public plan first, call `verify` and use the identical hook after checking it. That caller gains no ownership or configuration rights. If a different plan occupies an address, reject it. CREATE2 collisions revert atomically; there is no overwrite operation.

## Python integration

```python
from sdk.hooks_store import Rpc, StoreClient, normalize_spec

spec = normalize_spec(creator_output)
client = StoreClient(Rpc(reviewed_test_rpc), reviewed_factory_address)
plan = client.plan(spec, start_nonce=0, page_size=4096, max_pages=32)

# Persist plan and show its spec, chain, addresses and transaction to the user.
unsigned_transaction = plan["transaction"]
# Wallet submission belongs to the Store's separately implemented wallet integration.

# After a successful transaction receipt and the application's confirmation policy:
evidence = StoreClient(Rpc(reviewed_test_rpc), reviewed_factory_address).verify(plan)
```

Instantiate a fresh `Rpc` for each operation. It pins all state reads in that operation to one block number. Reusing a client after a transaction deliberately retains the old snapshot. The adapter verifies exact factory runtime against the local build, manager runtime against the spec, the independently calculated CREATE2 address, full factory preview and low-bit mask. It emits unsigned `to/data/value/chainId` calldata and never signs or sends it. It uses only `eth_chainId`, `eth_blockNumber`, `eth_getCode`, and `eth_call`, with explicit HTTP transport and no proxy discovery.

After submission, `verify` rejects changed plan fields or transaction calldata, compares the full deployed hook runtime bytes and calls the factory's constructor-settings/provenance verifier. Its result includes the observed block number. It does not replace receipt-status checks, finality policy or reorg monitoring. The Python adapter requires the locally built artifacts; deployments cannot be verified against an arbitrary remote artifact supplied by a creator.

CLI equivalents (the named arguments must be populated by the operator):

```sh
python3 sdk/hooks_store.py validate spec.json
python3 sdk/hooks_store.py plan spec.json --rpc "$HOOKS_TEST_RPC" --factory "$HOOKS_FACTORY" > plan.json
python3 sdk/hooks_store.py verify plan.json --rpc "$HOOKS_TEST_RPC"
```

These are documentation variable names, not provided credentials or environment files. The adapter itself reads explicit arguments only. Missing deployment inputs have no hard-coded fallback.

## Store state and errors

Use separate states for draft, validated spec, mined plan, wallet approval, submitted transaction, confirmed transaction and verified deployment. Preserve errors and permit explicit retries. Schema/chain/code mismatches require correcting inputs; search exhaustion resumes at the reported nonce; stale builds require a new plan; occupied addresses require verification or re-mining. A failed transaction has not deployed a hook. A successful IMD checker or backend request is never the `verified deployment` transition.

The Store must implement authentication, wallet UX, rate limits, approved RPC selection, confirmation depth, storage of transaction hashes and plans, and monitoring. Do not expose this adapter as a public URL-fetching service without restricting RPC destinations. None of those hosted components is delivered or claimed as operational here.
