# Chain support and evidence boundaries

The HookSpec, ABI encoding, CREATE2 calculation and fixed hook template are ordinary EVM components. The pinned PoolManager uses transient storage, so the execution environment must support Cancun semantics, including [EIP-1153](https://eips.ethereum.org/EIPS/eip-1153). Compatibility is conditional on the actual network's EVM and compatible reviewed v4 manager. The assignment did not deploy, fork or call a live manager on any public chain.

| Environment | What works or is expected | Evidence in this repository | Deployment policy |
|---|---|---|---|
| Local Cancun EVM / Anvil, 31337 | Full spec → mining → deployment → verification; real v4 pool initialization and swaps | **Tested locally.** Two fresh pools in Foundry; adapter and unsigned transaction path on disposable Anvil | Allowed |
| Ethereum | Standard EVM CREATE2 and v4 interface integration are expected to apply | **Untested on Ethereum.** No mainnet or Sepolia fork, RPC manager verification or live deployment | Mainnet 1 rejected; Sepolia 11155111 allowed for future testing |
| Base | Same spec/factory/hook design is expected with a chain-specific manager and Cancun-compatible execution | **Untested on Base.** No mainnet or Base Sepolia fork, manager verification or live deployment | Mainnet 8453 rejected; Base Sepolia 84532 allowed for future testing |
| Robinhood Chain | Standard EVM deployment is expected per Robinhood's Solidity/Foundry documentation; compatible manager and opcode support must still be verified on the chosen network | **Untested on Robinhood Chain.** No mainnet or testnet fork, manager verification, live deployment or gas benchmark | Mainnet 4663 rejected; testnet 46630 allowed for future testing |

Changing `vm.chainId` in the policy unit test only proves the allowlist works. It does not emulate a network, validate its addresses, or establish live compatibility. There are no hard-coded per-chain manager addresses or universal-deployer assumptions. The actual factory is the CREATE2 deployer, and each chain's spec commits its own manager address, code hash and chain ID; identical cross-chain hook addresses are not promised.

Uniswap's current [deployment reference](https://developers.uniswap.org/docs/protocols/v4/deployments) lists v4 deployments for Ethereum, Base and Robinhood Chain. Listing is documentation evidence only, not an onchain check by this project. The operator must obtain the approved address for the selected network and inspect its code and identity before supplying the spec. A mainnet listing does not establish a manager's availability on the corresponding testnet.

Base documents chain IDs [8453 and 84532](https://docs.base.org/base-chain/api-reference/ethereum-json-rpc-api/eth_chainId). Robinhood documents its [network configuration](https://docs.robinhood.com/chain/connecting/) and [EVM-compatible Solidity/Foundry workflow](https://docs.robinhood.com/chain/deploy-smart-contracts/). These sources were consulted for compatibility documentation; their examples were not executed.

The hook uses neither `block.number` nor timestamps, so it introduces no L1/L2 clock assumption. Rollup sequencer outages, ordering, censorship, upgrades and settlement finality still affect users and operational monitoring. This hook provides no sequencer bypass or MEV guarantee. Token pauses, denylisting, confiscation, rebasing or transfer fees are separate token/protocol risks, including when a pool trades tokenized assets. The local tests use ordinary ERC-20 fixtures, not Robinhood stock tokens or production routers.

## Deployment preparation update (2026-10-17)

The [preparation runbook](DEPLOYMENT_PREPARATION.md) separates read-only live protocol evidence
from local infrastructure tests and an unperformed real paid pilot. It records current official
no-token launcher capabilities, first-party Intake/token/signer sources and price reads on 1,
4663 and 11155111. Sepolia job.open is unsold and its omission from the Intake capabilities list
remains explicit. The existing HooksStoreFactory is still testnet-only and BoundedSwapHook-only;
it is excluded from production deployment profiles. These observations do not change the policy
or establish production hook integration.
