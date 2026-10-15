# Dependency provenance

All required Solidity source is vendored as ordinary files. No submodules or package installation are needed to build offline. Exact upstream commits and selected paths are recorded in [dependencies.lock.json](../dependencies.lock.json).

| Component | Version / commit | Selected files | License |
|---|---|---|---|
| Uniswap v4-core | `v4.0.0`, `e50237c43811bd9b526eff40f26772152a42daba` | production `src/`, excluding upstream test helpers; `licenses/` | Per-file MIT / BUSL-1.1; original license texts included |
| forge-std | `v1.9.7`, `77041d2ce690e692d6e03cc812b57d1ddaa4d505` | `src/`, license files | MIT / Apache-2.0 |
| Solmate | `4b47a19038b798b4a33d9749d25e570443520647` (v4-core's pinned dependency) | `Owned.sol` required by PoolManager, `ERC20.sol` for local test fixtures | AGPL-3.0-only SPDX on retained sources; upstream license included |

Source files are copied unchanged from the named upstream commits. Our test router is project-authored; no Uniswap periphery or external BaseHook dependency is needed. The hook implements the pinned `IHooks` interface directly, with the unused callback rejection separated into `DisabledCallbacks`.

The root MIT license covers project-authored files only. It does not relicense vendored material. Consult the retained per-file SPDX identifiers and upstream license files when redistributing or changing deployment scope.
