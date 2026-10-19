# Audit report

> Audit commit 205fa11271ab17a26630154815fae4c390aac624. Focus on AutoHookJobRequester, HookRequestCodec and their GatedHookDeployer integration, not just the legacy manual requester. Check exact question/ArtifactV2 authorization; confirmed native-chain windows, including Robinhood ArbSys; premature reserve spending; refunds/retries and NotPassed shopping; signer revocation/recovery; replay/reentrancy; and one-shot callbacks within 200k gas. Preserve the 24576-byte runtime limit and pinned compiler. Reproduce material findings with tests. Distinguish code defects from unproven live integration; local tests and free checks are not a paid end-to-end proof. Audit/report only: no fixes, deployment, live signatures or payments.

| | |
|---|---|
| Repository | https://github.com/identity-md-launches/launch-1811-build-technical-foundation-hooks.git |
| Commit | `205fa11271ab17a26630154815fae4c390aac624` |
| Job | `2218802d-0828-4f00-81cf-487b51c12aac` |
| Judged | 2026-10-19 00:28 UTC |
| Findings | 2 medium · 2 low · 1 info |

Four agents audited the code as it is at `205fa11`, each in one area (math, permissions, economics, control flow),
and a judge reproduced, merged and ranked what they found, then read the code once more itself. Nothing in the repository was changed or deployed.

## Findings

### 1. Medium: Verdict reserve deadline fixed at job open: a build delivered late (or after expiry) can never be reviewed; retry windows can also lapse into a dead end

`src/imd/automatic/AutoHookJobRequester.sol:310`

```
|| block.timestamp > p.reserveDeadline || j.status != HookJobRequester.JobStatus.Delivered
```

openJob sets reserveDeadline = openedAt + JOB_TIMEOUT; nothing moves it on delivery/commit. verdictReadiness requires block.timestamp <= reserveDeadline and review == None, while _jobCallback accepts deliveries for Open or Expired jobs. retryVerdict needs review == Unanswered, so a delivered-and-committed job whose deadline passes before the 8-block window matures (or which was delivered after expiry) has no route to a verdict; only cancelReserve remains, so the build fee buys a hook that can never pass GatedHookDeployer. Same dead end after retryVerdict if its 1-day window lapses untriggered (review reset to None). Merges audit_flow ec6c2371 and audit_economics 9bcbce14. Fix: extend reserveDeadline to max(reserveDeadline, now + REVIEW_TIMEOUT) in onJobResult/commitArtifact, or let the requester re-fund a stranded None ask.

**Reproduction**

openJob at T; onJobResult at T+7d-60s (Delivered); commitArtifact; roll 8 blocks, warp +96s. Expected verdictReadiness.ready == true; actual false, requestVerdict reverts NotReady, retryVerdict reverts NotReady. Supplied proof run: forge test --match-path test/scratch/Proof_ec6c2371f44e.t.sol fails with "delivered, committed, matured ask can never become ready".

**Proof**: a Foundry test that fails on this code and passes once it is fixed.

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {AutoHookJobRequester} from "src/imd/automatic/AutoHookJobRequester.sol";
import {HookRequestCodec} from "src/imd/automatic/HookRequestCodec.sol";
import {HookJobRequester} from "src/imd/HookJobRequester.sol";
import {IIntake} from "src/imd/IIntake.sol";
import {GatedHookDeployer} from "src/deployment/GatedHookDeployer.sol";
import {HookSpec, HookSpecLib} from "src/HookSpec.sol";

contract LateTok {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }

    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[to] += a;
        return true;
    }
}

