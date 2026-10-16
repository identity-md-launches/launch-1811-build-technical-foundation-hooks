// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookJobRequesterFixture} from "./HookJobRequester.t.sol";
import {HookJobRequester} from "../src/imd/HookJobRequester.sol";
import {OracleAttestation, OracleAttestationConsumer} from "../src/imd/OracleAttestation.sol";
import {StoreAdmin} from "../src/store/StoreAdmin.sol";

/// @dev Regressions for audit 1053af02: requester verdict shopping, misdelivery recovery,
/// unused reservations, and the two deliberately retained historical-verdict policies.
contract ReviewRecoveryTest is HookJobRequesterFixture {
    function _unbound() internal returns (bytes32 jobId, bytes32 askId) {
        jobId = _delivered();
        vm.prank(creator);
        askId = requester.requestReview(jobId);
    }

    function _deliver(bytes32 askId, OracleAttestation.Attestation memory a) internal returns (bool) {
        bytes memory signature = _sign(a, signerKey);
        vm.cool(address(requester));
        vm.cool(signer);
        return intake.complete(askId, abi.encode(askId, a, signature));
    }

    function _confirm(bytes32 askId, OracleAttestation.Attestation memory a) internal {
        bytes32 bodyHash = requester.getReviewAsk(askId).bodyHash;
        vm.prank(owner);
        requester.bindReview(askId, bodyHash, a.requestId, a.questionHash, a.chainId, a.fromBlock, a.toBlock);
    }

    function _discard(bytes32 askId, OracleAttestation.Attestation memory authentic) internal {
        bytes32 bodyHash = requester.getReviewAsk(askId).bodyHash;
        vm.prank(owner);
        requester.discardReviewReceipt(
            askId,
            bodyHash,
            authentic.requestId,
            authentic.questionHash,
            authentic.chainId,
            authentic.fromBlock,
            authentic.toBlock
        );
    }

    function testLateNotPassedReceiptCannotBeFrontRunByRequesterExpiry() public {
        (bytes32 jobId, bytes32 askId) = _unbound();
        vm.warp(requester.getReviewAsk(askId).deadline + 1);
        OracleAttestation.Attestation memory a = _attestation(askId, false);
        assertTrue(_deliver(askId, a));
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.ReviewAlreadyReceived.selector, askId));
        requester.expireReview(jobId);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.NotReviewable.selector, jobId));
        requester.requestReview(jobId);
        _confirm(askId, a);
        assertEq(uint8(_review(jobId)), uint8(HookJobRequester.ReviewStatus.NotPassed));
        assertTrue(requester.consumed(a.requestId));
    }

    function testSwappedReceiptOwnerClosesWrongAskWithoutStrandingGenuineUuid() public {
        (bytes32 jobA, bytes32 askA) = _unbound();
        (bytes32 jobB, bytes32 askB) = _unbound();
        OracleAttestation.Attestation memory a = _attestation(askA, false);
        OracleAttestation.Attestation memory b = _attestation(askB, true);
        assertTrue(_deliver(askA, b));
        bytes32 bodyA = requester.getReviewAsk(askA).bodyHash;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.ReviewAttestationMismatch.selector, askA));
        requester.bindReview(askA, bodyA, a.requestId, a.questionHash, a.chainId, a.fromBlock, a.toBlock);
        bytes memory payload = abi.encode(askA, a, _sign(a, signerKey));
        vm.expectRevert("not pending");
        intake.complete(askA, payload);
        bytes32 receiptHash = keccak256(abi.encode(requester.getReviewReceipt(askA)));
        uint256 paidBalance = imd.balanceOf(creator);
        vm.expectEmit(true, true, true, true, address(requester));
        emit HookJobRequester.ReviewReceiptDiscarded(
            jobA, askA, b.requestId, a.requestId, a.questionHash, a.chainId, a.fromBlock, a.toBlock
        );
        vm.expectEmit(true, true, false, true, address(requester));
        emit HookJobRequester.ReviewUnanswered(jobA, askA, 0, "misdelivered receipt");
        _discard(askA, a);
        assertEq(imd.balanceOf(creator), paidBalance, "owner recovery charges no fee and creates no refund");
        assertEq(imd.balanceOf(address(intake)), 4 * PRICE);
        assertEq(keccak256(abi.encode(requester.getReviewReceipt(askA))), receiptHash, "history retained");
        assertTrue(requester.discardedReviewReceipts(askA));
        assertEq(uint8(_review(jobA)), uint8(HookJobRequester.ReviewStatus.Unanswered));
        assertEq(requester.reviewOf(askA), bytes32(0));
        assertEq(requester.getReviewAsk(askA).oracleRequestId, bytes32(0));
        assertTrue(requester.usedIntakeRequestIds(askA));
        assertFalse(requester.consumed(a.requestId));
        assertFalse(requester.consumed(b.requestId));
        assertEq(requester.intakeReviewOfOracle(b.requestId), bytes32(0));
        assertTrue(_deliver(askB, b));
        _confirm(askB, b);
        assertEq(uint8(_review(jobB)), uint8(HookJobRequester.ReviewStatus.Passed));
        assertEq(requester.intakeReviewOfOracle(b.requestId), askB);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.UnknownOrSettled.selector, askA));
        requester.bindReview(askA, bodyA, b.requestId, b.questionHash, b.chainId, b.fromBlock, b.toBlock);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.UnknownOrSettled.selector, askA));
        requester.discardReviewReceipt(askA, bodyA, a.requestId, a.questionHash, a.chainId, a.fromBlock, a.toBlock);
        bytes memory sig = _sign(a, signerKey);
        vm.startPrank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.UnknownOrSettled.selector, askA));
        requester.onReviewResult(askA, a, sig);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.UnknownOrSettled.selector, askA));
        requester.onReviewFailure(askA, 2, "late", 0, 0, "");
        vm.stopPrank();

        // Closing the ask is free. A replacement protocol request still has its normal price.
        bytes32 retry = _requestReview(jobA);
        assertNotEq(retry, askA);
        assertEq(imd.balanceOf(creator), paidBalance - PRICE);
        assertTrue(_deliver(retry, _attestation(retry, false)));
        assertEq(uint8(_review(jobA)), uint8(HookJobRequester.ReviewStatus.NotPassed));
    }

    function testDiscardingDuplicateReceiptDoesNotClearGenuineConsumedUuid() public {
        (, bytes32 askA) = _unbound();
        (, bytes32 askB) = _unbound();
        OracleAttestation.Attestation memory a = _attestation(askA, false);
        assertTrue(_deliver(askB, a));
        assertTrue(_deliver(askA, a));
        _confirm(askA, a);
        _discard(askB, _attestation(askB, true));
        assertTrue(requester.consumed(a.requestId));
        assertEq(requester.intakeReviewOfOracle(a.requestId), askA);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.ReservationNotReleasable.selector, a.requestId));
        requester.releaseReservation(a.requestId);
    }

    function testFuzzOwnerCannotDiscardReceiptWithMatchingContext(bool passed) public {
        (, bytes32 askId) = _unbound();
        OracleAttestation.Attestation memory a = _attestation(askId, passed);
        assertTrue(_deliver(askId, a));
        vm.warp(requester.getReviewAsk(askId).deadline + 30 days);
        bytes32 bodyHash = requester.getReviewAsk(askId).bodyHash;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.ReviewReceiptMatches.selector, askId));
        requester.discardReviewReceipt(askId, bodyHash, a.requestId, a.questionHash, a.chainId, a.fromBlock, a.toBlock);
        assertFalse(requester.discardedReviewReceipts(askId));
        _confirm(askId, a);
    }

    function testFuzzSameUuidFieldMismatchCannotDiscardReceipt(uint8 field) public {
        field = uint8(bound(field, 1, 4));
        (bytes32 jobId, bytes32 askId) = _unbound();
        OracleAttestation.Attestation memory misdelivered = _attestation(askId, false);
        if (field == 1) misdelivered.questionHash ^= bytes32(uint256(1));
        if (field == 2) misdelivered.chainId++;
        if (field == 3) misdelivered.fromBlock--;
        if (field == 4) misdelivered.toBlock++;
        assertTrue(_deliver(askId, misdelivered));
        OracleAttestation.Attestation memory authentic = _attestation(askId, false);
        bytes32 bodyHash = requester.getReviewAsk(askId).bodyHash;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.ReviewAttestationMismatch.selector, askId));
        requester.discardReviewReceipt(
            askId,
            bodyHash,
            authentic.requestId,
            authentic.questionHash,
            authentic.chainId,
            authentic.fromBlock,
            authentic.toBlock
        );
        assertEq(uint8(_review(jobId)), uint8(HookJobRequester.ReviewStatus.Pending));
        assertFalse(requester.discardedReviewReceipts(askId));
        assertFalse(requester.consumed(misdelivered.requestId));
        assertEq(requester.getReviewReceipt(askId).oracleRequestId, misdelivered.requestId);
    }

    function testRecoveryRequiresCurrentOwnerExactBodyValidContextAndReceipt() public {
        (, bytes32 askId) = _unbound();
        OracleAttestation.Attestation memory a = _attestation(askId, false);
        bytes32 bodyHash = requester.getReviewAsk(askId).bodyHash;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.ReviewNotReceived.selector, askId));
        requester.discardReviewReceipt(askId, bodyHash, a.requestId, a.questionHash, a.chainId, 1, 2);
        assertTrue(_deliver(askId, a));
        bytes32 authenticId = keccak256("independently authenticated different UUID fixture");
        address[3] memory unauthorized = [creator, stranger, address(intake)];
        for (uint256 i; i < unauthorized.length; ++i) {
            vm.prank(unauthorized[i]);
            vm.expectRevert(StoreAdmin.NotOwner.selector);
            requester.discardReviewReceipt(askId, bodyHash, authenticId, a.questionHash, a.chainId, 1, 2);
        }
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.ReviewBodyMismatch.selector, bodyHash, bytes32(0)));
        requester.discardReviewReceipt(askId, bytes32(0), authenticId, a.questionHash, a.chainId, 1, 2);
        vm.expectRevert(HookJobRequester.InvalidReviewBinding.selector);
        requester.discardReviewReceipt(askId, bodyHash, bytes32(0), a.questionHash, a.chainId, 1, 2);
        vm.expectRevert(HookJobRequester.InvalidReviewBinding.selector);
        requester.discardReviewReceipt(askId, bodyHash, authenticId, bytes32(0), a.chainId, 1, 2);
        vm.expectRevert(HookJobRequester.InvalidReviewBinding.selector);
        requester.discardReviewReceipt(askId, bodyHash, authenticId, a.questionHash, 0, 1, 2);
        vm.expectRevert(HookJobRequester.InvalidReviewBinding.selector);
        requester.discardReviewReceipt(askId, bodyHash, authenticId, a.questionHash, a.chainId, 2, 1);
        requester.transferOwnership(stranger);
        vm.stopPrank();
        vm.prank(stranger);
        requester.acceptOwnership();
        vm.prank(owner);
        vm.expectRevert(StoreAdmin.NotOwner.selector);
        requester.discardReviewReceipt(askId, bodyHash, authenticId, a.questionHash, a.chainId, 1, 2);
        vm.prank(stranger);
        requester.discardReviewReceipt(askId, bodyHash, authenticId, a.questionHash, a.chainId, 1, 2);
        assertTrue(requester.discardedReviewReceipts(askId));
    }

    function testBoundOrTerminalAsksCannotBeDiscarded() public {
        (bytes32 job, bytes32 ask) = _reviewPending();
        OracleAttestation.Attestation memory a = _attestation(ask, false);
        bytes32 bodyHash = requester.getReviewAsk(ask).bodyHash;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.ReviewAlreadyBound.selector, ask));
        requester.discardReviewReceipt(ask, bodyHash, a.requestId, a.questionHash, a.chainId, 0, 2);
        assertTrue(_deliver(ask, a));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.UnknownOrSettled.selector, ask));
        requester.discardReviewReceipt(ask, bodyHash, a.requestId, a.questionHash, a.chainId, 0, 2);
        assertEq(uint8(_review(job)), uint8(HookJobRequester.ReviewStatus.NotPassed));
    }

    function testFuzzReleaseUnusedReservationAfterExpiryOrFailureThenFinalizeRetry(bool failure, bool receiptFirst)
        public
    {
        (bytes32 jobId, bytes32 askId) = _reviewPending();
        OracleAttestation.Attestation memory old = _attestation(askId, true);
        if (failure) {
            assertTrue(intake.fail(askId, 2, "no answer", 0, 0));
        } else {
            vm.warp(requester.getReviewAsk(askId).deadline + 1);
            vm.prank(creator);
            requester.expireReview(jobId);
            _confirmExpiry(askId);
        }
        vm.prank(creator);
        bytes32 retry = requester.requestReview(jobId);
        OracleAttestation.Attestation memory a = _attestation(retry, false);
        a.requestId = old.requestId; // Simulate authenticated protocol UUID reuse for this retry.
        bytes32 retryBody = requester.getReviewAsk(retry).bodyHash;
        bytes memory signature = _sign(a, signerKey);
        // An unreleased reservation must not consume the retry's sole callback attempt.
        if (receiptFirst) assertTrue(_deliver(retry, a));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.DuplicateRequestId.selector, a.requestId));
        requester.bindReview(retry, retryBody, a.requestId, a.questionHash, a.chainId, a.fromBlock, a.toBlock);
        vm.prank(creator);
        vm.expectRevert(StoreAdmin.NotOwner.selector);
        requester.releaseReservation(a.requestId);
        uint256 balance = imd.balanceOf(creator);
        vm.prank(owner);
        vm.expectEmit(true, true, false, true, address(requester));
        emit HookJobRequester.ReviewReservationReleased(a.requestId, askId);
        requester.releaseReservation(a.requestId);
        assertEq(imd.balanceOf(creator), balance);
        assertEq(requester.intakeReviewOfOracle(a.requestId), bytes32(0));
        assertFalse(requester.consumed(a.requestId));
        assertTrue(requester.usedIntakeRequestIds(askId));
        assertEq(requester.getReviewAsk(askId).oracleRequestId, a.requestId, "old binding history retained");
        assertEq(requester.reviewOf(askId), bytes32(0));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.ReservationNotReleasable.selector, a.requestId));
        requester.releaseReservation(a.requestId);
        vm.prank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.UnknownOrSettled.selector, askId));
        requester.onReviewResult(askId, a, signature);

        _confirm(retry, a);
        if (!receiptFirst) assertTrue(_deliver(retry, a));
        assertEq(uint8(_review(jobId)), uint8(HookJobRequester.ReviewStatus.NotPassed));
        assertEq(requester.intakeReviewOfOracle(a.requestId), retry);
        assertTrue(requester.consumed(a.requestId));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.ReservationNotReleasable.selector, a.requestId));
        requester.releaseReservation(a.requestId);
        // The completed retry cannot be released, and its UUID cannot be replayed into another ask.
        (, bytes32 other) = _unbound();
        assertFalse(_deliver(other, a));
        assertEq(requester.getReviewReceipt(other).oracleRequestId, bytes32(0));
    }

    function testReservationReleaseRejectsUnknownUnboundAndPendingHolderEvenPastDeadline() public {
        (, bytes32 unbound) = _unbound();
        (bytes32 jobId, bytes32 boundAsk) = _reviewPending();
        bytes32 boundId = requester.getReviewAsk(boundAsk).oracleRequestId;
        vm.warp(requester.getReviewAsk(boundAsk).deadline + 1);
        vm.prank(creator);
        requester.expireReview(jobId);
        assertTrue(requester.reviewExpiryRequested(boundAsk));
        assertEq(requester.reviewOf(boundAsk), jobId, "requesting expiry does not make a reservation releasable");
        bytes32[3] memory ids = [bytes32(0), _attestation(unbound, true).requestId, boundId];
        vm.startPrank(owner);
        for (uint256 i; i < ids.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(HookJobRequester.ReservationNotReleasable.selector, ids[i]));
            requester.releaseReservation(ids[i]);
        }
        vm.stopPrank();
        assertEq(requester.intakeReviewOfOracle(boundId), boundAsk);
    }

    function testSignerRotationPreservesRetainedVerificationButRejectsUndeliveredOldSignature() public {
        (bytes32 jobA, bytes32 askA) = _unbound();
        (bytes32 jobB, bytes32 askB) = _reviewPending();
        OracleAttestation.Attestation memory a = _attestation(askA, true);
        OracleAttestation.Attestation memory b = _attestation(askB, true);
        assertTrue(_deliver(askA, a));
        vm.prank(owner);
        requester.setOracleSigner(stranger);
        _confirm(askA, a);
        assertEq(uint8(_review(jobA)), uint8(HookJobRequester.ReviewStatus.Passed));
        assertFalse(_deliver(askB, b));
        assertEq(uint8(_review(jobB)), uint8(HookJobRequester.ReviewStatus.Pending));
        assertFalse(requester.consumed(b.requestId));
    }

    function testExpiredJobFalseVerdictRemainsTerminalEvenIfReviewLaterCompletes() public {
        bytes32 jobId = _open();
        vm.warp(requester.getJob(jobId).deadline + 1);
        vm.prank(creator);
        requester.expireJob(jobId);
        vm.prank(creator);
        bytes32 askId = requester.requestReview(jobId);
        OracleAttestation.Attestation memory a = _attestation(askId, false);
        assertTrue(_deliver(askId, a));
        _confirm(askId, a);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.NotReviewable.selector, jobId));
        requester.requestReview(jobId);
        vm.prank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.UnknownOrSettled.selector, jobId));
        requester.onJobResult(jobId, "later review passed");
        assertEq(uint8(_review(jobId)), uint8(HookJobRequester.ReviewStatus.NotPassed));
        assertEq(imd.balanceOf(address(intake)), 2 * PRICE);
    }
}
