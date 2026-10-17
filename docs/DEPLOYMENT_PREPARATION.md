# Deployment preparation from b157921

This is an executable preparation package for the **unchanged audited contracts**, not a
release authorization. Nothing was deployed on a public chain, signed, paid to Intake, or
created as a project token or pool. Local Anvil mocks are identified separately below.

Start with [deployment/manifest.json](../deployment/manifest.json), the three approval-gated
[draft configs](../deployment/), and [prepare_deployment.py](../script/prepare_deployment.py).
These files use Python's standard library and the existing Foundry tools; no additional packages,
FFI, filesystem cheatcode permissions or compiler changes are needed.

## Deployment sequence and the actual launcher

| Order | Contract | Exact constructor arguments | Dependencies / initial behavior |
|---|---|---|---|
| 1 | `HookListingRegistry` | none | No global owner or configuration. Listings are free. |
| 2 | `FeaturedPlacements` | `($owner, $contract:HookListingRegistry)` | Registry must be the contract from step 1, on this chain. Token and proceeds recipient start unset. |
| 3 | `HookJobRequester` | `($owner, $intake, $asset, $oracleSigner, $maxPrice)` | Protocol inputs from the selected profile; both templates start unset. |
| 4, testnets only | `HooksStoreFactory` | none | No owner/setters. Current factory rejects production chains and deploys only `BoundedSwapHook`. |

The registry and ads must be deployed in that dependency order; the requester has no registry
constructor dependency. There is no token, distributor, liquidity or pool entry. All deployment
value is zero. A public owner is deliberately **not supplied**: `$owner` must resolve to the
explicitly approved wallet/multisig, not IMD's broadcaster, ProjectFactory, Intake or payee.
Although IMD can default owner to the paying wallet, this preparation requires explicit approval.