contract LateIntake {
    uint256 public constant PRICE = 0.5 ether;
    uint256 private n;
    mapping(bytes32 => address) public target;
    mapping(bytes32 => bytes4) public sel;

    function priceOf(bytes32, address) external pure returns (uint256) {
        return PRICE;
    }

    function requestWithFailure(
        bytes32,
        bytes calldata,
        IIntake.Callback calldata cb,
        bytes4,
        address asset,
        uint256 amount
    ) external returns (bytes32 id) {
        LateTok(asset).transferFrom(msg.sender, address(this), amount);
        id = keccak256(abi.encode(address(this), ++n));
        target[id] = cb.target;
        sel[id] = cb.selector;
    }

    function complete(bytes32 id, bytes calldata args) external returns (bool ok) {
        (ok,) = target[id].call{gas: 200_000}(bytes.concat(sel[id], args));
    }
}

contract LateDeliveryVerdictTest is Test {
    AutoHookJobRequester auto_;
    GatedHookDeployer gated;
    LateIntake intake;
    LateTok tok;
    HookSpec spec;
    address creator = makeAddr("creator");
    address outsider = makeAddr("outsider");

    function setUp() public {
        vm.chainId(31337);
        vm.warp(1_800_000_000);
        vm.roll(1000);
        intake = new LateIntake();
        tok = new LateTok();
        HookRequestCodec codec = new HookRequestCodec();
        auto_ = new AutoHookJobRequester(address(this), address(intake), address(tok), address(0xA11CE), 1 ether, codec);
        gated = new GatedHookDeployer(address(this), HookJobRequester(address(auto_)));
        spec = HookSpec({
            schemaVersion: 1,
            templateId: HookSpecLib.TEMPLATE_ID,
            chainId: block.chainid,
            poolManager: address(0xBEEF),
            poolManagerCodeHash: keccak256("manager runtime"),
            permissions: HookSpecLib.PERMISSIONS,
            maxSpecifiedAmount: 1_000_000
        });
        tok.mint(creator, 10 ether);
        vm.prank(creator);
        tok.approve(address(auto_), 10 ether);
    }

    function _artifact(bytes32 id) internal view returns (GatedHookDeployer.Artifact memory a) {
        a = GatedHookDeployer.Artifact({
            jobRequestId: id,
            sourceHash: sha256("src"),
            sourceSubmissionHash: sha256("source submission"),
            reviewSubmissionHash: sha256("review submission"),
            evidenceHash: bytes32(0),
            buildHash: keccak256("build"),
            creationCodeHash: keccak256("creation"),
            constructorArgsHash: keccak256("args"),
            runtimeCodeHash: keccak256("runtime"),
            chainId: block.chainid,
            deployer: address(gated),
            poolManager: spec.poolManager,
            poolManagerCodeHash: spec.poolManagerCodeHash,
            permissions: spec.permissions
        });
        a.evidenceHash = sha256(gated.evidenceDocument(a));
    }

    /// A build delivered (in time, job still Open) shortly before the 7-day job deadline, then
    /// committed and matured by the 8-block window, must still be able to obtain a verdict.
    function testDeliveredBeforeJobDeadlineCanStillRequestVerdict() public {
        vm.prank(creator);
        (bytes32 jobId, bytes32 askId) = auto_.openJob(spec, address(gated), "hook", 0.5 ether, 0.5 ether);
        uint64 deadline = auto_.getJob(jobId).deadline;

        // Intake delivers 60 seconds before the job deadline; the job is not expired.
        vm.warp(deadline - 60);
        assertTrue(intake.complete(jobId, abi.encode(jobId, keccak256("completion"), "ipfs://r")));
        assertEq(uint8(auto_.getJob(jobId).status), uint8(HookJobRequester.JobStatus.Delivered));

        // Requester commits the reviewed artifact from the delivered publication right away.
        GatedHookDeployer.Artifact memory a = _artifact(jobId);
        vm.prank(creator);
        auto_.commitArtifact(jobId, a, bytes20(keccak256("commit")));

        // Earliest possible trigger: eight native blocks (12 s each on Ethereum) later.
        vm.roll(block.number + 8);
        vm.warp(block.timestamp + 96);
        (bool ready,,,) = auto_.verdictReadiness(askId);
        assertTrue(ready, "delivered, committed, matured ask can never become ready");

        vm.prank(outsider);
        auto_.requestVerdict(askId);
    }
}
```

### 2. Medium: One-shot onReviewResult rejects issuedAt even 1s ahead of block.timestamp and any delivery >1h after issuance, losing a paid verdict

`src/imd/automatic/AutoHookJobRequester.sol:361`

```
|| att.issuedAt < a.askedAt || att.issuedAt > block.timestamp || att.issuedAt > att.expiresAt
```

The base OracleAttestationConsumer tolerates ISSUED_AT_TOLERANCE (5 min) of attester clock skew, but AutoHookJobRequester adds a zero-tolerance issuedAt > block.timestamp check and MAX_ANSWER_AGE = 1h (vs signed 24h expiry). The Intake attempts the callback once with 200k gas; a revert leaves review Pending with the reserve spent, retryVerdict/cancelReserve unavailable, and recovery only via owner confirmReviewExpiry after 1 day plus a second reserve. Merges audit_permissions f0863070 and audit_economics 03b1f5e7. Fix: allow issuedAt <= block.timestamp + ISSUED_AT_TOLERANCE and bound age by expiresAt (or a larger MAX_ANSWER_AGE).

**Reproduction**

Open, deliver, commit, roll 8, requestVerdict. A correctly signed true attestation with exact window, panel 7/5/5, issuedAt = now is accepted (testControl passes). Same with issuedAt = now+1: reverts InvalidWindow (testIssuedAtOneSecondAheadLost fails). issuedAt = now delivered at now+3601 with expiresAt = now+1d: reverts InvalidWindow (testDeliveredAfterOneHourLost fails). Run: forge test --match-path on the proof.

**Proof**: a Foundry test that fails on this code and passes once it is fixed.

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {AutoHookJobRequester} from "src/imd/automatic/AutoHookJobRequester.sol";
import {HookRequestCodec} from "src/imd/automatic/HookRequestCodec.sol";
import {HookJobRequester} from "src/imd/HookJobRequester.sol";
import {IIntake} from "src/imd/IIntake.sol";
import {GatedHookDeployer} from "src/deployment/GatedHookDeployer.sol";
import {OracleAttestation} from "src/imd/OracleAttestation.sol";
import {HookSpec, HookSpecLib} from "src/HookSpec.sol";

contract LateTok {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }

    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[to] += a;
        return true;
    }
}

contract LateIntake {
    uint256 public constant PRICE = 0.5 ether;
    uint256 private n;
    mapping(bytes32 => address) public target;
    mapping(bytes32 => bytes4) public sel;

    function priceOf(bytes32, address) external pure returns (uint256) {
        return PRICE;
    }

    function requestWithFailure(
        bytes32,
        bytes calldata,
        IIntake.Callback calldata cb,
        bytes4,
        address asset,
        uint256 amount
    ) external returns (bytes32 id) {
        LateTok(asset).transferFrom(msg.sender, address(this), amount);
        id = keccak256(abi.encode(address(this), ++n));
        target[id] = cb.target;
        sel[id] = cb.selector;
    }

    function complete(bytes32 id, bytes calldata args) external returns (bool ok) {
        (ok,) = target[id].call{gas: 200_000}(bytes.concat(sel[id], args));
    }
}

contract SkewTest is Test {
    AutoHookJobRequester auto_;
    GatedHookDeployer gated;
    LateIntake intake;
    LateTok tok;
    HookSpec spec;
    address creator = makeAddr("creator");
    address outsider = makeAddr("outsider");

    function setUp() public {
        vm.chainId(31337);
        vm.warp(1_800_000_000);
        vm.roll(1000);
        intake = new LateIntake();
        tok = new LateTok();
        HookRequestCodec codec = new HookRequestCodec();
        auto_ = new AutoHookJobRequester(address(this), address(intake), address(tok), address(0xA11CE), 1 ether, codec);
        gated = new GatedHookDeployer(address(this), HookJobRequester(address(auto_)));
        spec = HookSpec({
            schemaVersion: 1,
            templateId: HookSpecLib.TEMPLATE_ID,
            chainId: block.chainid,
            poolManager: address(0xBEEF),
            poolManagerCodeHash: keccak256("manager runtime"),
            permissions: HookSpecLib.PERMISSIONS,
            maxSpecifiedAmount: 1_000_000
        });
        tok.mint(creator, 10 ether);
        vm.prank(creator);
        tok.approve(address(auto_), 10 ether);
    }

    function _artifact(bytes32 id) internal view returns (GatedHookDeployer.Artifact memory a) {
        a = GatedHookDeployer.Artifact({
            jobRequestId: id,
            sourceHash: sha256("src"),
            sourceSubmissionHash: sha256("source submission"),
            reviewSubmissionHash: sha256("review submission"),
            evidenceHash: bytes32(0),
            buildHash: keccak256("build"),
            creationCodeHash: keccak256("creation"),
            constructorArgsHash: keccak256("args"),
            runtimeCodeHash: keccak256("runtime"),
            chainId: block.chainid,
            deployer: address(gated),
            poolManager: spec.poolManager,
            poolManagerCodeHash: spec.poolManagerCodeHash,
            permissions: spec.permissions
        });
        a.evidenceHash = sha256(gated.evidenceDocument(a));
    }


    uint256 pk = 0xB0B;
    uint64 f0; uint64 t0;
    function _ready() internal returns (bytes32 askId, bytes32 vid) {
        auto_.setOracleSigner(vm.addr(pk));
        vm.prank(creator);
        bytes32 jobId;
        (jobId, askId) = auto_.openJob(spec, address(gated), "hook", 0.5 ether, 0.5 ether);
        assertTrue(intake.complete(jobId, abi.encode(jobId, keccak256("completion"), "ipfs://r")));
        GatedHookDeployer.Artifact memory a = _artifact(jobId);
        vm.prank(creator);
        auto_.commitArtifact(jobId, a, bytes20(keccak256("commit")));
        vm.roll(block.number + 8);
        (,, f0, t0) = auto_.verdictReadiness(askId);
        vm.prank(outsider);
        vid = auto_.requestVerdict(askId);
        vm.roll(block.number + 1);
    }
    function _signed(bytes32 vid, bytes32 askId, uint64 issuedAt, uint256 key) internal view returns (bytes memory) {
        OracleAttestation.Attestation memory t = OracleAttestation.Attestation({
            requestId: keccak256("uuid"), chainId: block.chainid,
            questionHash: auto_.expectedQuestionHash(askId, f0, t0), answerType: 0,
            answer: abi.encode(true), figure: 0, fromBlock: f0, toBlock: t0, blockHash: bytes32(uint256(1)),
            panelJobId: keccak256("panel"), panelSize: 7, quorum: 5, agreed: 5,
            issuedAt: issuedAt, expiresAt: issuedAt + 1 days});
        bytes32 d = auto_.attestationDigest(t);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, d);
        return abi.encode(vid, t, abi.encodePacked(r, s, v));
    }
    function testControl() public {
        (bytes32 askId, bytes32 vid) = _ready();
        assertTrue(intake.complete(vid, _signed(vid, askId, uint64(block.timestamp), pk)));
        assertEq(uint8(auto_.getJob(auto_.jobAsk(bytes32(0))).review), 0);
    }
    function testIssuedAtOneSecondAheadLost() public {
        (bytes32 askId, bytes32 vid) = _ready();
        assertTrue(intake.complete(vid, _signed(vid, askId, uint64(block.timestamp) + 1, pk)), "1s skew rejected");
    }
    function testDeliveredAfterOneHourLost() public {
        (bytes32 askId, bytes32 vid) = _ready();
        bytes memory s = _signed(vid, askId, uint64(block.timestamp), pk);
        vm.warp(block.timestamp + 3601);
        assertTrue(intake.complete(vid, s), "1h+1s delivery rejected");
    }
}
```

