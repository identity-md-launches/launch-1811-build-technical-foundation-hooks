// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AutomaticFixture} from "./AutomaticBinding.t.sol";
import {AutoHookJobRequester} from "../src/imd/automatic/AutoHookJobRequester.sol";
import {HookJobRequester} from "../src/imd/HookJobRequester.sol";
import {OracleAttestation, OracleAttestationConsumer} from "../src/imd/OracleAttestation.sol";
import {ColdReadReceiptSigner} from "./helpers/ReceiptSigners.sol";
import {WindowArbSysMock} from "./OracleWindowRegression.t.sol";
import {HookRequestCodec} from "../src/imd/automatic/HookRequestCodec.sol";
import {ECDSA} from "../src/vendor/openzeppelin/utils/cryptography/ECDSA.sol";
import {HookSpecLib} from "../src/HookSpec.sol";

/// @dev Regressions for all four actionable findings at 205fa112. Local mock Intake is one-shot.
contract Audit2218802dTest is AutomaticFixture {
    function testIssue1LateDeliveryLeavesTimeToMature() public {
        (jobId, askId) = _open();
        vm.warp(automatic.getJob(jobId).deadline - 60);
        _deliver(jobId);
        _commit(jobId, _artifact(jobId));
        vm.roll(vm.getBlockNumber() + 8);
        vm.warp(vm.getBlockTimestamp() + 96);
        (bool ready,,,) = automatic.verdictReadiness(askId);
        assertTrue(ready, "late delivered candidate must still mature");
        verdictId = automatic.requestVerdict(askId);
        _answer(true);
    }

    function testIssue1ExpiredBuildCanBeDeliveredAndReviewed() public {
        (jobId, askId) = _open();
        vm.warp(automatic.getJob(jobId).deadline + 1);
        vm.prank(creator);
        automatic.expireJob(jobId);
        _deliver(jobId);
        _commit(jobId, _artifact(jobId));
        vm.roll(vm.getBlockNumber() + 8);
        verdictId = automatic.requestVerdict(askId);
        _answer(false);
    }

    function testIssue2OneSecondSkewTrue() public {
        _skew(1, true);
    }

    function testIssue2ThreeHundredSecondSkewFalse() public {
        _skew(300, false);
    }

    function _skew(uint64 secondsAhead, bool passed) internal {
        _ready();
        OracleAttestation.Attestation memory a = _att(askId, passed);
        a.issuedAt += secondsAhead;
        a.expiresAt = a.issuedAt + 1 days;
        assertTrue(intake.complete(verdictId, abi.encode(verdictId, a, _sign(a))), "valid skew rejected");
        assertEq(automatic.reviewVerifiedAt(verdictId), block.timestamp, "future receipt clock");
        assertEq(
            uint8(_review(jobId)),
            uint8(passed ? HookJobRequester.ReviewStatus.Passed : HookJobRequester.ReviewStatus.NotPassed)
        );
    }

    function testIssue2DelayedTrueStillValid() public {
        _delayed(true);
    }

    function testIssue2DelayedFalseStillTerminal() public {
        _delayed(false);
    }

    function _delayed(bool passed) internal {
        _ready();
        OracleAttestation.Attestation memory a = _att(askId, passed);
        a.expiresAt = a.issuedAt + 1 days;
        bytes memory signature = _sign(a);
        vm.warp(vm.getBlockTimestamp() + 3601);
        assertTrue(intake.complete(verdictId, abi.encode(verdictId, a, signature)), "valid delayed answer rejected");
        assertEq(automatic.reviewVerifiedAt(verdictId), a.issuedAt);
        if (!passed) {
            vm.prank(creator);
            vm.expectRevert(AutoHookJobRequester.NotReady.selector);
            automatic.retryVerdict(jobId, FEE);
        }
    }

    function testIssue3EOARotationKeepsPendingSigner() public {
        _ready();
        OracleAttestation.Attestation memory a = _att(askId, true);
        bytes memory signature = _sign(a);
        automatic.setOracleSigner(makeAddr("replacement"));
        assertTrue(intake.complete(verdictId, abi.encode(verdictId, a, signature)), "ordinary rotation lost answer");
        assertEq(automatic.reviewReceiptSignerEpoch(verdictId), 1);
    }

    function testIssue3ERC1271RotationKeepsPendingSigner() public {
        ColdReadReceiptSigner signer = new ColdReadReceiptSigner(vm.addr(key), 22);
        automatic.setOracleSigner(address(signer));
        _ready();
        OracleAttestation.Attestation memory a = _att(askId, false);
        bytes memory signature = _sign(a);
        automatic.setOracleSigner(makeAddr("replacement"));
        assertTrue(intake.complete(verdictId, abi.encode(verdictId, a, signature)), "registry rotation lost answer");
        assertEq(automatic.reviewReceiptSignerEpoch(verdictId), 2);
    }

    function testIssue4CommitRequiresDelivered() public {
        (jobId, askId) = _open();
        artifact = _artifact(jobId);
        vm.prank(creator);
        vm.expectRevert(AutoHookJobRequester.NotReady.selector);
        automatic.commitArtifact(jobId, artifact, COMMIT);
        assertEq(automatic.candidateDigest(jobId), bytes32(0));
        _deliver(jobId);
        _commit(jobId, artifact);
        vm.roll(vm.getBlockNumber() + 8);
        verdictId = automatic.requestVerdict(askId);
        _answer(true);
    }
}

