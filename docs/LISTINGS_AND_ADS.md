# Listings and featured advertising

This release adds `HookListingRegistry` and `FeaturedPlacements` beside the existing factory and
`HookJobRequester`. It makes no calls to the Intake, changes none of its integration, and does not
deploy hooks, tokens or pools. Contracts and tests run locally; no public deployment, funded
transaction, live IMD integration or hosted service is claimed.

## Free listings and the meaning of a claim

`createListing(chainId, hook, metadata)` is permissionless and nonpayable. There is no platform fee
to create, edit, archive, restore or transfer a listing; ordinary network gas still applies. Its
owner is the creating wallet, not the factory, hook admin or an inferred contract owner.

The chain ID and hook address are immutable. The registry can describe another chain, so it does
not call that hook or assert that code exists. One listing is allowed per `(chainId, hook, owner)`;
other wallets can independently describe the same hook. This prevents the first submitter from
globally excluding a legitimate developer. Listings are claims, not canonical ownership records.
Same-owner duplicates are rejected even when archived. Transfer checks this uniqueness again at
acceptance. A corrected chain/address requires a new listing.

Metadata includes a name, source/test/review/audit references, a declared 14-bit v4 callback mask,
callback behavior disclosure, fee disclosure, admin disclosure, and up to 16 searchable labels.
Each disclosure must be present; use an honest explicit description such as `unknown` when needed.
References may be empty, meaning no evidence supplied. The mask and text are owner declarations;
they are not automatically checked against address bits, deployed bytecode or privileged accounts.

The name is limited to 96 bytes, each reference to 512 bytes, each disclosure to 1,024 bytes, and
each unique label to 1–32 bytes of lowercase ASCII letters, digits or hyphens. Empty label lists
are allowed. Limits bound storage and read costs; they do not make text trustworthy. Render strings
as text, never HTML, scripts or instructions. Reference contents are not fetched by the contracts.
Use immutable source commits, test artifacts and content-addressed review reports where possible.
An off-chain renderer must apply its own safe-link policy and treat all links as untrusted.

Every edit appends a full immutable metadata revision. `getMetadata(id, revision)` returns the
historical content. `getListing(id)` returns its current owner, pending transfer, revision,
visibility, chain and hook. `MetadataUpdated` commits `keccak256(abi.encode(metadata))`.
`LabelSet` removal/addition events and `hasLabel(id, hash)` reflect only the current revision.
Archiving preserves records and hides them from organic search and new ad purchases.

**A supplied audit URL never makes a hook audited.** `isAudited(id)` returns false for every known
listing. This release intentionally has no audit badge issuer or badge setter. Even a label named
`audited` is user text. Display `Audit reference (unverified)` and distinguish it from an actual
independent audit. Existing Intake review status belongs to the specific job and its original
contract; neither a URL nor a copied request ID proves that a deployed hook is the reviewed code.
No automatic cross-contract audit status is introduced.

Listing transfers are two-step: the owner calls `proposeListingOwner`, the proposed wallet calls
`acceptListingOwnership`. The current owner can replace or cancel the proposal. They retain edit
rights until acceptance. Buyers of a listing should check the latest revision before accepting.

## Exact placement terms

| Term | Enforced behavior |
|---|---|
| Price | Exactly **0.1 IMD**, `100000000000000000` base units of a reviewed 18-decimal token |
| Duration | Exactly **7 days / 604800 seconds**, fixed at purchase |
| Start/end | Immediate, active on `[startsAt, endsAt)` by the chain's timestamp |
| Disclosure | Every placement and purchase event carries `bytes3("#ad")`; render **#ad** visibly on every paid card |
| Ordering | Ascending purchase ID, oldest first, with transaction order breaking same-block ties |
| Capacity | Concurrent placements, no auction, scarce slot, queue, cap or future scheduling |
| Eligibility | Current owner of an active listing, with enough of their own deposited credit |
| Duplicates | At most one live placement per listing; distinct claims can advertise the same hook |
| Renewal | A new purchase after cancellation or expiry; fresh ID and seven-day period, no auto-renewal |
| Commitment | Purchase pins listing revision, payer and proceeds recipient; immutable price/duration |
| Cancellation | Original payer or current listing owner, any time strictly before expiry; a proposed owner has no right until acceptance |
| Refund | `PRICE - floor(PRICE * elapsedSeconds / DURATION)`, credited to the original payer |
| Final settlement | Anyone calls `settle(id)` at/after expiry; all 0.1 IMD becomes the pinned recipient's proceeds |