### 3. Low: Ordinary signer rotation while a verdict is Pending makes the in-flight one-shot answer fail BadSignature

`src/imd/automatic/AutoHookJobRequester.sol:540`

```
function setOracleSigner(address signer) external onlyOwner nonReentrant {
```

_verifyAttestation checks only the current oracleSigner. An answer for an ask triggered under epoch N and signed by the epoch-N key is rejected once setOracleSigner moves to N+1, though the epoch was not revoked. The one-shot callback is lost: review stays Pending, reserve spent, requester waits for owner confirmReviewExpiry and pays again. Fix: accept the signer of the epoch recorded at trigger until that epoch is revoked, or document that rotation must wait for pending asks to settle.

**Reproduction**

After requestVerdict, sign a valid true attestation with the current key, owner calls setOracleSigner(0xD00D), Intake delivers: reverts BadSignature (test/scratch/Skew.t.sol::testRotationMidFlightLost, which asserts acceptance, fails with BadSignature()).

### 4. Low: Candidate committed before delivery cannot be withdrawn; an outsider can spend the reserve on a question that must answer false

`src/imd/automatic/AutoHookJobRequester.sol:214`

```
if (candidateDigest[jobId] != bytes32(0)) revert AlreadyCommitted();
```

commitArtifact is allowed before onJobResult and is immutable. If the delivered snapshot does not match the pre-committed ArtifactV2, the requester cannot cancelReserve (DeadlineNotReached) or recommit, and requestVerdict is permissionless once 8 blocks pass, so the reserve is spent and the resulting NotPassed is terminal. Merges audit_permissions 27d07527 and audit_math fae370f5. Fix: require status == Delivered in commitArtifact, or let the requester cancel while the ask has no intakeId.