contract AuditReserveWindowTest is AutomaticFixture {
    function _clock(bool robinhood) internal {
        if (robinhood) {
            vm.chainId(4663);
            spec.chainId = 4663;
            vm.etch(address(100), type(WindowArbSysMock).runtimeCode);
            WindowArbSysMock(address(100)).setHead(900_000);
        }
    }

    function _advance(uint64 count) internal {
        uint64 h = automatic.head();
        if (block.chainid == 4663) WindowArbSysMock(address(100)).setHead(h + count);
        else vm.roll(h + count);
    }

    function testFuzzRefreshNeverShortensDeadlineAndUsesNativeClock(bool robinhood) public {
        _clock(robinhood);
        (jobId, askId) = _open();
        uint64 original = automatic.reserveDeadline(jobId);
        _advance(10);
        _deliver(jobId);
        assertEq(automatic.reserveDeadline(jobId), original);
        vm.warp(original - 60);
        _advance(10);
        uint64 committedAt = automatic.head();
        _commit(jobId, _artifact(jobId));
        assertEq(automatic.reserveDeadline(jobId), vm.getBlockTimestamp() + 1 days);
        (,, uint64 start,) = automatic.verdictReadiness(askId);
        assertEq(start, committedAt);
        _advance(8);
        vm.warp(vm.getBlockTimestamp() + 96);
        verdictId = automatic.requestVerdict(askId);
        _answer(true);
    }

    function testDeliveryAndCommitEachExtendExpiredReserve() public {
        (jobId, askId) = _open();
        vm.warp(automatic.reserveDeadline(jobId) + 1);
        _deliver(jobId);
        uint64 deliveryDeadline = automatic.reserveDeadline(jobId);
        assertEq(deliveryDeadline, vm.getBlockTimestamp() + 1 days);
        vm.warp(deliveryDeadline + 1);
        vm.roll(2000);
        _commit(jobId, _artifact(jobId));
        assertEq(automatic.reserveDeadline(jobId), vm.getBlockTimestamp() + 1 days);
        vm.roll(2008);
        verdictId = automatic.requestVerdict(askId);
        _answer(true);
    }

    function testFuzzRenewUnspentAskPreservesFundsIdentityAndMaturity(bool robinhood, bool committed) public {
        _clock(robinhood);
        (jobId, askId) = _open();
        _deliver(jobId);
        if (committed) _commit(jobId, _artifact(jobId));
        bytes32 candidate = automatic.candidateDigest(jobId);
        uint64 deadline = automatic.reserveDeadline(jobId);
        vm.warp(deadline);
        vm.prank(creator);
        vm.expectRevert(AutoHookJobRequester.DeadlineNotReached.selector);
        automatic.renewVerdict(jobId);
        vm.warp(uint256(deadline) + 1);
        vm.prank(outsider);
        vm.expectRevert(AutoHookJobRequester.NotRequester.selector);
        automatic.renewVerdict(jobId);
        _advance(100);
        uint64 renewedAt = automatic.head();
        uint256 balance = imd.balanceOf(creator);
        uint256 allowance = imd.allowance(creator, address(automatic));
        // A renewal must not quote or interact with Intake at all.
        intake.setRefusal(bytes4(keccak256("ActionNotSold()")));
        vm.prank(creator);
        automatic.renewVerdict(jobId);
        assertEq(automatic.jobAsk(jobId), askId);
        assertEq(automatic.candidateDigest(jobId), candidate);
        assertEq(automatic.reserveDeadline(jobId), vm.getBlockTimestamp() + 1 days);
        assertEq(automatic.getAsk(askId).intakeId, bytes32(0));
        assertEq(automatic.getAsk(askId).pin, address(0));
        assertEq(automatic.getAsk(askId).verification, 0);
        assertEq(imd.balanceOf(creator), balance);
        assertEq(imd.allowance(creator, address(automatic)), allowance);
        assertEq(imd.balanceOf(address(intake)), FEE);
        assertEq(automatic.reserved(address(imd)), FEE);
        assertEq(automatic.refunds(address(imd), creator), 0);
        if (!committed) _commit(jobId, _artifact(jobId));
        for (uint64 i; i < 8; ++i) {
            (bool ready,, uint64 start,) = automatic.verdictReadiness(askId);
            assertFalse(ready);
            assertEq(start, renewedAt);
            vm.expectRevert(AutoHookJobRequester.NotReady.selector);
            automatic.requestVerdict(askId);
            _advance(1);
        }
        intake.setRefusal(bytes4(0));
        verdictId = automatic.requestVerdict(askId);
        assertEq(automatic.getAsk(askId).fromBlock, renewedAt);
        assertEq(automatic.getAsk(askId).toBlock, renewedAt);
        _answer(false);
        vm.warp(automatic.reserveDeadline(jobId) + 1);
        vm.prank(creator);
        vm.expectRevert(AutoHookJobRequester.NotReady.selector);
        automatic.renewVerdict(jobId);
    }

    function testExpiredRetryCanRenewWithoutAnotherPaymentAndRefundSurplus() public {
        _ready();
        assertTrue(intake.fail(verdictId, 2, "no answer", 0, 7));
        bytes32 oldAsk = askId;
        vm.prank(creator);
        askId = automatic.retryVerdict(jobId, FEE);
        vm.warp(automatic.reserveDeadline(jobId) + 1);
        uint256 balance = imd.balanceOf(creator);
        vm.prank(creator);
        automatic.renewVerdict(jobId);
        assertEq(imd.balanceOf(creator), balance);
        assertNotEq(askId, oldAsk);
        assertEq(automatic.jobAsk(jobId), askId);
        assertEq(automatic.getAsk(oldAsk).intakeId, verdictId);
        _advance(8);
        intake.setPrice(automatic.reviewAction(), address(imd), FEE / 2);
        verdictId = automatic.requestVerdict(askId);
        _answer(true);
        assertEq(automatic.refunds(address(imd), creator), FEE / 2);
        assertEq(automatic.reserved(address(imd)), FEE / 2);
        vm.expectRevert(AutoHookJobRequester.EscrowProtected.selector);
        automatic.sweep(address(imd), outsider, 1);
        vm.prank(creator);
        automatic.withdrawRefund(address(imd));
        assertEq(imd.balanceOf(creator), balance + FEE / 2);
        assertEq(automatic.reserved(address(imd)), 0);
    }

    function testCancelledReserveCannotReviveAfterLateDeliveryOrRenewal() public {
        (jobId, askId) = _open();
        vm.warp(automatic.reserveDeadline(jobId) + 1);
        vm.prank(creator);
        automatic.cancelReserve(jobId);
        _deliver(jobId);
        artifact = _artifact(jobId);
        vm.prank(creator);
        vm.expectRevert(AutoHookJobRequester.NotReady.selector);
        automatic.commitArtifact(jobId, artifact, COMMIT);
        vm.warp(automatic.reserveDeadline(jobId) + 1);
        vm.prank(creator);
        vm.expectRevert(AutoHookJobRequester.NotReady.selector);
        automatic.renewVerdict(jobId);
        _advance(8);
        vm.expectRevert(AutoHookJobRequester.NotReady.selector);
        automatic.requestVerdict(askId);
        vm.prank(creator);
        automatic.withdrawRefund(address(imd));
        assertEq(imd.balanceOf(creator), 100 ether - FEE);
    }

    function testRenewThenCancelRefundsExactlyOnce() public {
        (jobId, askId) = _open();
        _deliver(jobId);
        _commit(jobId, _artifact(jobId));
        vm.warp(automatic.reserveDeadline(jobId) + 1);
        vm.prank(creator);
        automatic.renewVerdict(jobId);
        vm.prank(creator);
        vm.expectRevert(AutoHookJobRequester.DeadlineNotReached.selector);
        automatic.cancelReserve(jobId);
        vm.warp(automatic.reserveDeadline(jobId) + 1);
        vm.prank(creator);
        automatic.cancelReserve(jobId);
        vm.prank(creator);
        automatic.cancelReserve(jobId);
        assertEq(automatic.refunds(address(imd), creator), FEE);
        vm.prank(creator);
        automatic.withdrawRefund(address(imd));
        assertEq(imd.balanceOf(creator), 100 ether - FEE);
        assertEq(automatic.reserved(address(imd)), 0);
    }

    function testRenewRejectsOpenExpiredFailedPendingAndUnanswered() public {
        (jobId, askId) = _open();
        vm.warp(automatic.reserveDeadline(jobId) + 1);
        _cannotRenew();
        vm.prank(creator);
        automatic.expireJob(jobId);
        _cannotRenew();
        assertTrue(intake.fail(jobId, 1, "failed", 0, 0));
        _cannotRenew();
        _ready();
        vm.warp(automatic.reserveDeadline(jobId) + 1);
        _cannotRenew();
        automatic.confirmReviewExpiry(verdictId);
        _cannotRenew();
    }

    function _cannotRenew() private {
        vm.prank(creator);
        vm.expectRevert(AutoHookJobRequester.NotReady.selector);
        automatic.renewVerdict(jobId);
    }

    function testRenewUsesNativeClockAndFailsAtomicallyIfUnavailable() public {
        _clock(true);
        (jobId, askId) = _open();
        _deliver(jobId);
        _commit(jobId, _artifact(jobId));
        uint64 deadline = automatic.reserveDeadline(jobId);
        vm.warp(uint256(deadline) + 1);
        WindowArbSysMock(address(100)).setHead(1 << 64);
        vm.prank(creator);
        vm.expectRevert(HookRequestCodec.InvalidClock.selector);
        automatic.renewVerdict(jobId);
        assertEq(automatic.reserveDeadline(jobId), deadline);
        assertEq(automatic.reserved(address(imd)), FEE);
        assertEq(automatic.jobAsk(jobId), askId);
    }
}

