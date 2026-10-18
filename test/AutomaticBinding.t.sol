// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./helpers/Fixture.sol";
import {TestToken} from "./helpers/TestToken.sol";
import {StoreTokenMock} from "./helpers/StoreTokenMock.sol";
import {MockIntake} from "./helpers/MockIntake.sol";
import {ColdReadReceiptSigner, ThresholdReceiptSigner} from "./helpers/ReceiptSigners.sol";
import {PoolRouter} from "./helpers/PoolRouter.sol";
import {AutoHookJobRequester} from "../src/imd/automatic/AutoHookJobRequester.sol";
import {HookRequestCodec} from "../src/imd/automatic/HookRequestCodec.sol";
import {HookJobRequester} from "../src/imd/HookJobRequester.sol";
import {OracleAttestation} from "../src/imd/OracleAttestation.sol";
import {GatedHookDeployer} from "../src/deployment/GatedHookDeployer.sol";
import {HookMiner} from "../src/deployment/HookMiner.sol";
import {BoundedSwapHook} from "../src/BoundedSwapHook.sol";
import {HookSpecLib} from "../src/HookSpec.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

abstract contract AutomaticFixture is Fixture {
    AutoHookJobRequester internal automatic;
    GatedHookDeployer internal gated;
    HookRequestCodec internal codec;
    MockIntake internal intake;
    TestToken internal imd;
    address internal creator = makeAddr("automatic creator");
    address internal outsider = makeAddr("automatic outsider");
    uint256 internal key = 0xA11CE;
    bytes20 internal constant COMMIT = bytes20(keccak256("local reviewed git commit"));
    uint256 internal constant FEE = 0.5 ether;
    bytes32 internal jobId;
    bytes32 internal askId;
    bytes32 internal verdictId;
    GatedHookDeployer.Artifact internal artifact;

    function setUp() public virtual override {
        super.setUp();
        vm.warp(1_800_000_000);
        vm.roll(1000);
        codec = new HookRequestCodec();
        intake = new MockIntake();
        imd = new TestToken("local IMD", 18);
        automatic = new AutoHookJobRequester(address(this), address(intake), address(imd), vm.addr(key), FEE, codec);
        gated = new GatedHookDeployer(address(this), HookJobRequester(address(automatic)));
        gated.setManager(address(manager), address(manager).codehash, true);
        intake.setPrice(automatic.jobAction(), address(imd), FEE);
        intake.setPrice(automatic.reviewAction(), address(imd), FEE);
        imd.mint(creator, 100 ether);
        vm.prank(creator);
        imd.approve(address(automatic), 100 ether);
    }

    function _open() internal returns (bytes32 id, bytes32 ask) {
        vm.prank(creator);
        return automatic.openJob(spec, address(gated), "A bounded swap hook", FEE, FEE);
    }

    function _artifact(bytes32 id) internal view returns (GatedHookDeployer.Artifact memory a) {
        a = GatedHookDeployer.Artifact({
            jobRequestId: id,
            sourceHash: sha256("local accepted source bundle"),
            sourceSubmissionHash: sha256("local accepted source submission"),
            reviewSubmissionHash: sha256("local accepted independent review"),
            evidenceHash: bytes32(0),
            buildHash: keccak256("local solc 0.8.26 cancun optimizer 200"),
            creationCodeHash: keccak256(type(BoundedSwapHook).creationCode),
            constructorArgsHash: keccak256(abi.encode(spec)),
            runtimeCodeHash: keccak256(type(BoundedSwapHook).runtimeCode),
            chainId: block.chainid,
            deployer: address(gated),
            poolManager: address(manager),
            poolManagerCodeHash: address(manager).codehash,
            permissions: spec.permissions
        });
        a.evidenceHash = sha256(gated.evidenceDocument(a));
    }

    function _commit(bytes32 id, GatedHookDeployer.Artifact memory a) internal {
        vm.prank(creator);
        automatic.commitArtifact(id, a, COMMIT);
    }

    function _deliver(bytes32 id) internal {
        assertTrue(
            intake.complete(id, abi.encode(id, keccak256("local exact completion snapshot"), "ipfs://local-fixture"))
        );
    }

    function _ready(bool deliveryFirst) internal {
        (jobId, askId) = _open();
        artifact = _artifact(jobId);
        if (deliveryFirst) {
            _deliver(jobId);
            _commit(jobId, artifact);
        } else {
            _commit(jobId, artifact);
            _deliver(jobId);
        }
        vm.roll(vm.getBlockNumber() + 20);
        vm.prank(outsider);
        verdictId = automatic.requestVerdict(askId);
    }

    function _att(bytes32 ask, bool passed) internal view returns (OracleAttestation.Attestation memory a) {
        AutoHookJobRequester.Ask memory ctx = automatic.getAsk(ask);
        a = OracleAttestation.Attestation({
            requestId: keccak256(abi.encode("local oracle uuid", ask)),
            chainId: block.chainid,
            questionHash: automatic.expectedQuestionHash(ask, ctx.fromBlock, ctx.toBlock),
            answerType: 0,
            answer: abi.encode(passed),
            figure: 0,
            fromBlock: ctx.fromBlock,
            toBlock: ctx.toBlock,
            blockHash: keccak256("local closing block"),
            panelJobId: keccak256(abi.encode("panel", ask)),
            panelSize: 7,
            quorum: 5,
            agreed: 5,
            issuedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp + 1 hours)
        });
    }

    function _sign(OracleAttestation.Attestation memory a) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, automatic.attestationDigest(a));
        return abi.encodePacked(r, s, v);
    }

    function _answer(bool passed) internal {
        OracleAttestation.Attestation memory a = _att(askId, passed);
        assertTrue(intake.complete(verdictId, abi.encode(verdictId, a, _sign(a))));
    }

    function _review(bytes32 id) internal view returns (HookJobRequester.ReviewStatus) {
        return automatic.getJob(id).review;
    }

    function _mine() internal view returns (bytes32 salt, address hook) {
        uint256 start;
        for (uint256 i; i < 20; ++i) {
            HookMiner.Result memory r = gated.mine(
                keccak256(bytes.concat(type(BoundedSwapHook).creationCode, abi.encode(spec))),
                spec.permissions,
                start,
                131072
            );
            if (r.found) return (r.salt, r.hook);
            start = r.nextNonce;
        }
        revert("local mining exhausted");
    }
}