**Reproduction**

openJob; commitArtifact while Open; onJobResult with a different snapshot; creator cancelReserve reverts; roll 8; outsider requestVerdict succeeds and intake balance == 1 ether (both fees). test/scratch/Skew.t.sol::testEarlyCommitLocked passes on this code, which shows the lock-in.

### 5. Info: Live-integration and trust items not proven locally (Robinhood window-age default, ArbSys clock, callback gas margin, owner powers)

`src/imd/automatic/AutoHookJobRequester.sol:62`

```
uint64 public maxWindowAgeBlocks = 7200;
```

Not code defects. (1) maxWindowAgeBlocks=7200 applies to the native clock on every chain; on Robinhood (4663, ArbSys arbBlockNumber) sub-second blocks would make it minutes, not a day. The real cadence was not measured here, so set a per-chain value via setPanel before launch. (2) The ArbSys path is covered only by mocks, and testnets 46630/84532 revert UnsupportedClock in head(). (3) Specialists report a Robinhood 22-cold-read ERC-1271 callback minimum of about 195.9k of the 200k stipend; this was not re-measured here. (4) Owner trust: setOracleSigner takes effect immediately; revokeSignerEpoch + closeRevokedVerdict can turn NotPassed into Unanswered and allow a retry; confirmReviewExpiry is owner-only. Merges e855832c, 486c0bec, 84d0a538, 639db2e3, 82d3db6b, 745885ae, 2939818f, 561c401a, 0115375e.

**Reproduction**

Window age: onReviewResult reverts InvalidWindow when head() - toBlock > windowAge (7200 default), so on any chain where 7200 native blocks pass in under the delivery latency, the answer is lost. Not reproduced on live Robinhood.

---

Judge's submission `f92a0d8f4e086d413f58729cd59c1d232b27a486ece9416f749c459698450dad`, accepted on the IdentityMD network. Acceptance means the report met the job's checks;
it is not a guarantee that the code has no other defects.