contract AuditAnswerWindowTest is AutomaticFixture {
    function _complete(OracleAttestation.Attestation memory a, bool expected) internal {
        assertEq(intake.complete(verdictId, abi.encode(verdictId, a, _sign(a))), expected);
        assertEq(automatic.consumed(a.requestId), expected);
        if (!expected) {
            assertEq(uint8(_review(jobId)), uint8(HookJobRequester.ReviewStatus.Pending));
            assertEq(automatic.reviewReceiptSignerEpoch(verdictId), 0);
        }
    }

    function testFuzzClockToleranceExactBoundaries(bool passed, uint8 which) public {
        _ready();
        uint64[3] memory offsets = [uint64(1), 300, 301];
        uint64 offset = offsets[bound(which, 0, 2)];
        OracleAttestation.Attestation memory a = _att(askId, passed);
        a.issuedAt += offset;
        a.expiresAt = a.issuedAt + 1 days;
        _complete(a, offset <= 300);
        if (offset <= 300) assertEq(automatic.reviewVerifiedAt(verdictId), vm.getBlockTimestamp());
    }

    function testIssuanceMustNotPrecedeAsk() public {
        _ready();
        OracleAttestation.Attestation memory a = _att(askId, true);
        a.issuedAt = automatic.getAsk(askId).askedAt - 1;
        _complete(a, false);
    }

    function testFuzzIssuanceBoundedByAskDeadlineWithTolerance(bool passed, bool tooLate) public {
        _ready();
        uint64 issued = automatic.getAsk(askId).deadline + (tooLate ? 301 : 300);
        vm.warp(issued);
        OracleAttestation.Attestation memory a = _att(askId, passed);
        a.expiresAt = issued + 1 days;
        _complete(a, !tooLate);
        if (!tooLate) assertEq(automatic.reviewVerifiedAt(verdictId), issued);
    }

    function testFuzzExpiryAndMaximumLifetimeInclusive(bool passed, bool pastExpiry) public {
        _ready();
        OracleAttestation.Attestation memory a = _att(askId, passed);
        a.expiresAt = a.issuedAt + 1 days;
        vm.warp(uint256(a.expiresAt) + (pastExpiry ? 1 : 0));
        _complete(a, !pastExpiry);
    }

    function testFuzzInvalidSignedLifetime(bool beforeIssuance, bool passed) public {
        _ready();
        OracleAttestation.Attestation memory a = _att(askId, passed);
        a.expiresAt = beforeIssuance ? a.issuedAt - 1 : a.issuedAt + 86401;
        _complete(a, false);
    }

    function testZeroLifetimeValidAtIssuance() public {
        _ready();
        OracleAttestation.Attestation memory a = _att(askId, false);
        a.expiresAt = a.issuedAt;
        _complete(a, true);
    }

    function testTimestampMaximumCannotWrapLifetimeBounds() public {
        _ready();
        OracleAttestation.Attestation memory a = _att(askId, false);
        a.issuedAt = type(uint64).max - 1;
        a.expiresAt = type(uint64).max;
        _complete(a, false);
    }

    function testDelayedFalseAfterDeadlineStillBlocksExpiryRenewAndRetry() public {
        _ready();
        uint64 deadline = automatic.getAsk(askId).deadline;
        vm.warp(deadline);
        OracleAttestation.Attestation memory a = _att(askId, false);
        a.expiresAt = deadline + 1 days;
        vm.warp(uint256(deadline) + 3601);
        _complete(a, true);
        vm.expectRevert(AutoHookJobRequester.UnknownOrSettled.selector);
        automatic.confirmReviewExpiry(verdictId);
        vm.prank(creator);
        vm.expectRevert(AutoHookJobRequester.NotReady.selector);
        automatic.renewVerdict(jobId);
        vm.prank(creator);
        vm.expectRevert(AutoHookJobRequester.NotReady.selector);
        automatic.retryVerdict(jobId, FEE);
    }
}