At the purchase timestamp a cancellation refunds the full 0.1 IMD. At 3.5 days it refunds 0.05
IMD; at the final second it refunds the remaining fraction. Rounding favors the payer by less than
one base unit. At the exact end cancellation reverts; settlement earns the full fee. Repeated
cancellation or settlement reverts. Unused credit is never spent by anyone else's purchase.

`purchase(listingId, expectedRevision, expectedRecipient, deadline)` prevents a changed revision
or recipient from silently changing reviewed purchase terms. The caller must set a useful deadline
and confirm the current values before approving. No additional fee or bid can improve ranking.
Block producers can reorder purchases, and free listing creation allows spam; there is no claim
of fair transaction ordering, Sybil resistance, guaranteed clicks, impressions or placement on a
third-party website. Buying an ad never changes organic search or audit status.

An ad displays **its purchased metadata revision and its original payer**, including if the listing
is later edited, transferred or archived. Changes cannot replace an already paid message. To remove
an ad, its payer or current listing owner must cancel it separately. After accepting a listing
transfer, a buyer can call `cancel(oldPlacementId)` to clear the seller's live placement, then buy
a new one using their own deposit and the current listing revision. **The entire pro-rata refund
still credits the original payer**, never the cancelling buyer or the admin. The original payer
keeps their cancellation right after transfer/archive. A proposed owner cannot cancel before
accepting, and an intermediate owner loses that right on a later transfer unless they paid for
the placement. A transfer alone does not cancel an ad; it can remain visible until either
permitted caller cancels or it expires. Buyers should inspect `latestPlacement` and the pinned
revision/payer before acceptance. Existing ads expire even without a keeper; `settle` only releases accounting balances.
An expired but unsettled placement does not block a new purchase or later settlement of the old one.

## Custody, withdrawals and conservation

Approve the ads contract for the desired deposit and call `deposit(amount)` from the owning wallet.
The deposit credits only `msg.sender`. Use `withdraw(amount, to)` for unused balances and refunds;
only that wallet can debit them, and it may choose a nonzero receiving address other than the escrow.
Listing archive/transfer, recipient changes, and missing recipient configuration cannot block this.

Buying a placement moves 0.1 IMD from `available[payer]` to `totalEscrowed`. A cancellation moves
the refund to `available[payer]` and the elapsed charge to `proceeds[pinnedRecipient]`. Expiry
settlement moves the entire fee to that recipient's proceeds. Only the recipient can call
`withdrawProceeds(amount, to)` against its own earned credit. A recipient rotation cannot redirect
prior bookings or old earned balances. Admins cannot prematurely claim locked fees.

At all times after completed transactions:

```text
accountedBalance = totalAvailable + totalEscrowed + totalProceeds
IMD.balanceOf(ads) >= accountedBalance
```

The equality is exact unless someone transfers tokens directly to the contract. Direct transfers
are not deposits and cannot be attributed safely; they receive no credit and are irrecoverable.
There is **no sweep**, arbitrary token call, approval to the Intake, native-currency handling,
proxy, upgrade, pause, confiscation or emergency withdrawal function. Forced ETH and unsupported
tokens are also irrecoverable. Use `deposit`, not a bare transfer.

Token operations accept a true return or no return. Missing code, false, malformed return data,
inexact debit/credit and transfer taxes revert atomically. Reentrancy guards cover all custody
mutations, and withdrawal debits precede token calls. A failing token transfer preserves the
withdrawable credit for retry. Cancellation and settlement make no token or recipient calls, so
a blocked recipient cannot block refunds becoming credit. Token pauses, blacklists, confiscation,
negative rebases, dishonest balance reporting or token upgrades can still make withdrawal fail;
the configured token and its control plane must be independently reviewed. Transfer checks alone
cannot establish token identity or prevent arbitrary future token behavior.

## Contract reads and indexing

Start cursors at 1. Both paginated methods scan **at most** 100 consecutive IDs, not 100 matching
results, so an empty page can have later matches. Continue with `nextCursor` while it is at most
the relevant count. A cursor of `count + 1` returns an empty final page. Zero, out-of-range cursors,
zero scan size and sizes above 100 revert. Use a fixed block for a multi-page snapshot.

| Read | Purpose |
|---|---|
| `search(cursor, scanLimit, chainId, owner, labelHash)` | Current active organic IDs, ascending; zero filters mean any value |
| `labelKey(label)` | Exact `keccak256(bytes(label))` for the normalized label |
| `getListing(id)` / `getMetadata(id, revision)` | Header and chosen metadata revision |
| `featured(cursor, scanLimit)` | Active purchased snapshots in ascending ID order, each carrying #ad |
| `cancel(id)` | Original payer or current listing owner removes an unexpired ad; refund credits only the original payer |
| `getPlacement(id)` / `isActive(id)` | Historical record / time-aware visibility; unknown IDs are inactive |
| `available(account)` / `proceeds(account)` | Independently owned withdrawal balances |