contract AutomaticBindingTest is AutomaticFixture {
    function testPrepayBothFeesAndPermissionlessTriggerNoOwnerCall() public {
        _ready(true);
        assertTrue(gated.automaticBindingSupported());
        assertEq(imd.balanceOf(creator), 99 ether);
        assertEq(imd.balanceOf(address(intake)), 1 ether);
        assertEq(imd.allowance(address(automatic), address(intake)), 0);
        assertEq(automatic.reserved(address(imd)), 0);
        assertEq(automatic.getJob(jobId).specHash, HookSpecLib.hash(spec));
        assertEq(automatic.getSpec(jobId).maxSpecifiedAmount, spec.maxSpecifiedAmount);
        _answer(true);
        assertEq(uint8(_review(jobId)), uint8(HookJobRequester.ReviewStatus.Passed));
        assertEq(automatic.approvedArtifact(jobId), gated.artifactDigest(artifact));
        assertEq(automatic.reviewReceiptSignerEpoch(verdictId), 1);
        assertEq(automatic.reviewVerifiedAt(verdictId), block.timestamp);
    }

    function testCandidateAndBuildCallbackBothOrders() public {
        _ready(false);
        _answer(true);
        assertEq(automatic.approvedArtifact(jobId), gated.artifactDigest(artifact));
    }

    function testNoCallerSelectedArtifactAndNoNotPassedShopping() public {
        _ready(true);
        _answer(false);
        assertEq(uint8(_review(jobId)), uint8(HookJobRequester.ReviewStatus.NotPassed));
        vm.expectRevert(AutoHookJobRequester.NotReady.selector);
        automatic.requestVerdict(askId);
        vm.prank(creator);
        vm.expectRevert(AutoHookJobRequester.NotReady.selector);
        automatic.retryVerdict(jobId, FEE);
        vm.prank(creator);
        vm.expectRevert(AutoHookJobRequester.AlreadyCommitted.selector);
        automatic.commitArtifact(jobId, artifact, COMMIT);
        vm.prank(creator);
        vm.expectRevert(AutoHookJobRequester.DeadlineNotReached.selector);
        automatic.cancelReserve(jobId);
    }

    function testRequestOnlyWhenReadyAndNoDoubleSpend() public {
        (jobId, askId) = _open();
        vm.expectRevert(AutoHookJobRequester.NotReady.selector);
        automatic.requestVerdict(askId);
        artifact = _artifact(jobId);
        _commit(jobId, artifact);
        vm.expectRevert(AutoHookJobRequester.NotReady.selector);
        automatic.requestVerdict(askId);
        _deliver(jobId);
        vm.expectRevert(AutoHookJobRequester.NotReady.selector);
        automatic.requestVerdict(askId);
        vm.roll(1001);
        verdictId = automatic.requestVerdict(askId);
        vm.expectRevert(AutoHookJobRequester.NotReady.selector);
        automatic.requestVerdict(askId);
        assertEq(imd.balanceOf(address(intake)), 1 ether);
    }

    function testLowerFeeCreditsRefundAndOwnerCannotSweepEscrow() public {
        (jobId, askId) = _open();
        vm.expectRevert(AutoHookJobRequester.EscrowProtected.selector);
        automatic.sweep(address(imd), address(this), 1);
        _commit(jobId, _artifact(jobId));
        _deliver(jobId);
        vm.roll(1010);
        intake.setPrice(automatic.reviewAction(), address(imd), FEE / 2);
        automatic.requestVerdict(askId);
        assertEq(automatic.refunds(address(imd), creator), FEE / 2);
        assertEq(automatic.reserved(address(imd)), FEE / 2);
        vm.prank(outsider);
        automatic.withdrawRefund(address(imd));
        assertEq(automatic.refunds(address(imd), creator), FEE / 2);
        vm.expectRevert(AutoHookJobRequester.EscrowProtected.selector);
        automatic.sweep(address(imd), address(this), 1);
        vm.prank(creator);
        automatic.withdrawRefund(address(imd));
        assertEq(imd.balanceOf(creator), 99 ether + FEE / 2);
        assertEq(automatic.reserved(address(imd)), 0);
        vm.prank(creator);
        automatic.withdrawRefund(address(imd));
        assertEq(imd.balanceOf(creator), 99 ether + FEE / 2);
    }

    function testBuildFailureRefundAndLateDeliveryCancellationCannotGrief() public {
        (jobId, askId) = _open();
        assertTrue(intake.fail(jobId, 1, "refused", 0, 0));
        vm.prank(creator);
        automatic.cancelReserve(jobId);
        vm.prank(creator);
        automatic.withdrawRefund(address(imd));
        assertEq(imd.balanceOf(creator), 100 ether - FEE);
        vm.expectRevert(AutoHookJobRequester.NotReady.selector);
        automatic.requestVerdict(askId);
        (bytes32 id2, bytes32 ask2) = _open();
        vm.warp(automatic.getJob(id2).deadline + 1);
        vm.prank(creator);
        automatic.cancelReserve(id2);
        _deliver(id2);
        vm.expectRevert(AutoHookJobRequester.NotReady.selector);
        automatic.requestVerdict(ask2);
    }

    function testPriceRiseAndSynchronousRefusalCannotSpendReserve() public {
        (jobId, askId) = _open();
        _commit(jobId, _artifact(jobId));
        _deliver(jobId);
        vm.roll(1005);
        intake.setPrice(automatic.reviewAction(), address(imd), FEE + 1);
        vm.expectRevert(abi.encodeWithSelector(AutoHookJobRequester.PriceExceeded.selector, FEE + 1, FEE));
        automatic.requestVerdict(askId);
        intake.setPrice(automatic.reviewAction(), address(imd), FEE);
        intake.setRefusal(bytes4(keccak256("ActionNotSold()")));
        vm.expectRevert();
        automatic.requestVerdict(askId);
        assertEq(automatic.getAsk(askId).intakeId, bytes32(0));
        assertEq(automatic.reserved(address(imd)), FEE);
        assertEq(imd.balanceOf(address(intake)), FEE);
        intake.setRefusal(bytes4(0));
        intake.setUnspent(1);
        vm.expectRevert(AutoHookJobRequester.InexactSpend.selector);
        automatic.requestVerdict(askId);
        assertEq(automatic.reserved(address(imd)), FEE);
    }

    function testVerdictFailureRetryUsesFreshAskAndPreservesHistory() public {
        _ready(true);
        assertTrue(intake.fail(verdictId, 2, "disagreed", 2, 7));
        vm.prank(creator);
        bytes32 retry = automatic.retryVerdict(jobId, FEE);
        assertNotEq(retry, askId);
        vm.roll(vm.getBlockNumber() + 2);
        bytes32 id2 = automatic.requestVerdict(retry);
        OracleAttestation.Attestation memory a = _att(askId, false);
        assertFalse(intake.complete(id2, abi.encode(id2, a, _sign(a))));
        assertEq(automatic.getAsk(askId).intakeId, verdictId);
        assertEq(uint8(_review(jobId)), uint8(HookJobRequester.ReviewStatus.Pending));
    }

    function testSwapAcrossJobsFailsEvenWhenSignedAndUUIDFresh() public {
        _ready(true);
        bytes32 first = verdictId;
        bytes32 firstAsk = askId;
        _ready(false);
        OracleAttestation.Attestation memory a = _att(firstAsk, true);
        assertFalse(intake.complete(verdictId, abi.encode(verdictId, a, _sign(a))));
        assertFalse(automatic.consumed(a.requestId));
        assertTrue(intake.complete(first, abi.encode(first, a, _sign(a))));
        assertEq(uint8(_review(jobId)), uint8(HookJobRequester.ReviewStatus.Pending));
    }

    function testOnlyIntakeUnknownAndConsumedUUIDReplay() public {
        _ready(true);
        OracleAttestation.Attestation memory a = _att(askId, true);
        bytes memory signature = _sign(a);
        vm.expectRevert(AutoHookJobRequester.NotIntake.selector);
        automatic.onReviewResult(verdictId, a, signature);
        assertTrue(intake.complete(verdictId, abi.encode(verdictId, a, _sign(a))));
        vm.prank(address(intake));
        vm.expectRevert();
        automatic.onReviewResult(verdictId, a, signature);
        bytes32 uuid = a.requestId;
        _ready(false);
        a = _att(askId, true);
        a.requestId = uuid;
        assertFalse(intake.complete(verdictId, abi.encode(verdictId, a, _sign(a))));
    }

    function testFuzzSignedTamperingFailsClosed(uint8 field) public {
        _ready(true);
        OracleAttestation.Attestation memory a = _att(askId, true);
        uint256 f = bound(field, 0, 15);
        if (f == 0) a.questionHash = keccak256("drifted canonicalization");
        if (f == 1) a.chainId++;
        if (f == 2) a.answerType = 3;
        if (f == 3) a.fromBlock--;
        if (f == 4) a.toBlock++;
        if (f == 5) a.issuedAt = uint64(block.timestamp + 1);
        if (f == 6) a.issuedAt = uint64(block.timestamp - 1);
        if (f == 7) a.expiresAt = uint64(block.timestamp - 1);
        if (f == 8) a.panelSize = 6;
        if (f == 9) a.quorum = 0;
        if (f == 10) a.agreed = 4;
        if (f == 11) a.agreed = 8;
        if (f == 12) a.requestId = bytes32(0);
        if (f == 13) a.panelJobId = bytes32(0);
        if (f == 14) a.answer = hex"01";
        if (f == 15) a.answer = abi.encode(uint256(2));
        assertFalse(intake.complete(verdictId, abi.encode(verdictId, a, _sign(a))));
        assertEq(uint8(_review(jobId)), uint8(HookJobRequester.ReviewStatus.Pending));
        assertEq(automatic.approvedArtifact(jobId), bytes32(0));
    }

    function testStaleWindowAndStaleSignatureAndWrongDomain() public {
        _ready(true);
        OracleAttestation.Attestation memory a = _att(askId, true);
        bytes memory sig = _sign(a);
        uint256 snap = vm.snapshotState();
        vm.roll(vm.getBlockNumber() + 7201);
        assertFalse(intake.complete(verdictId, abi.encode(verdictId, a, sig)));
        vm.revertToStateAndDelete(snap);
        snap = vm.snapshotState();
        vm.warp(vm.getBlockTimestamp() + 1 hours + 1);
        assertFalse(intake.complete(verdictId, abi.encode(verdictId, a, sig)));
        vm.revertToStateAndDelete(snap);
        snap = vm.snapshotState();
        vm.chainId(1);
        assertFalse(intake.complete(verdictId, abi.encode(verdictId, a, sig)));
        vm.revertToStateAndDelete(snap);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, keccak256("another consumer domain"));
        assertFalse(intake.complete(verdictId, abi.encode(verdictId, a, abi.encodePacked(r, s, v))));
    }

    function testSignerRevocationBlocksDeploymentAndRecoveryKeepsUUID() public {
        _ready(true);
        _answer(true);
        bytes32 uuid = automatic.getAsk(askId).oracleUUID;
        automatic.setOracleSigner(makeAddr("replacement signer"));
        automatic.revokeSignerEpoch(1, keccak256("local incident"));
        assertEq(automatic.approvedArtifact(jobId), bytes32(0));
        (bytes32 salt, address hook) = _mine();
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(GatedHookDeployer.ReviewRevoked.selector, verdictId));
        gated.deploy(artifact, "", type(BoundedSwapHook).creationCode, abi.encode(spec), salt, hook);
        automatic.closeRevokedVerdict(jobId);
        assertTrue(automatic.consumed(uuid));
        assertEq(automatic.getAsk(askId).oracleUUID, uuid);
        assertEq(uint8(_review(jobId)), uint8(HookJobRequester.ReviewStatus.Unanswered));
    }

    function testNegativeCallbackPreventsExpiryAndOwnerRecovery() public {
        _ready(true);
        _answer(false);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        vm.expectRevert(AutoHookJobRequester.UnknownOrSettled.selector);
        automatic.confirmReviewExpiry(verdictId);
        assertEq(uint8(_review(jobId)), uint8(HookJobRequester.ReviewStatus.NotPassed));
    }

    function testExactArtifactGateRejectsSubstitutionAndExecutesGenuineHook() public {
        _ready(true);
        _answer(true);
        (bytes32 salt, address predicted) = _mine();
        GatedHookDeployer.Artifact memory changed = artifact;
        changed.sourceHash = keccak256("substituted rejected source");
        bytes32 changedDigest = gated.artifactDigest(changed);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(GatedHookDeployer.ArtifactNotInResult.selector, changedDigest));
        gated.deploy(changed, "", type(BoundedSwapHook).creationCode, abi.encode(spec), salt, predicted);
        vm.prank(creator);
        address deployed =
            gated.deploy(artifact, "", type(BoundedSwapHook).creationCode, abi.encode(spec), salt, predicted);
        _exerciseHook(deployed);
        vm.prank(creator);
        vm.expectRevert();
        gated.deploy(artifact, "", type(BoundedSwapHook).creationCode, abi.encode(spec), salt, predicted);
    }

    function _exerciseHook(address deployed) private {
        BoundedSwapHook hook = BoundedSwapHook(deployed);
        PoolRouter router = new PoolRouter(manager);
        TestToken t0 = new TestToken("A", 18);
        TestToken t1 = new TestToken("B", 18);
        t0.mint(address(this), 1e24);
        t1.mint(address(this), 1e24);
        t0.approve(address(router), type(uint256).max);
        t1.approve(address(router), type(uint256).max);
        (address c0, address c1) = address(t0) < address(t1) ? (address(t0), address(t1)) : (address(t1), address(t0));
        PoolKey memory pool = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 3000, 60, IHooks(deployed));
        manager.initialize(pool, 1 << 96);
        router.liquidity(pool, 1e12);
        router.swap(pool, IPoolManager.SwapParams(true, -10000, TickMath.MIN_SQRT_PRICE + 1), "", false);
        assertEq(hook.swapCount(pool.toId()), 1);
    }

    function testFuzzEveryArtifactFieldIsBound(uint8 field) public {
        _ready(true);
        _answer(true);
        GatedHookDeployer.Artifact memory changed = artifact;
        uint256 f = bound(field, 0, 13);
        assembly ("memory-safe") {
            let p := add(changed, mul(f, 32))
            mstore(p, xor(mload(p), 1))
        }
        (bytes32 salt,) = _mine();
        vm.expectRevert();
        gated.check(changed, "", type(BoundedSwapHook).creationCode, abi.encode(spec), salt, creator);
    }

    function testWindowWaitsForBothDeliveredJobAndCandidateConfirmation() public {
        (jobId, askId) = _open();
        vm.roll(1010);
        _deliver(jobId);
        vm.roll(1020);
        _commit(jobId, _artifact(jobId));
        vm.expectRevert(AutoHookJobRequester.NotReady.selector);
        automatic.requestVerdict(askId);
        vm.roll(1021);
        verdictId = automatic.requestVerdict(askId);
        assertEq(automatic.getAsk(askId).fromBlock, 1020);
        assertEq(automatic.getAsk(askId).toBlock, 1020);
        (bytes32 secondJob, bytes32 secondAsk) = _open();
        vm.roll(1030);
        _commit(secondJob, _artifact(secondJob));
        vm.roll(1040);
        _deliver(secondJob);
        vm.expectRevert(AutoHookJobRequester.NotReady.selector);
        automatic.requestVerdict(secondAsk);
        vm.roll(1041);
        automatic.requestVerdict(secondAsk);
        assertEq(automatic.getAsk(secondAsk).fromBlock, 1040);
    }

    function testExpiredUnspentReadyReserveCannotBeGriefSpent() public {
        (jobId, askId) = _open();
        _commit(jobId, _artifact(jobId));
        _deliver(jobId);
        vm.warp(automatic.getJob(jobId).deadline + 1);
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(outsider);
        vm.expectRevert(AutoHookJobRequester.NotReady.selector);
        automatic.requestVerdict(askId);
        vm.prank(creator);
        automatic.cancelReserve(jobId);
        assertEq(automatic.refunds(address(imd), creator), FEE);
        assertEq(imd.balanceOf(address(intake)), FEE);
    }

    function testSignedCanonicalFutureOrPreAskWindowFailsWindowPolicy() public {
        _ready(true);
        OracleAttestation.Attestation memory a = _att(askId, true);
        a.toBlock = uint64(block.number + 1);
        a.questionHash = automatic.expectedQuestionHash(askId, a.fromBlock, a.toBlock);
        bytes memory signature = _sign(a);
        vm.prank(address(intake));
        vm.expectRevert(AutoHookJobRequester.InvalidWindow.selector);
        automatic.onReviewResult(verdictId, a, signature);
        a = _att(askId, true);
        a.fromBlock--;
        a.questionHash = automatic.expectedQuestionHash(askId, a.fromBlock, a.toBlock);
        signature = _sign(a);
        vm.prank(address(intake));
        vm.expectRevert(AutoHookJobRequester.InvalidWindow.selector);
        automatic.onReviewResult(verdictId, a, signature);
    }

    function testProtocolSettingsCannotRedirectPendingFundsOrCallback() public {
        _ready(true);
        automatic.setProtocol(outsider, outsider, 1, bytes32("replacement job"), bytes32("replacement oracle"));
        _answer(true);
        assertEq(uint8(_review(jobId)), uint8(HookJobRequester.ReviewStatus.Passed));
        assertEq(imd.balanceOf(address(intake)), 2 * FEE);
    }

    function testLowerSignedQuorumWithSufficientActualAgreementAccepted() public {
        _ready(true);
        OracleAttestation.Attestation memory a = _att(askId, true);
        a.quorum = 4;
        assertTrue(intake.complete(verdictId, abi.encode(verdictId, a, _sign(a))));
        assertEq(uint8(_review(jobId)), uint8(HookJobRequester.ReviewStatus.Passed));
    }

    function testMismatchedCandidateAndUntrustedCallerRejected() public {
        (jobId, askId) = _open();
        artifact = _artifact(jobId);
        vm.prank(outsider);
        vm.expectRevert(AutoHookJobRequester.NotRequester.selector);
        automatic.commitArtifact(jobId, artifact, COMMIT);
        artifact.chainId++;
        vm.prank(creator);
        vm.expectRevert(HookRequestCodec.InvalidArtifact.selector);
        automatic.commitArtifact(jobId, artifact, COMMIT);
        artifact = _artifact(jobId);
        artifact.reviewSubmissionHash = artifact.sourceSubmissionHash;
        vm.prank(creator);
        vm.expectRevert(HookRequestCodec.InvalidArtifact.selector);
        automatic.commitArtifact(jobId, artifact, COMMIT);
        artifact = _artifact(jobId);
        artifact.evidenceHash = keccak256("tampered evidence");
        vm.prank(creator);
        vm.expectRevert(HookRequestCodec.InvalidArtifact.selector);
        automatic.commitArtifact(jobId, artifact, COMMIT);
    }

    function testTokenReentrancyCannotOpenAnotherJobOrDrainReserve() public {
        StoreTokenMock token = new StoreTokenMock();
        automatic.setProtocol(address(intake), address(token), FEE, automatic.jobAction(), automatic.reviewAction());
        intake.setPrice(automatic.jobAction(), address(token), FEE);
        intake.setPrice(automatic.reviewAction(), address(token), FEE);
        token.mint(creator, 10 ether);
        vm.prank(creator);
        token.approve(address(automatic), 10 ether);
        token.setCallback(
            address(automatic), abi.encodeCall(automatic.openJob, (spec, address(gated), bytes("reenter"), FEE, FEE))
        );
        (jobId, askId) = _open();
        assertFalse(token.callbackSucceeded());
        assertEq(bytes4(token.callbackResult()), AutoHookJobRequester.Reentrancy.selector);
        assertEq(automatic.reserved(address(token)), FEE);
        assertEq(token.balanceOf(address(intake)), FEE);
        assertEq(automatic.getJob(jobId).requester, creator);
    }

    function testExpiryRecoveryBothOrdersAndNegativeCannotRetry() public {
        _ready(true);
        vm.warp(automatic.getAsk(askId).deadline + 1);
        OracleAttestation.Attestation memory a = _att(askId, false);
        bytes memory signature = _sign(a);
        uint256 snap = vm.snapshotState();
        // Delivery after its local deadline remains admissible if signed fresh.
        assertTrue(intake.complete(verdictId, abi.encode(verdictId, a, signature)));
        vm.expectRevert(AutoHookJobRequester.UnknownOrSettled.selector);
        automatic.confirmReviewExpiry(verdictId);
        vm.prank(creator);
        vm.expectRevert(AutoHookJobRequester.NotReady.selector);
        automatic.retryVerdict(jobId, FEE);
        vm.revertToStateAndDelete(snap);
        // Exceptional owner closure can lose a later callback; it is an explicit trust power.
        automatic.confirmReviewExpiry(verdictId);
        assertFalse(intake.complete(verdictId, abi.encode(verdictId, a, signature)));
        assertEq(uint8(_review(jobId)), uint8(HookJobRequester.ReviewStatus.Unanswered));
    }

    function testDuplicateIntakeIdRollsBackPaymentAndReservation() public {
        (jobId, askId) = _open();
        _commit(jobId, _artifact(jobId));
        _deliver(jobId);
        vm.roll(1002);
        intake.setReuseIds(true);
        vm.expectRevert(AutoHookJobRequester.DuplicateId.selector);
        automatic.requestVerdict(askId);
        assertEq(automatic.getAsk(askId).intakeId, bytes32(0));
        assertEq(imd.balanceOf(address(intake)), FEE);
        assertEq(automatic.reserved(address(imd)), FEE);
    }

    function testSaveActualBodiesForIndependentPreflight() public {
        _ready(true);
        emit log_named_string("JOB_BODY", string(intake.bodyOf(jobId)));
        emit log_named_string("ORACLE_BODY", string(intake.bodyOf(verdictId)));
        emit log_named_string("QUESTION_PREFIX", string(automatic.questionPrefix(askId)));
    }
}