contract CallerBoundReceiptSigner {
    address private immutable consumer;
    address private immutable signer;

    constructor(address consumer_, address signer_) {
        consumer = consumer_;
        signer = signer_;
    }

    function isValidSignature(bytes32 digest, bytes calldata signature) external view returns (bytes4) {
        require(msg.sender == consumer, "wrong consumer context");
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecoverCalldata(digest, signature);
        return err == ECDSA.RecoverError.NoError && recovered == signer ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }
}

contract AuditSignerEpochTest is AutomaticFixture {
    function testTriggerRecordsSignerAndEpochButReceiptViewsWaitForAnswer() public {
        _ready();
        uint256 recorded = (uint256(uint160(vm.addr(key))) << 96) | (uint256(1) << 64);
        assertEq(automatic.getAsk(askId).verification, recorded);
        assertEq(automatic.reviewReceiptSignerEpoch(verdictId), 0);
        assertEq(automatic.reviewVerifiedAt(verdictId), 0);
        automatic.setOracleSigner(makeAddr("next signer"));
        _answer(true);
        assertEq(automatic.getAsk(askId).verification, recorded | uint64(vm.getBlockTimestamp()));
        assertEq(automatic.reviewReceiptSignerEpoch(verdictId), 1);
        assertEq(automatic.reviewReceiptSignerEpoch(keccak256("unknown intake")), 0);
    }

    function testERC1271IsVerifiedInRequesterContextAfterRotation() public {
        CallerBoundReceiptSigner signer = new CallerBoundReceiptSigner(address(automatic), vm.addr(key));
        automatic.setOracleSigner(address(signer));
        _ready();
        automatic.setOracleSigner(makeAddr("next signer"));
        _answer(false);
        assertEq(automatic.reviewReceiptSignerEpoch(verdictId), 2);
        assertEq(address(uint160(automatic.getAsk(askId).verification >> 96)), address(signer));
    }

    function testEOAWithCodeUsesECDSAFirstAfterRotation() public {
        vm.etch(vm.addr(key), hex"60006000fd"); // ERC-1271 would revert.
        _ready();
        automatic.setOracleSigner(makeAddr("next signer"));
        _answer(true);
        assertEq(automatic.reviewReceiptSignerEpoch(verdictId), 1);
    }

    function testNewSignerCannotAnswerOldAsk() public {
        _ready();
        uint256 replacementKey = uint256(keccak256("local replacement signer"));
        automatic.setOracleSigner(vm.addr(replacementKey));
        OracleAttestation.Attestation memory a = _att(askId, false);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(replacementKey, automatic.attestationDigest(a));
        vm.prank(address(intake));
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        automatic.onReviewResult(verdictId, a, abi.encodePacked(r, s, v));
        _answer(false);
    }

    function testFuzzRevokedPendingSignerFailsAndRecoveryIsGuarded(bool registry) public {
        if (registry) {
            automatic.setOracleSigner(address(new CallerBoundReceiptSigner(address(automatic), vm.addr(key))));
        }
        uint32 epoch = automatic.oracleSignerEpoch();
        _ready();
        automatic.setOracleSigner(makeAddr("replacement"));
        automatic.revokeSignerEpoch(epoch, keccak256("incident"));
        OracleAttestation.Attestation memory a = _att(askId, true);
        assertFalse(intake.complete(verdictId, abi.encode(verdictId, a, _sign(a))));
        assertFalse(automatic.consumed(a.requestId));
        assertEq(automatic.reviewReceiptSignerEpoch(verdictId), 0);
        vm.expectRevert(AutoHookJobRequester.Revoked.selector);
        automatic.closeRevokedVerdict(jobId);
        vm.expectRevert(AutoHookJobRequester.DeadlineNotReached.selector);
        automatic.confirmReviewExpiry(verdictId);
        vm.warp(automatic.getAsk(askId).deadline + 1);
        vm.prank(creator);
        vm.expectRevert();
        automatic.confirmReviewExpiry(verdictId);
        automatic.confirmReviewExpiry(verdictId);
        vm.prank(creator);
        bytes32 retry = automatic.retryVerdict(jobId, FEE);
        assertNotEq(retry, askId);
        vm.roll(vm.getBlockNumber() + 8);
        bytes32 retryIntake = automatic.requestVerdict(retry);
        assertEq(uint32(automatic.getAsk(retry).verification >> 64), epoch + 1);
        assertEq(automatic.reviewReceiptSignerEpoch(retryIntake), 0);
    }

    function testFuzzFinalizedRevocationPreservesHistoryAndAllowsOnlyOwnerRecovery(bool passed, bool registry) public {
        if (registry) {
            automatic.setOracleSigner(address(new CallerBoundReceiptSigner(address(automatic), vm.addr(key))));
        }
        uint32 epoch = automatic.oracleSignerEpoch();
        _ready();
        automatic.setOracleSigner(makeAddr("replacement"));
        _answer(passed);
        AutoHookJobRequester.Ask memory receipt = automatic.getAsk(askId);
        assertEq(automatic.reviewReceiptSignerEpoch(verdictId), epoch);
        assertEq(automatic.approvedArtifact(jobId), passed ? automatic.candidateDigest(jobId) : bytes32(0));
        vm.expectRevert(AutoHookJobRequester.Revoked.selector);
        automatic.closeRevokedVerdict(jobId);
        automatic.revokeSignerEpoch(epoch, keccak256("incident"));
        assertEq(automatic.approvedArtifact(jobId), bytes32(0));
        vm.prank(creator);
        vm.expectRevert();
        automatic.closeRevokedVerdict(jobId);
        automatic.closeRevokedVerdict(jobId);
        assertTrue(automatic.revokedReviewReceipts(verdictId));
        assertEq(automatic.getAsk(askId).verification, receipt.verification);
        assertEq(automatic.getAsk(askId).oracleUUID, receipt.oracleUUID);
        assertTrue(automatic.consumed(receipt.oracleUUID));
        vm.prank(creator);
        automatic.retryVerdict(jobId, FEE);
        assertEq(automatic.reviewReceiptSignerEpoch(verdictId), epoch);
        assertEq(automatic.candidateDigest(jobId), gated.artifactDigest(artifact));
    }
}