For large histories, index emitted IDs and timestamps off chain rather than repeatedly scanning
from 1. Readers must filter the exact deployed contract, handle confirmations and reorgs, and
discard expired cards as the chain advances. `Status.Open` alone does not imply active: an expired
ad remains Open until someone settles it. Render the advertised revision, not the current one.
The static [listing reader](../site/listings.html) demonstrates these reads without signing or
fund submission, labels each ad visibly, and shows all references as unverified text.

## Deployment parameters and proposed recipient

No address is guessed or embedded. The future deployer creates `HookListingRegistry()` and then
`FeaturedPlacements(owner_, registry_)`. The launch owner is an explicit constructor argument
(the launch's `$owner` when populated by its separate manifest process), never `msg.sender` or
`tx.origin`. `registry_` is the newly deployed, reviewed registry on the same settlement chain.
The ads constructor does not call it or require code, allowing factory construction on an empty
chain. Verify its bytecode and binding before configuring the token or accepting deposits.

**Proposed proceeds recipient: the Hooks Store project's treasury, controlled by a
requester-approved multisig. Its exact address and signers remain subject to final requester
approval before live use.** No IdentityMD service, Intake, token, operator or guessed address is
substituted for that decision. The recipient begins unset and purchases fail clearly until the
owner configures it. The owner-settable path lets this source-only assignment finish without
blocking on a future launch choice.

The ads token also begins unset. The future operator obtains the approved IMD address for the
chosen settlement chain, verifies identity, code, decimals and behavior, then configures it once.
The pinned input lists IMD candidates for Ethereum and Robinhood Chain, but this job has not
verified a live address. Base has no approved payment asset supplied here. Do not substitute a
lookalike ERC-20 or create a token. Cross-chain listing support does not bridge payments or make
IMD available on another network. These new contracts are chain-agnostic; existing factory
deployment policy remains as documented. All public-chain use remains untested.

## After launch

| Setting / action | Authority and source of value |
|---|---|
| `configureToken(token)` | Ads owner, once only. Verified IMD address from approved target-chain configuration; requires code, balance ABI and 18 decimals. Irreversible; review before calling. |
| `setProceedsRecipient(recipient)` | Ads owner. Exact treasury address from final requester approval; affects future purchases only and emits previous/new values. |
| `transferOwnership(newOwner)` then `acceptOwnership()` | Current owner proposes; new owner accepts. Use the requester-approved operational multisig. Existing owner may replace/cancel the proposal. |
| `settle(id)` | Anyone, usually the proceeds recipient's operator, after expiry. No paid keeper is built in. |
| `withdrawProceeds(amount, to)` | Each pinned proceeds recipient, only against its earned credit. Monitor old recipients after rotation. |

`configureToken` cannot be undone even if no deposit exists. This protects future liabilities from
asset substitution; a wrong initial setting requires a new reviewed ads contract. Constructor
arguments are just owner and registry, well below the launch limit; libraries are internal only.
No launch manifest or broadcast script is added in this assignment.

## Complete account of administrative powers

* **Registry:** no global admin, moderation, forced transfer, fee setting, deletion or badge authority.
  Only a listing's owner edits its metadata/visibility and proposes ownership transfer.
* **Ads owner:** one-time token configuration, future proceeds recipient changes, two-step admin
  rotation. No price/duration/ranking changes, forced cancellation, user-balance access, asset
  migration, sweep, pause or upgrade.
* **Depositor/payer:** can spend only their available credit on their own active listing; withdraw
  their unused credit and refunds; cancel their own unexpired purchases. A current listing owner
  may also cancel a previous owner's placement, but cannot receive or withdraw its refund.
* **Recipient:** can withdraw only their own earned proceeds, including from before a rotation.
* **Anyone:** can create a claim, read history, and settle expired placements.

The existing `HookJobRequester` has its separately documented owner powers, including recovery of
mistaken transfers into that requester. Those powers do not apply to the new escrow, and the
escrow never approves the requester or Intake to spend deposited IMD.

Operators remain responsible for safe display and link handling, abuse filtering in their own UI,
ad disclosure on every card, immutable evidence retention, RPC trust, reorgs, gas costs, treasury
operation, IMD compatibility and incident response. Organic moderation is an off-chain presentation
policy and must not be confused with an on-chain audit badge. Refunds meter purchased on-chain
time, not website uptime. Independent adversarial review by another contributor is required before
holding real users' funds; these local tests and this contributor's review are not that audit.
