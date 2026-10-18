# Confirmed native-chain oracle windows

Continuation of `378cd9b20db99e2190ed5a73fc73849250996e72`. Source and local verification only.
No public deployment, paid Intake request, live signature, backend, new signer, token or pool
was created. Test signatures and deployments use disposable local fixtures. These are contributor
self-checks, not an independent audit or a live end-to-end Hooks Store demonstration.

## Change and regression evidence

`red-regression.sol.txt` is the six-test source run against the unchanged base. `red.log` records
all six failures: one-block closing depth, early permissionless reserve spending, premature retry
spending, mixed Robinhood L1/L2 heights, unsupported clocks and a missing ArbSys accepted before
build payment. The final `window-green.log` has 28 passing tests, including those six and the
additional policy, canonical-question, and Robinhood callback-gas cases.

The closing block is native head minus eight. Start is the latest commitment/delivery, or retry
creation; start must be <= close before any reserved payment. The fixed window ends before the
trigger. Its signed bounds still match exactly, while signed issuance must be >= trigger time.
Ethereum/Sepolia/local use block.number; Robinhood 4663 uses ArbSys at address(100). Unknown
chains, failed/malformed ArbSys calls, and heights above the protocol's exact JSON integer limit
fail closed. The same native counter is used at every lifecycle stage and for callback age.

Additional tests cover both lifecycle orders, zero/small heads, all seven early blocks and the
first permitted boundary, native clocks on either side of mocked L1 height, freshness boundaries,
future/stale issuance and windows, expiry, reserve deadlines, retry identity and wrong-question
rejection. Existing tests still prove exact-candidate deployment/substitution refusal, no
NotPassed shopping, signer recovery/revocation, replay, reentrancy, refunds, fees and recipients.
The new minimum block-age configuration is eight; operational latency requires additional slack.

The immutable prefix algorithm was retained. `test/helpers/OracleQuestion.sol` is the official
library copied for tests with only imports/formatting adjusted. Tests reproduce its independent
`0x2117…46fb` vector and compare both exact emitted Ethereum/Robinhood bodies with the official
hash implementation. The original four captured public v2 question/signature vectors also pass.
Their signatures are genuine public records; they are not signatures for this application's jobs.

## Final checks

| Check | Result / log |
|---|---|
| `forge build` | Pass with pinned solc 0.8.26; `build.log` (compiler/lint warnings retained) |
| `forge fmt --check` | Pass; `fmt-check.log` is empty on success |
| `forge test` | 600 pass, 0 fail/skip; `foundry.log`, repository-pinned seed |
| `forge test --fuzz-seed 0x1cce11b977345bde5d2e8864effc5b353b22f85c7b0d962b70d90077d67f4205` | 600 pass, 0 fail/skip; `assignment-seed.log` |
| Isolated callback-gas suites | 21 pass; `callback-gas.log` |
| Python SDK / local Anvil | 64 pass; `sdk.log` |
| Node UI / ABI checks | 29 pass; `ui.log` |
| Offline protocol vectors | Pass; `protocol-vectors.log` |
| Vendored dependency verification | 96 files verified, 24 historical formatting-only differences; `vendored.log` |
| Production runtime sizes | All <= 24,576 bytes; `sizes.log` |

`bash script/check_automatic.sh` repeats the offline suites. It never runs the public free checks.
No compiler, build configuration, dependency, fee recipient or legacy contract change was required.
`preserved.json` records unchanged source/configuration hashes; current ABIs and build fingerprints
are refreshed. Open-time deployer validation moved into the pinned codec and fee quoting shares a
helper to keep runtime size within the cap, with dedicated preservation tests.

| Runtime | Bytes |
|---|---:|
| AutoHookJobRequester | 24,546 |
| HookRequestCodec | 14,088 |
| GatedHookDeployer (unchanged) | 20,967 |
| HookJobRequester (unchanged legacy) | 24,559 |

| Isolated minimum forwarded callback gas | EVM native clock | Mocked Robinhood ArbSys clock |
|---|---:|---:|
| EOA | 127,706 | 133,605 |
| 5-of-7 ERC-1271 | 172,804 | 178,704 |
| ERC-1271 with 22 cold reads | 189,978 | 195,877 |

All remain below the unchanged 200,000 stipend. The mock clock is cooled as well as the consumer,
codec, pin and signer. Oversized job URI and failure callbacks also pass. These measurements do
not promise every ERC-1271 signer or live chain execution will fit; operators must recheck their
chosen signer and native clock implementation. The requester has only 30 bytes of runtime margin.

## Exact free checks and limitations

`bodies/` contains byte-for-byte emitted job and oracle bodies on local Ethereum/Robinhood chain
simulations, exact HTTP request bodies, raw responses, status/time/hash metadata and separate
oracle drafting requests. These addresses, ids and commits are explicit test fixtures, never
launch configuration or claims of public jobs. `body-parity.json` proves the final test emissions
still match the bytes sent to the free checker.

- Both exact `job.open` inputs: HTTP 200, no blockers or suggestions.
- Both exact `oracle.request` inputs: HTTP 400 `invalid_request`. The free endpoint rejects
  `v`, `window`, `definitions`, `quorum`, `validForSeconds`, and `consumer` because it accepts a
  narrower drafting input. This is not evidence that an Intake oracle body was refused/admitted.
- Both separate oracle drafting inputs: HTTP 200, no blockers, with a `not_answerable` suggestion.
  The local job/source/review identities are not public evidence. The returned draft is not the
  emitted full body. No full-body admission, real panel verdict or live deployment is claimed.

To reproduce body extraction without network:

```sh
forge test --match-path test/OracleWindowRegression.t.sol -vv > window.log
python3 script/check_oracle_window_bodies.py --log window.log --directory local-bodies
```

Adding `--check` explicitly sends only free `POST https://api.imd.fun/requests/check`; it never
quotes, pays, signs or admits work. It records failed responses as well as successful ones.

Official inputs: [binding documentation](https://imd.fun/docs/#intake-binding-an-answer-to-its-request),
[oracle-consumer skill and OracleQuestion/OracleBoundConsumer](https://api.imd.fun/reads/skill/oracle-consumer).
The saved `oracle-reference.md` matches the pinned task input. `capabilities.json` records three
Ethereum Intake confirmations, two on Robinhood and two on Sepolia. Window maturity is already
sufficient at the trigger and does not depend on those confirmation settings. `sources.json`
records retrieval/provenance hashes and `imd-binding-docs.txt` retains the relevant documentation.

Deployment parameters, supported-clock assumptions, preflight, owner responsibilities and
one-shot delivery/recovery limitations are in [the automatic runbook](../../AUTOMATIC_BINDING.md).
Separate deployment authorization and independent adversarial review remain operational work.
