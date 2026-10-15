# HookSpec v1

The schema is [schemas/hook-spec.v1.schema.json](../schemas/hook-spec.v1.schema.json). The canonical validator and encoder are [sdk/hooks_store.py](../sdk/hooks_store.py); the contract-side authority is [HookSpecLib](../src/HookSpec.sol). JSON Schema checks shape; the adapter and contract also enforce integer bounds, nonempty code commitments and semantic constraints.

| JSON field | JSON representation | Solidity representation and rule |
|---|---|---|
| `schemaVersion` | integer `1` | `uint32`, exactly 1 |
| `templateId` | `"hooks-store/bounded-swap/v1"` | `bytes32`, Keccak-256 of the UTF-8 template string |
| `chainId` | positive decimal string | `uint256`, must equal the execution chain |
| `poolManager` | 20-byte hex address | nonzero `address`; normalized to lowercase |
| `poolManagerCodeHash` | 32-byte hex hash | Keccak-256 of the reviewed manager's deployed runtime; nonzero and not the hash of empty bytes |
| `permissions` | `["afterInitialize", "beforeSwap", "afterSwap"]` | `uint160(4288)`, exactly `0x10c0` |
| `maxSpecifiedAmount` | positive decimal string | `uint128`, from 1 through 2^128-1, in raw specified-currency units |

Unknown fields, unknown versions/templates, changed permissions, duplicate JSON keys, floats, numeric coercions, leading zeroes and overflow are rejected. Both numeric strings are required even when their values fit a JavaScript number. No owner, token, pool, payout or privileged creator field is implicit. Display names, conversation history and visual coordinates belong in a separate UI document and are not deployment settings.

The template allows exactly three callback bits:

| Callback | Bit | Value |
|---|---|---|
| afterInitialize | 12 | `0x1000` |
| beforeSwap | 7 | `0x0080` |
| afterSwap | 6 | `0x0040` |

All eleven other bits, including all four return-delta permissions, must be clear. The check is `(uint160(hook) & 0x3fff) == 0x10c0`; testing only whether required bits are present is insufficient. The constructor calls the pinned Uniswap `Hooks.validateHookPermissions` too. The permissions model follows [Uniswap's hook deployment guide](https://developers.uniswap.org/docs/protocols/v4/guides/hooks/hook-deployment).

## Canonical commitment

The ABI field order is exactly the table above, and all fields are static:

```text
HookSpec = (uint32,bytes32,uint256,address,bytes32,uint160,uint128)
TYPEHASH = keccak256(UTF8(
  "HookSpec(uint32 schemaVersion,bytes32 templateId,uint256 chainId,address poolManager,bytes32 poolManagerCodeHash,uint160 permissions,uint128 maxSpecifiedAmount)"
))
specHash = keccak256(abi.encode(TYPEHASH, spec))
constructorArgs = abi.encode(spec)             // 7 ABI words, 224 bytes
initCode = BoundedSwapHook.creationCode || constructorArgs
initCodeHash = keccak256(initCode)
```

JSON whitespace and key order do not affect this hash. This is a deterministic deployment commitment, **not an EIP-712 signed authorization**. No signature verifier or replay nonce is implied. Chain ID is committed, so replaying the spec on another chain fails even when addresses coincide.

`specHash` describes intent. `initCodeHash` additionally binds the compiled implementation. The factory address, salt and init-code hash bind the predicted address. The plan also carries the expected runtime hash. Altering compiler flags, sources, dependency versions or constructor arguments requires rebuilding the plan and re-mining; retaining only a salt is not sufficient.

## Creator adapters and versioning

A chat creator supplies structured fields matching the schema, and a visual builder maps form values to the same fields. The foundation does not implement natural-language interpretation or drag-and-drop UI. Both can call:

```python
from sdk.hooks_store import build_spec, normalize_spec

# Every argument below comes from reviewed chain configuration or explicit creator input.
spec = build_spec(
    chain_id=selected_chain_id_as_string,
    pool_manager=reviewed_manager_address,
    pool_manager_code_hash=reviewed_manager_runtime_hash,
    max_specified_amount=creator_limit_as_decimal_string,
)
assert normalize_spec(chat_structured_output) == spec  # if the creators chose the same settings
```

Version 1 is intentionally one reviewed template. Arbitrary generated Solidity, programmable callback graphs, dynamic fees, per-pool mutable policy and upgradeable hooks are not part of this ABI. New semantics require a new template ID and implementation, a reviewed factory build and new deployments. Breaking wire-format changes require a new schema version. Existing specs are never silently migrated to a different implementation.