The [official launch fields](https://imd.fun/docs/#job-body-launch-fields), the
[live launcher recipe](https://api.imd.fun/reads/skill/evm-contracts-launch), and the actual
[No token launcher UI](https://explorer.imd.fun/launch) were rechecked. The UI selects
`onchain: "evm_contracts"`. The recipe uses ProjectFactory, allows 1–8 named contracts, static
constructor words (maximum 16), `$owner`, and backward `$contract:EarlierName` references.
The launch deploys and records contracts atomically; it **does not call post-deployment setters**.
Static constructors in this package fit the argument shape and need no external code at
construction. No atomic public ProjectFactory execution was performed here.

There is a further operational compatibility gate: that recipe asks for applications fully
configured in their constructors. Ads and requester intentionally require owner setters in this
audited build. **Do not describe them as ready-to-use automatically launched applications.**
Before choosing IMD's no-token route, obtain confirmation that its manifest/review process will
accept a deliberately unconfigured deployment with a separately executed owner handoff. Otherwise
use the explicit unsigned creation transactions and approved operator deployment route. Changing
constructors to satisfy that recipe would change audited bytecode and is outside this assignment.

`manifest.json` is a preparation format, **not** the launch service's `launch.json`. The latter is
created by IMD's separate manifest stage, with exactly `kind`, `contracts`, `notes`. Its contract
entries carry `contract` and `constructorArgs`; the static arguments and `$contract` dependency
above are the handoff. Do not copy the preparation file to `launch.json` or add setter calls to an
unsupported schema. The final launcher chain/policy/factory, gas limit and manifest acceptance
must be revalidated by that service. Its own source/operator execution was not audited here.

## First-party sources and current chain distinction

Sources: [Intake addresses](https://imd.fun/docs/#intake-addresses),
[Intake actions](https://imd.fun/docs/#intake-what-it-sells),
[capabilities](https://api.imd.fun/requests/capabilities), and the current
[oracle attester](https://api.imd.fun/oracle/requests?limit=1). Observations were captured on
2026-10-17; the tools can recheck them. Published addresses are configurable deployment inputs,
not new Solidity constants. Reconfirm identity and protocol support immediately before any launch.

| Chain / profile | Intake v2 | Payment asset | Factory in this package | Purpose |
|---|---|---|---|---|
| Sepolia, 11155111 | `0xa43e6f75ee006411f79ac1c84120606c2330de82` | TestIMD `0x44a1cd38474fb1748400e7deb5f8d786cce3f89a` | Included | Infrastructure only |
| Ethereum, 1 | same v2 | IMD `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7` | **Excluded** | Potential real paid pilot, separately approved |
| Robinhood Chain, 4663 | same v2 | IMD `0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127` | **Excluded** | Alternative real paid pilot, separately approved |

The observed oracle signer is `0x5598aa9146215bc13eb26f2c692ad1461fd32982`. It is the oracle
attester, **not** the capabilities `quoteSigner`. IntakeDelivery is not a constructor dependency:
this requester authorizes only its same-chain Intake. Do not configure IntakeDelivery as Intake
or assume cross-chain job/review requests work through this requester.

At the recorded blocks, read-only `priceOf` returned:

| Chain | `job.open@job-1` | `oracle.request@oracle-1` |
|---|---:|---:|
| Ethereum, block `0x18fee26` | 500000000000000000 | 500000000000000000 |
| Robinhood, block `0x5670d4a` | 500000000000000000 | 500000000000000000 |
| Sepolia, block `0xb610c6` | **0 (not sold)** | 500000000000000000 TestIMD |

All are 18-decimal assets. Action IDs are the UTF-8 action/version right-padded to bytes32,
**not keccak hashes**; exact encodings are in the manifest. Public capabilities also quote
0.5 IMD for job continuation, launch and workflow admission (and per schedule run); this tool
prepares no paid call to any of them. Minimum job plus review expenditure is currently 1 IMD,
plus chain gas; an asynchronous refusal or failed callback can spend the fee without a result.
The proposed per-ask ceiling is 0.5 IMD, subject to owner approval and fresh reads. Never
raise it automatically after a price change.

**Sepolia discrepancy:** the docs describe oracle-only Intake, but the captured
`onchain.chains` contains only 1 and 4663; the live Sepolia contract still quotes the oracle
price. A price is not proof its offchain writer will service it. Launch capabilities separately
list `evm_contracts` on all three chains. A launch *paid on mainnet* can target Sepolia; that
does not make `job.open` purchasable with free TestIMD. Keep Sepolia requester templates unset.
A review needs a job recorded by this requester, so Sepolia cannot test its complete paid flow.
Do not fabricate a job ID or prefill storage and call that a pilot.

No supported Base Intake/profile is provided. The factory policy also permits local 31337,
Base Sepolia 84532 and Robinhood Testnet 46630, but this package supplies no invented Intake,
asset or owner on those chains. Use the existing standalone factory/SDK for separately qualified
hook infrastructure there; a paid Hooks Store profile needs independently confirmed service.

## Owner approvals and configuration

**Preserved proposed ad proceeds recipient:**
`0x3f252e859a277a86A3967c11D4E054B2f07a1F22`, pending requester approval. No ownership,
multisig threshold or signers of this address were verified. The published Intake/HTTP payee
`0x4e0fa57bde726079356537e2f34d671e9f41adbc` is a different beneficiary; the configuration tool
explicitly rejects substituting it for ad proceeds. Ad price remains 0.1 IMD for seven days.

Copy the selected draft into an operator-controlled JSON file. Set `owner` to the real approved
address and `ownerApproval` to `{"address": <that address>, "reference": <approval record>}`.
Set `recipientApproval` in the same format only after approval of the exact configured recipient.
These records are explicit operator assertions, **not** cryptographic authorization or wallet
signatures. A changed address requires a matching new approval record. No tool discovers keys,
reads environment files, signs or submits transactions. Config and output should contain no
credentials; RPC URLs are explicit arguments and are omitted from generated plans.

| Exact owner call | Parameters and constraints | Readback |
|---|---|---|
| Ads `configureToken(address)` | Selected chain's verified 18-decimal IMD/TestIMD, **one time** | `imd()` equals approved token; `registry()` equals confirmed registry |
| Ads `setProceedsRecipient(address)` | Approved proposed recipient above; changes future purchases only | `proceedsRecipient()` equals that address |
| Requester `setFailureHook(bool)` | `true` for the v2 profile; v1 requires a separately reviewed config with `false` | `failureHook()` |
| Requester `setTimeouts(uint64,uint64)` | Proposed 604800 / 86400 seconds; each within 3600–2592000 | `jobTimeout()`, `reviewTimeout()` |
| Requester `setJobTemplate(bytes32,bytes,bytes,bytes)` | Paid profiles only, exact action and approved UTF-8 prefix/middle/suffix | `jobAction()`, each `jobBody*()` byte-for-byte |
| Requester `setReviewTemplate(bytes32,bytes,bytes,uint16,uint16)` | Paid profiles only, approved action/prefix/suffix/panel minimums | `reviewAction()`, both `reviewBody*()`, `minPanelSize()`, `minAgreed()` |

Token and recipient setters are separate transactions. Until both complete, do not open ads to
users. Constructor-supplied `intake`, `asset`, `oracleSigner`, `maxPrice`, explicit `owner` and
unset `pendingOwner` are also read back. Defaults already matching an approved desired value
are reported by readback and produce no redundant transaction. In particular, a fresh v2
requester already has `failureHook=true`, seven-day job and one-day review timeouts. The tool
never gratuitously calls `setOracleSigner`: that increments the signer epoch.

For a deliberate protocol migration, existing owner calls are `setIntake(address)`,
`setPayment(address,uint256)`, `setOracleSigner(address)` and `setFailureHook(bool)`; these are
**not automatic bootstrap repairs**. Their impact on pending asks requires the existing incident
procedure. Owner handover is `transferOwnership(address)` then `acceptOwnership()` by the new
owner. The registry has only per-listing ownership; there is no global registry owner. Factory
has no owner/configuration calls. Preserve escrow refunds and the rights of past recipients.

## Executable preparation and readback

Run from repository root. Names such as `operator.json`, `addresses.json` and `RPC_URL` below
mean files/values the operator supplies, not shipped identities. RPC endpoints must match the
selected chain. `--transport curl` is optional where network routing requires curl; `-q` disables
curl config files. The default SDK transport uses no implicit proxy discovery.

```sh
forge build
python3 script/prepare_deployment.py verify-build
python3 script/prepare_deployment.py manifest --config deployment/sepolia.draft.json
python3 script/recheck_official.py --output-directory test/scratch/fresh-official
python3 script/prepare_deployment.py preflight --config operator.json --rpc RPC_URL
```

`preflight` needs no owner approval and performs only reads: chain ID, fixed block, Intake/token/signer
code hashes, 18 decimals, balance ABI and both action prices. Public profiles pin the code hashes
observed in the saved live RPC evidence and refuse a change pending review. An EOA signer may
have empty code; a signer registry's storage/policy changes still require separate qualification.
It rejects missing required code, wrong
chains, unsold required actions and prices above the approved ceiling. It treats Sepolia job
price zero as expected while still reporting **paidPilotReady=false**. Compare fresh official
capabilities/attester with the manifest and resolve any change through owner review. Code
existence and prices do not establish all protocol semantics or qualify a signer implementation.

`creation` requires owner approval, checks all pinned source/config/bytecode hashes, verifies
constructor ABI and emits initcode plus exact ABI arguments with zero value. It neither mines
nor predicts arbitrary deployment addresses. There is intentionally no automatic send command:

```sh
python3 script/prepare_deployment.py creation --config operator.json \
  --contract HookListingRegistry --output registry-unsigned.json
# After a separately approved deployment, record the confirmed registry address in addresses.json.
python3 script/prepare_deployment.py creation --config operator.json --addresses addresses.json \
  --contract FeaturedPlacements --output ads-unsigned.json
python3 script/prepare_deployment.py creation --config operator.json \
  --contract HookJobRequester --output requester-unsigned.json
# Only for a supported testnet profile:
python3 script/prepare_deployment.py creation --config operator.json \
  --contract HooksStoreFactory --output factory-unsigned.json
```

Alternatively reuse `DeployStore.run(address)` and `DeployHookJobRequester.run(address,Config)`
with explicit inputs, as shown in [DEPLOYMENT.md](DEPLOYMENT.md#scripts). Both are exercised
without `--broadcast` in the local rehearsal. `DeployHookJobRequester.runConfigure(owner,requester,Templates)`
remains available for the two template setters, after all the same approval/body checks. An
ordinary direct call to `configure` from a script contract is not an owner call; the existing
wrapper broadcasts as the given owner. The Python tool emits direct owner calldata, suitable
for separate wallet review. It reuses `sdk/hooks_store.py` and compiled artifacts instead of
introducing another Solidity deployment implementation. `DeployHook` remains for the existing
BoundedSwapHook CREATE2 path and is not called to create a generated hook.

Populate `addresses.json` from confirmed receipts/launcher handoff, keyed by the selected
Solidity names. There must be three entries on a paid production profile or four on Sepolia.
The configuration tool checks every runtime byte. It fills the ads registry immutable and all
seven EIP-712 immutables with the expected values; it does **not** ignore immutable byte ranges.
It also verifies the public EIP-712 domain and constructor state before preparing setters.

```sh
python3 script/prepare_deployment.py configure --config operator.json --addresses addresses.json \
  --rpc RPC_URL --output owner-calls-unsigned.json
# Separate approved owner wallet execution, one successful receipt at a time, happens outside this tool.
python3 script/prepare_deployment.py verify --config operator.json --addresses addresses.json --rpc RPC_URL
```

Each unsigned entry includes chain, from, to, value, exact calldata, readable arguments and
expected raw readback data. Independent setter `eth_call` simulations run as the configured owner
at the same explicit block. Regenerate after changes; a snapshot can become stale. `verify`
recomputes expectations from the approved config rather than trusting an edited plan. It fails
on incomplete settings; successful reconfiguration is idempotent. A conflicting one-time token
or an existing different job/review template fails rather than silently overwriting state.
Observe confirmations and reorgs independently; a receipt or snapshot is not finality. Keep the
source revision, manifest, approvals, unsigned calldata, successful receipts, readbacks and code.

## Template activation and a real paid pilot

Drafts ship with `templates: null`, keeping job/review entry points `NotConfigured`.
`test/helpers/ImdTemplates.sol` is a **local historical fixture**, not a validated production
job schema: its `v/kind/repository/specHash/request` shape is not the current job body. Do not
install it from an old example. Solidity's marker check does not validate the live JSON schema.

An approved bundle has exactly `jobPrefix`, `jobMiddle`, `jobSuffix`, `reviewPrefix`,
`reviewSuffix`, `minPanelSize`, `minAgreed`, `sampleSpecHash`, `sampleBrief`, `sampleJobId`, and
`checks`. Fragments are UTF-8 JSON strings in the operator config; calldata encodes them as bytes.
Assemble the job with the real spec hash and brief, and review with a real recorded Intake job
ID. Use current [job-body](https://imd.fun/docs/#job-body) / [oracle-body](https://imd.fun/docs/#oracle-body)
fields: job has an `objective`, never `onchain`; quote the brief as untrusted text. Include all
three whole markers, chain, public review evidence, definitions, panel/quorum and validity window.
The oracle body must request bool on the chosen chain and meet the configured panel minimums.
No live job ID or publicly answerable review question has been invented for this package.

For each exact assembled body:

```sh
python3 script/check_request_body.py --action job.open --input job-body.json --output job-check.json
python3 script/check_request_body.py --action oracle.request --input review-body.json --output review-check.json
```

These call only the free public `/requests/check` endpoint. Put each complete record under
`templates.checks[<action>]`. The tool binds each response to the canonical parsed body SHA-256
and requires an explicit empty `blockers` array. Owner `templateApproval` is
`{"sha256": <SHA-256 of canonical templates object>, "reference": <approval record>}`; canonical
encoding is `sdk.deployment.canonical` (sorted keys, compact UTF-8 JSON). Changed fragments,
body/chain/panel mismatches, stale/blocked checks or a mismatched approval refuse activation.
A check validates only its supplied sample, not every future brief, job ID or service revision.
Recheck actual bodies, pricing and service availability before each separately approved purchase.

This bundle gate deliberately leaves paid activation unresolved until public evidence exists.
An operator may first obtain the job through an approved external workflow, then approve a
complete requester template bundle; this assignment does not acquire or pay for such evidence.
For ongoing operation, the approved template is still dynamic and must be checked against each
actual body. Do not use the local mock checker responses as live approvals.

A real pilot is a separately authorized, small-budget run on **Ethereum or Robinhood Chain**:
verify exact debit/spend and caller price cap; registered job selector `0x325a77b4`; asynchronous
writer routing; result document hash and available URI; failure callback/fee-loss behavior; a
fresh signed review in the requester's EIP-712 domain; independent Intake-to-oracle UUID mapping
and canonical question/window; owner `bindReview`; exact receipt/history and final verdict.
The [existing binding and incident procedures](IMD_INTEGRATION.md) remain mandatory operational
responsibilities. Do not infer that a callback's signed UUID authenticates its own Intake pairing.
The owner controls current Intake/signer even for pending work; disclose those powers to users.
No service-level success or paid review is claimed by this package.

## URI gas and display pilot checks

The onchain URI remains unbounded and event-only. Local pinned-solc/Cancun/optimizer-200,
cold clean Open-job tests under exactly 200,000 forwarded gas delivered **20,224 bytes** and
failed at **20,256 bytes**, consuming the mock Intake's sole attempt and retaining its fee.
The measured 4,096-byte URI costs 67,052 minimum forwarded gas. These are **fixture measurements,
not a universal safe maximum**, and the site's 32 KiB decode limit is not a callback gas budget.
Require short writer-produced URIs with ample headroom and measure the actual cold production
path, URI bytes, signer and signature at pilot time. Requalify after any implementation,
signer, chain gas schedule or writer change. Do not target the measured boundary.

Current [callback docs](https://imd.fun/docs/#intake-what-comes-back) say 200,000 gas for production
and 1,000,000 on Sepolia. The imported reference predates that Sepolia distinction. This package
keeps all conservative 200k tests; a Sepolia-only success cannot qualify a production callback.

Display escaping is a reader change only. Both pages visibly escape Unicode controls, format
and default-ignorable characters (including bidi controls/zero-width/BOM), plus line/paragraph
separators, as `\u{HEX}`. Valid accented text and ordinary emoji remain readable. URI decoding
preserves bytes, including a leading BOM, before rendering; hashing must use original bytes,
never the escaped display. URIs stay unverified text, with no links or content fetching.

## Work required beyond this assignment

For **production BoundedSwapHook deployment**, separately review a new factory release whose
`DeploymentPolicy` supports the selected production chain; update and test the related factory,
shared deployment helper, scripts, SDK and UI policy gates together. Verify the target Uniswap
v4 PoolManager's first-party identity and exact implementation/code hash, Cancun compatibility,
permissions and integration behavior on that chain. Rebuild/review the new factory and remine
salts against its actual address; a different factory changes CREATE2 addresses. Retain bytecode,
constructor/source verification and tests with new pools in a separate authorized environment.
The existing hook template itself is not mainnet-gated and need not change solely for this
policy upgrade. A direct deployment bypassing this factory is not a verified Store deployment.

For **generated-hook deployment**, first design and independently review a new deployment
interface and spec/template policy. Current HookSpec v1, factory, miner and SDK accept only the
fixed BoundedSwapHook template and callback mask `0x10c0`; a paid job's result document is not
executable deployment authorization. The additional work includes binding generated source,
compiler/dependencies, constructor ABI, creation/runtime bytecode and review evidence by hash;
validating each hook's actual callback mask and constructor dependencies; permission-correct
CREATE2 mining for that exact initcode; factory registration/verification for additional approved
templates or a deliberately reviewed general-bytecode path; and matching SDK, ABI, UI and
readback support (including immutable substitutions). Define who approves templates/bytecode,
what an independent review means, and how a verdict is tied to the exact artifact, rather than
trusting a user URL or an unrelated `Passed` status. Add success, failure, malicious-constructor,
wrong-mask, collision, code-hash and multi-pool integration tests and review this new trust surface.
Production rollout also needs the chain work above. None of these contract changes is implemented
here, and no hook, pool or token is automatically deployed from an IMD result.

## Evidence and remaining operator inputs

[Command logs and observations](checks/deployment-preparation/README.md) distinguish local
Foundry/Anvil tests from public HTTP/RPC reads. `audited-build.json` captures the original source
and compiler configuration plus creation/runtime-template SHA-256 for all five application
contracts. `verify-build` compares them after the changes. Requester runtime stays 24,117 bytes,
459 below EIP-170. No new audit claim is made.

Still required: approved owner and control model; final approval of the proposed ad recipient;
choice of paid-pilot chain, RPC/finality and budget; current protocol/signer qualification;
accepted templates and real job/mapping evidence; actual deployment addresses/receipts and,
if using IMD, launcher acceptance of the separate owner-configuration handoff. A PoolManager
address and code hash are needed only for a future supported hook deployment, not for registry,
ads or requester deployment. No credentials are requested or stored by these tools.

## Approval-binding fixes after the preparation baseline

`deployment/audited-build.json` remains immutable historical evidence for its old source commit.
The current source intentionally changes HookJobRequester and GatedHookDeployer. Tools now compare
`deployment/current-build.json`, refreshed by `python3 script/update_build_evidence.py` after a build.
These fingerprints assert build identity, **not an audit**; the tool reports `auditStatus: not-audited`.
Those historical runtime measurements are superseded by [the consolidated results](checks/consolidated/README.md), with the compiler configuration still unchanged.
The existing manager/owner configuration responsibilities remain. See
[GATED_DEPLOYMENT.md](GATED_DEPLOYMENT.md) for accepted-snapshot evidence, revocation in both callback
orders, actual-schema templates, free-checker evidence and the disabled automatic binding route.