contract AutomaticGasTest is AutomaticFixture {
    ColdReadReceiptSigner private registry;
    ThresholdReceiptSigner private multisigner;
    uint256[] private memberKeys;
    bytes32 private pendingJob;

    function setUp() public override {
        super.setUp();
        _ready(true);
        registry = new ColdReadReceiptSigner(vm.addr(key), 22);
        (pendingJob,) = _open();
        address[] memory members = new address[](7);
        for (uint256 i; i < 7; ++i) {
            memberKeys.push(uint256(keccak256(abi.encode("automatic gas member", i))));
        }
        for (uint256 i; i < 7; ++i) {
            for (uint256 j = i + 1; j < 7; ++j) {
                if (vm.addr(memberKeys[j]) < vm.addr(memberKeys[i])) {
                    (memberKeys[i], memberKeys[j]) = (memberKeys[j], memberKeys[i]);
                }
            }
            members[i] = vm.addr(memberKeys[i]);
        }
        multisigner = new ThresholdReceiptSigner(members, 5);
    }

    function _minimum(bytes memory payload, address signer) private returns (uint256) {
        uint256 lo = 50000;
        uint256 hi = 300000;
        while (lo < hi) {
            uint256 gasCap = (lo + hi) / 2;
            uint256 snap = vm.snapshotState();
            vm.cool(address(automatic));
            vm.cool(address(codec));
            vm.cool(signer);
            vm.cool(automatic.getAsk(askId).pin);
            // getAsk warms automatic again; cool it after retrieving the pin.
            vm.cool(address(automatic));
            vm.prank(address(intake));
            (bool ok,) = address(automatic).call{gas: gasCap}(payload);
            assertTrue(vm.revertToStateAndDelete(snap));
            if (ok) hi = gasCap;
            else lo = gasCap + 1;
        }
        return hi;
    }

    function testColdEOACallbackUnder200k() public {
        OracleAttestation.Attestation memory a = _att(askId, true);
        bytes memory payload = abi.encodeCall(automatic.onReviewResult, (verdictId, a, _sign(a)));
        uint256 measured = _minimum(payload, vm.addr(key));
        emit log_named_uint("Automatic EOA minimum forwarded callback gas", measured);
        assertLt(measured, 200000);
        _answer(true);
    }

    function testColdRealisticERC1271CallbackUnder200k() public {
        automatic.setOracleSigner(address(registry));
        OracleAttestation.Attestation memory a = _att(askId, false);
        bytes memory payload = abi.encodeCall(automatic.onReviewResult, (verdictId, a, _sign(a)));
        uint256 measured = _minimum(payload, address(registry));
        emit log_named_uint("Automatic 22-cold-read ERC1271 minimum forwarded callback gas", measured);
        assertLt(measured, 200000);
        _answer(false);
    }

    function testColdFiveOfSevenCallbackUnder200k() public {
        automatic.setOracleSigner(address(multisigner));
        OracleAttestation.Attestation memory a = _att(askId, true);
        bytes32 digest = automatic.attestationDigest(a);
        bytes memory signature;
        for (uint256 i; i < 5; ++i) {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(memberKeys[i], digest);
            signature = bytes.concat(signature, abi.encodePacked(r, s, v));
        }
        bytes memory payload = abi.encodeCall(automatic.onReviewResult, (verdictId, a, signature));
        uint256 measured = _minimum(payload, address(multisigner));
        emit log_named_uint("Automatic cold 5-of-7 ERC1271 minimum forwarded callback gas", measured);
        assertLt(measured, 200000);
        assertTrue(intake.complete(verdictId, abi.encode(verdictId, a, signature)));
    }

    function testColdJobResultAndOversizedUriFit200k() public {
        bytes memory payload = abi.encode(pendingJob, keccak256("local completed document"), new string(65536));
        vm.cool(address(automatic));
        assertTrue(intake.complete(pendingJob, payload));
        assertEq(automatic.getJob(pendingJob).resultHash, keccak256("local completed document"));
        assertEq(uint8(automatic.getJob(pendingJob).status), uint8(HookJobRequester.JobStatus.Delivered));
    }

    function testColdJobAndOracleFailureCallbacksFit200k() public {
        vm.cool(address(automatic));
        assertTrue(intake.fail(pendingJob, 1, "body refused", 0, 0));
        vm.cool(address(automatic));
        assertTrue(intake.fail(verdictId, 2, "disagreed", 2, 7));
        assertEq(uint8(_review(jobId)), uint8(HookJobRequester.ReviewStatus.Unanswered));
    }

    function testProductionRuntimeSizes() public view {
        assertLe(address(automatic).code.length, 24576);
        assertLe(address(gated).code.length, 24576);
        assertLe(address(codec).code.length, 24576);
        assertLe(automatic.getAsk(askId).pin.code.length, 24576);
    }
}
