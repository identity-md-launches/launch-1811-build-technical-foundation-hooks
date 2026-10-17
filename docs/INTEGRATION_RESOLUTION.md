# Integration decision, 2026-10-17

**Automatic binding remains disabled. No founder-free or launch-ready flow is claimed.**
The fixes in this revision do not introduce a backend, hot wallet, new trusted signer, or routine
founder transaction. The existing owner-binding functions remain available for compatibility and
local/manual demonstrations; they are an explicit owner assertion, not the requested protocol proof.

## First-party protocol and deployed contract evidence

The current [IMD callback documentation](https://imd.fun/docs/#intake-what-a-callback-proves)
explains that the writer can mispair an answer. The [completion interface](https://imd.fun/docs/#intake-what-comes-back)
uses two different namespaces: the callback's Intake ID and the signed oracle UUID. This is confirmed
by the [captured public request record](https://api.imd.fun/intake/1/0xf85bae3821dd11be1146fd631df7ec601c5d47e02b00a7c8dc3bf28149455665):

| Record | Value |
|---|---|
| Ethereum Intake v2 | `0xa43e6f75ee006411f79ac1c84120606c2330de82` |
| Observed block | `0x18ffb7e` |
| Intake ID, log index 55 | `0x2a2a72a13996058695e187dfd43bcee41682f8a6592b04b23bae308fca2784e1` |
| HTTP admission's oracle UUID | `76587543-d7e6-471e-a01f-63e9e0dfc6e7` |
| Signed question hash | `0xf4df38bb41d635b3de83f4215612d83e25696f6a40fc040f9de053baba7029df` |
| Oracle domain consumer | `0x77e1684402869bf2b7c70b8bf21e1c7ca7104951` |

The [public attestation](https://api.imd.fun/oracle/requests/76587543-d7e6-471e-a01f-63e9e0dfc6e7/attestation)
is a different consumer's **uint256 price answer**, not a Hooks Store review. Its signature is verified
offline by `test/LiveOracleVector.t.sol`, without creating a signature. This demonstrates the real v2
format only. It does not authenticate the HTTP admission pairing or the question document's preimage.

The deployed [verified Intake source/ABI](https://eth.blockscout.com/api/v2/smart-contracts/0xa43e6f75ee006411f79ac1c84120606c2330de82)
was compared byte-for-byte with `eth_getCode` at the observed block; they match. Its
`requests(bytes32)` getter exposes payer, callback target, callback selector, and completed status.
It has no oracle UUID, question hash, body-to-question commitment, or proof verifier.
`request` emits the body and computes the ID from chain, Intake address and nonce. `complete` takes
writer-supplied success arguments, emits completion, and forwards those arguments once. Checking
that this writer called Intake does not authenticate the signed answer's association with the ask.
The observed `callbackGas()` is 200,000. Full evidence and retrieval scripts are in
[checks/consolidated](checks/consolidated/README.md).

## Worker input trace

| Required value | Available source and actual limitation |
|---|---|
| Full HookSpec | `openJob` receives only `specHash` and a bounded text brief. A hash cannot reconstruct the spec. No full-spec input is currently declared by the shipped template. IMD supports accepted named files in `inputs`, delivered under `.imd/reads/artifacts/<name>`; an actual job must supply the complete spec that way, or in its authenticated body, and check its ABI hash against `JobOpened.specHash`. This delivery has **not** been demonstrated. |
| Originating Intake ID | The returned ID is stored and emitted by `HookJobRequester.JobOpened`; the same transaction contains Intake `Requested`. It is generated after the body is fixed and is absent from that body. `GET /intake/:chain/:tx` connects it to the control-plane job UUID, but this HTTP relation is unsigned. Guessing the next nonce, matching identical body hashes, or copying a worker claim is not an authenticated reverse mapping. |
| Chain and requester | Confirmed transaction/log identity plus the actual requester address and configured Intake. An oracle's question chain and EIP-712 consumer chain are separate fields, even if a deployment uses the same chain for both. |
| Gated deployer | Must be an explicit, real deployment input. The requester has no deployer setting; a worker cannot derive it from `specHash`. Check the deployer's immutable `requester()` on the intended chain. No placeholder address is provided for launch. |
| PoolManager/code hash | The complete HookSpec, deployer manager policy, and `eth_getCode` at an identified block. Production pins remain unchanged. Enablement requires the real code hash; never infer a manager from the untrusted brief. |
| Reviewed source | The exact earlier accepted source bundle and its `submissionHash`, before the evidence publication step. Rehash the retrieved bytes with SHA-256. The current completed project record has one source entry and no named files. |
| Exact accepted review | The accepted adversarial-review submission and report in job/submission records. This is distinct from the oracle panel job and from the publication worker. The live audit result has `source: []`; therefore this revision does **not invent** a review entry in `source[]`. The oracle must verify acceptance and findings for the committed `reviewSubmissionHash`. |
| Reviewed build | Reproduce the selected source with the pinned compiler/dependencies/settings and exact target. Hash a build identity file, creation code, ABI constructor bytes and final runtime (including immutables). Commit them in ArtifactV2 and its canonical evidence file. Reproduction and review correctness are claims checked by the oracle, not facts established by a JSON parser. |

The template now states these inputs explicitly and tells the publication worker to withhold the
publication if any is missing. This is honest failure behavior, **not** a complete input-delivery
implementation. A real accepted input package and authenticated origin context are launch blockers.
No public lookup is promoted into onchain authentication.

## Missing protocol primitive

A usable primitive would be a protocol-signed, domain-separated commitment (by the existing oracle
trust root), or an equivalently authenticated onchain record/proof, relating:

- consumer chain/address and originating Intake chain/address/request ID;
- the exact submitted body hash and oracle UUID;
- the canonical question preimage/hash, including resolved window, definitions and question chain;
- the job/result/artifact that this question authorizes, including exact source/review/build evidence.

The consumer must verify that commitment against its stored pending ask and consume the identity
once. The protocol also needs a specified, reproducible question canonicalization and worker origin
context. None is present in the inspected deployed ABI, official consumer reference, typed signature,
or public records. A signed answer's own questionHash cannot authenticate its unsigned preimage.
Adding an owner allowlist, copying the receipt, trusting HTTPS alone, or trusting the writer's
`Completed` event would change the trust model and does not supply this primitive.

Accordingly `automaticBindingSupported()` is constant false, and the SDK refuses its default automatic
mode before any RPC. Explicit `owner-confirmed` mode remains a **manual trust assumption**, useful for
local proofs, not a proposed routine-founder production solution.

## Release blockers

1. Protocol-verifiable request/question/artifact binding and canonicalization as above.
2. Demonstrated delivery of the complete HookSpec, real deployment context, authenticated origin and
   reviewed source/build to workers; successful publication of both named v2 files.
3. A real four-step completion snapshot, byte-identical to its recorded Intake `resultHash`, within
   this parser's measured limits. `/jobs/:id/result` can evolve; use the original completion URI or
   `/intake-results/:id`, never JSON reserialization.
4. A real **Hooks Store** review under the intended domain/signer, with confirmed delivery under the
   live stipend and the intended panel behavior. The captured price attestation is not this pilot.
5. Independent adversarial review of these changes, final deployment/owner/recipient choices and
   operational handoff. No transaction, paid request, token/pool creation or deployment was performed.

These are protocol/integration limitations, not a request for a key or permission to transact.