contract AuditCodecCompositionTest is AutomaticFixture {
    function testComposedJobPreservesFullBodyHashAndConsumer() public {
        (jobId, askId) = _open();
        bytes memory expected = codec.jobBody(
            spec,
            HookSpecLib.hash(spec),
            askId,
            address(automatic),
            address(intake),
            address(gated),
            "A bounded swap hook"
        );
        assertEq(intake.bodyOf(jobId), expected);
        assertEq(automatic.getJob(jobId).bodyHash, keccak256(expected));
        assertEq(automatic.getJob(jobId).specHash, HookSpecLib.hash(spec));
        vm.prank(outsider);
        vm.expectRevert(HookRequestCodec.InvalidConfig.selector);
        codec.prepareJob(spec, askId, address(intake), address(gated), "A bounded swap hook");
        vm.prank(address(automatic));
        vm.expectRevert(abi.encodeWithSelector(HookRequestCodec.InvalidBrief.selector, 0));
        codec.prepareJob(spec, askId, address(intake), address(gated), '"');
    }

    function testComposedOraclePreservesQuestionPinAndBodyConsumer() public {
        _ready();
        AutoHookJobRequester.Ask memory a = automatic.getAsk(askId);
        bytes memory q = codec.question(
            block.chainid,
            address(intake),
            address(automatic),
            jobId,
            askId,
            automatic.getJob(jobId).specHash,
            automatic.getJob(jobId).resultHash,
            COMMIT,
            automatic.candidateDigest(jobId)
        );
        bytes memory p = codec.prefix(block.chainid, q);
        assertEq(automatic.questionPrefix(askId), p);
        assertEq(a.pin.code, bytes.concat(hex"00", p));
        assertEq(
            intake.bodyOf(verdictId),
            codec.oracleBody(block.chainid, address(automatic), q, a.fromBlock, a.toBlock, 7, 5)
        );
        assertEq(
            automatic.expectedQuestionHash(askId, a.fromBlock, a.toBlock),
            keccak256(codec.document(p, a.fromBlock, a.toBlock))
        );
        _answer(true);
    }

    function testWrongCodecCodehashRejectedBeforeTakingFunds() public {
        vm.etch(address(codec), hex"60006000f3");
        vm.prank(creator);
        vm.expectRevert(AutoHookJobRequester.NotConfigured.selector);
        automatic.openJob(spec, address(gated), "A bounded swap hook", FEE, FEE);
        assertEq(imd.balanceOf(creator), 100 ether);
        assertEq(imd.balanceOf(address(intake)), 0);
    }
}
