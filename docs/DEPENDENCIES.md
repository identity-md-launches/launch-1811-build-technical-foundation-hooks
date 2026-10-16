# Dependency provenance

All required Solidity source is vendored as ordinary files. No submodules or package installation are needed to build offline. Exact upstream commits and selected paths are recorded in [dependencies.lock.json](../dependencies.lock.json).

| Component | Version / commit | Selected files | License |
|---|---|---|---|
| Uniswap v4-core | `v4.0.0`, `e50237c43811bd9b526eff40f26772152a42daba` | production `src/`, excluding upstream test helpers; `licenses/` | Per-file MIT / BUSL-1.1; original license texts included |
| forge-std | `v1.9.7`, `77041d2ce690e692d6e03cc812b57d1ddaa4d505` | `src/`, license files | MIT / Apache-2.0 |
| Solmate | `4b47a19038b798b4a33d9749d25e570443520647` (v4-core's pinned dependency) | `Owned.sol` required by PoolManager, `ERC20.sol` for local test fixtures | AGPL-3.0-only SPDX on retained sources; upstream license included |

**Correction (audit follow-up).** The earlier claim that files are copied unchanged was wrong. `lib/SHA256SUMS` records the **upstream** hashes; all 80 of those were re-downloaded from the pinned commits and match. But 18 vendored files under `lib/` differ from upstream. Each difference is exactly what `forge fmt` (Foundry 1.8.4, `line_length = 120`) produces from the upstream file: whitespace and line breaks only, checked file by file. Compiling the project against the pristine upstream files gives byte-identical creation and runtime bytecode for `BoundedSwapHook`, `HooksStoreFactory` and `PoolManager`.

`lib/` is protected build configuration, so it was not rewritten. The corrected evidence is in `docs/checksums/`:
- `UPSTREAM.sha256`: the upstream originals.
- `VENDORED.sha256`: the tree as committed.
- `FORMAT_ONLY.txt`: the files that differ, all formatting-only.

`sh script/verify-vendored.sh` checks all of this offline.

OpenZeppelin Contracts **v5.5.0** (`fcbae5394ae8ad52d8e580a3477db99814b9d565`, MIT) is vendored under `src/vendor/openzeppelin/`. It is the import closure of `EIP712.sol` and `SignatureChecker.sol`, which the oracle-consumer reference's `OracleAttestation.sol` needs (`isValidSignatureNowCalldata` first appears in v5.5.0). Six of those files were reformatted by `forge fmt` and are listed in `FORMAT_ONLY.txt`. `src/imd/OracleAttestation.sol` retains the reference's exact struct, hash and domain. Audit d9970905 follow-up adds an ECDSA import and changes verification to try the key first, even when it has EIP-7702 code, then fall back to ERC-1271. This is an intentional local verification change, not an upstream byte-for-byte claim; no vendored dependency was modified. Our test router is project-authored; no Uniswap periphery or external BaseHook dependency is needed. The hook implements the pinned `IHooks` interface directly, with the unused callback rejection separated into `DisabledCallbacks`.

The root MIT license covers project-authored files only. It does not relicense vendored material. Consult the retained per-file SPDX identifiers and upstream license files when redistributing or changing deployment scope.
