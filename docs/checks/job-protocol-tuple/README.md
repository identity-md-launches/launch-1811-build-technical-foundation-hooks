# Job callback protocol correction

Base commit: `575e8a8f74da581298a8527f493e9eab8a45901f`. This is a source/local-test
patch. No deployment, paid request, token replacement or funded-wallet operation was performed.
The repository's `.git/` write prohibition is respected: no new commit was created.
[Implementation diff](implementation.patch) includes source, callers, tests, ABI, fingerprints and
current documentation; this evidence directory and its raw logs are delivered separately.

The [protocol](https://imd.fun/docs/#what-comes-back) specifies a job result tuple of
`(bytes32 requestId, bytes32 resultHash, string uri)`. The old callback decoded `(bytes32,bytes)`
and hashed the bytes it received, so the existing mock callers concealed a protocol mismatch.
The production change is limited to that callback, its documentation and one additional event.

## RED before production changes, then GREEN

The exact requested `testProtocolTuple` was added to `JobProtocolTupleTest`, inheriting
`HookJobRequesterFixture`, before any production or existing fixture changes. Command:

```sh
forge test --match-contract JobProtocolTupleTest --match-test testProtocolTuple -vvvv
```

- [RED log](red.log), exit **1**: **0 passed, 1 failed, 0 skipped**. The registered selector was
  `0x5dd4c70b`; `MockIntake.complete` forwarded the real tuple unchanged, the old callback
  reverted during ABI decoding, and Intake returned `false` to `assertTrue`.
- [GREEN log](green.log), exit **0**, after the callback and job callers were migrated:
  **1 passed, 0 failed, 0 skipped**. The selector is `0x325a77b4`; `JobDelivered` carries
  `0xce7930180e7cf7bc99fdb265c1042726096f0b6244c97a1e0b3f8cf103d22499`, exactly
  `keccak256("result document")`, and `JobResultURI` carries `ipfs://fixture`.

These are the retained original command outputs, not reconstructions. The GREEN trace precedes
the additional adversarial tests, so its whole-test gas differs slightly from later runs.
`MockIntake` and `ProofIntake` still forward `selector ++ args` under 200,000 gas without
translation. Oracle tuples and signatures are unchanged. Every existing test and assertion
is retained; the two old result-hash expectations now compare the supplied document hash.

## Commands and results

Commands run at the repository root with the unchanged pinned Solidity **0.8.26**, Cancun,
optimizer **200**, no metadata hash and no CBOR metadata. No dependencies or build settings changed.

| Command | Result | Raw output |
|---|---|---|
| `forge build` | Exit 0; compilation successful; advisory lints reported | [build.log](build.log) |
| `forge test --match-contract 'JobProtocol.*Test' -vv` | Exit 0; 12 passed, 0 failed/skipped | [tuple-tests.log](tuple-tests.log) |
| `forge test` | Exit 0; 252 passed across 27 suites, 0 failed/skipped | [foundry.log](foundry.log) |
| `forge test --fuzz-seed 0xf26a9b5634efd5ce7b559826e3d88cfde1d1b356c70d58ff3025a15e862a9578 --gas-report` | Exit 0; 252 passed across 27 suites, 0 failed/skipped | [assignment-seed-gas.log](assignment-seed-gas.log) |
| `forge test --isolate --match-contract 'JobProtocolGasTest\|ReviewReceiptGasTest' -vv` | Exit 0; 9 passed, 0 failed/skipped | [cold-gas.log](cold-gas.log) |
| `forge fmt --check` | Exit 0; no output | [fmt.log](fmt.log) |
| `node --test test/requester-abi.test.cjs test/listings-reader.test.cjs` | Exit 0; 18 passed, 0 failed/skipped | [site-abi.log](site-abi.log) |
| `python3 -m unittest discover -s test -p 'test_*.py' -v` | Exit 0; 10 passed on disposable local Anvil | [sdk.log](sdk.log) |
| `TMPDIR=test/scratch sh script/verify-vendored.sh` | Exit 0; 96 files verified, 24 recorded formatting differences | [vendored-retry.log](vendored-retry.log) |

The initial `sh script/verify-vendored.sh` exited 2 because its default temporary directory was
unavailable ([original output](vendored.log)). Rerunning with a writable scratch directory required
no script or dependency changes. Scratch files are not needed by the delivered tests.
The normal test run uses the repository seed
`0x936d89b088020ddf36122a88c4c9aed7130c7a410f5c44680a7d121950c99345`; the gas-report run
explicitly uses the assignment seed above. No Solidity test reads or sets environment variables.

## What is checked

The new Foundry tests cover the exact supplied hash, both events and indexed request ID, a static
15-word Job return, arbitrary hash/URI bytes, empty URI, unauthorized callers, duplicate callbacks,
the removed legacy selector, unknown IDs, six malformed payload shapes, the consumed single
attempt and retained fee, expiry, late delivery in either order, and a negative finalized review
surviving late delivery. All existing oracle, payment, listing/ad and review regressions remain.

The site tests compare the full published ABI to compiler output, verify callback/event types,
compare the decoder with `cast`, and test malformed lengths/offsets/padding/UTF-8, bounded decoding,
HTML/JavaScript/data URI text, other emitters/request IDs and removed logs. The URI is never
linked or fetched. An unavailable URI does not hide other history or confer a review verdict.
Compiler ABI comparison confirms only `onJobResult` changed and `JobResultURI` was added.

Cold minimum **forwarded** gas, measured by restoring state and cooling on every binary-search
trial and then exercising the unchanged exact-200k Intake path:

| Callback | Gas |
|---|---:|
| Job tuple, 4,096-byte URI, clean pre-existing Open job | 67,052 |
| EOA review receipt | 124,984 |
| 5-of-7 ERC-1271 receipt / bound verdict | 170,077 / 132,553 |
| 5-of-7 mismatched pre-binding receipt | 175,123 |
| 22-cold-read signer receipt / bound verdict | 187,231 / 149,726 |
| 22-cold-read mismatched pre-binding receipt | 192,286 |

These are callback execution measurements, not transaction totals or gas-report averages.
The requester runtime is **24,117 bytes**, **459 bytes** below 24,576. Creation bytecode is
25,861 bytes. [Build fingerprints](../../build-fingerprints.json) were regenerated and tested
against artifacts; the hook/factory fingerprints are unchanged. EIP-712 immutable substitutions
mean the artifact runtime hash is not a claim about any live instance.

## Remaining operational assumptions

The documented tuple is now implemented, but no live Intake/writer was exercised. Action/body
acceptance, prices and exact spending, asynchronous callback timing, request-ID routing and
uniqueness, real result-document hash/URI availability and URI length still require a pilot.
Malformed or over-budget delivery can consume the fee and sole callback; an unbounded URI cannot
be guaranteed to fit a finite stipend. Large/invalid UTF-8 strings can be emitted onchain even
when the reader cannot display them. URI/hash presence alone does not validate the document.

Owner powers over Intake/signer rotation, pending review binding, expiry/recovery and signer-epoch
revocation remain disclosed. Signed review outcomes still require independently authenticated
Intake-to-oracle mapping, canonical question/window, fresh signatures and qualified signer gas.
Delivery does not approve a review, and a matching document hash is not an audit. Operators must
also provide trustworthy RPC/log history and finality/reorg handling. Existing non-upgradeable
contracts and their registered selectors are unaffected by this source patch.

See [deployment parameters and owner duties](../../IMD_INTEGRATION.md#after-launch),
[callback compatibility](../../DEPLOYMENT.md#requester-callback-compatibility) and the
[live pilot list](../../IMD_INTEGRATION.md#requires-a-live-ethereum-or-robinhood-chain-pilot).
No Slither, Mythril or independent security audit was performed by this patch.
