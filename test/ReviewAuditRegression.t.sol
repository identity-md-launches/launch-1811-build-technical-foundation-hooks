// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookJobRequesterFixture} from "./HookJobRequester.t.sol";
import {HookJobRequester} from "../src/imd/HookJobRequester.sol";
import {OracleAttestation} from "../src/imd/OracleAttestation.sol";
import {StoreAdmin} from "../src/store/StoreAdmin.sol";

/// @dev Audit ef1f6915 transaction-order and recovery regressions. Delivery uses Intake's
/// one-attempt 200k path. Expected contexts are synthetic fixtures, not live mapping evidence.
contract ReviewAuditRegressionTest is HookJobRequesterFixture {
    function _unbound() private returns (bytes32 jobId, bytes32 askId) {
        jobId = _delivered();
        vm.prank(creator);
        askId = requester.requestReview(jobId);
    }

    function _deliver(bytes32 askId, OracleAttestation.Attestation memory a) private returns (bool) {
        bytes memory payload = abi.encode(askId, a, _sign(a, signerKey));
        vm.cool(address(requester));
        vm.cool(signer);
        return intake.complete(askId, payload);
    }

    function _confirm(bytes32 askId, OracleAttestation.Attestation memory a) private {
        bytes32 bodyHash = requester.getReviewAsk(askId).bodyHash;
        vm.prank(owner);
        requester.bindReview(askId, bodyHash, a.requestId, a.questionHash, a.chainId, a.fromBlock, a.toBlock);
    }

    function _discard(bytes32 askId, OracleAttestation.Attestation memory a) private {
        bytes32 bodyHash = requester.getReviewAsk(askId).bodyHash;
        vm.prank(owner);
        requester.discardReviewReceipt(askId, bodyHash, a.requestId, a.questionHash, a.chainId, a.fromBlock, a.toBlock);
    }

    function _retryBlocked(bytes32 jobId) private {
        uint256 balance = imd.balanceOf(creator);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.NotReviewable.selector, jobId));
        requester.requestReview(jobId);
        assertEq(imd.balanceOf(creator), balance);
    }

    function testFuzzExpiryAndDeliveryBothOrdersPreserveVerdictAndBlockRetries(
        bool expiryFirst,
        bool prebound,
        bool passed
    ) public {
        (bytes32 jobId, bytes32 askId) = _unbound();
        if (prebound) _bind(askId);
        vm.warp(requester.getReviewAsk(askId).deadline + 1);
        // The adversary can see the signed value before choosing to request expiry.
        OracleAttestation.Attestation memory a = _attestation(askId, passed);
        bytes memory payload = abi.encode(askId, a, _sign(a, signerKey));
        if (expiryFirst) {
            vm.prank(creator);
            vm.expectEmit(true, true, false, true, address(requester));
            emit HookJobRequester.ReviewExpiryRequested(jobId, askId);
            requester.expireReview(jobId);
            assertTrue(requester.reviewExpiryRequested(askId));
            assertEq(uint8(_review(jobId)), uint8(HookJobRequester.ReviewStatus.Pending));
            assertEq(requester.reviewOf(askId), jobId);
            _retryBlocked(jobId);
        }
        assertTrue(_deliver(askId, a), "expiry request must not burn a late one-shot callback");
        if (!expiryFirst) {
            vm.prank(creator);
            vm.expectRevert(
                prebound
                    ? abi.encodeWithSelector(HookJobRequester.UnknownOrSettled.selector, jobId)
                    : abi.encodeWithSelector(HookJobRequester.ReviewAlreadyReceived.selector, askId)
            );
            requester.expireReview(jobId);
        } else {
            vm.prank(owner);
            vm.expectRevert(
                prebound
                    ? abi.encodeWithSelector(HookJobRequester.UnknownOrSettled.selector, askId)
                    : abi.encodeWithSelector(HookJobRequester.ReviewAlreadyReceived.selector, askId)
            );
            requester.confirmReviewExpiry(askId);
        }
        _retryBlocked(jobId);
        if (!prebound) _confirm(askId, a);
        assertEq(
            uint8(_review(jobId)),
            uint8(passed ? HookJobRequester.ReviewStatus.Passed : HookJobRequester.ReviewStatus.NotPassed)
        );
        assertTrue(requester.consumed(a.requestId));
        assertEq(requester.intakeReviewOfOracle(a.requestId), askId);
        _retryBlocked(jobId);
        vm.expectRevert("not pending");
        intake.complete(askId, payload);
        assertEq(imd.balanceOf(address(intake)), 2 * PRICE, "no second review fee");
    }

    function testExpiryRequestAllowsBindingBeforeLateDelivery() public {
        (bytes32 jobId, bytes32 askId) = _unbound();
        vm.warp(requester.getReviewAsk(askId).deadline + 1);
        vm.prank(creator);
        requester.expireReview(jobId);
        _bind(askId);
        assertTrue(_deliver(askId, _attestation(askId, false)));
        assertEq(uint8(_review(jobId)), uint8(HookJobRequester.ReviewStatus.NotPassed));
        _retryBlocked(jobId);
    }

    function testExpiryNeedsRequesterDeadlineAndCurrentOwnerApprovalForExactAsk() public {
        (bytes32 jobId, bytes32 askId) = _unbound();
        uint64 deadline = requester.getReviewAsk(askId).deadline;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.ReviewExpiryNotRequested.selector, askId));
        requester.confirmReviewExpiry(askId);
        vm.warp(deadline);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.DeadlineNotReached.selector, deadline));
        requester.expireReview(jobId);
        vm.warp(uint256(deadline) + 1);
        vm.prank(stranger);
        vm.expectRevert(HookJobRequester.NotRequester.selector);
        requester.expireReview(jobId);
        vm.prank(creator);
        requester.expireReview(jobId);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.ReviewExpiryAlreadyRequested.selector, askId));
        requester.expireReview(jobId);
        address[3] memory unauthorized = [creator, stranger, address(intake)];
        for (uint256 i; i < unauthorized.length; ++i) {
            vm.prank(unauthorized[i]);
            vm.expectRevert(StoreAdmin.NotOwner.selector);
            requester.confirmReviewExpiry(askId);
        }
        _retryBlocked(jobId);
        vm.prank(owner);
        requester.transferOwnership(stranger);
        vm.prank(stranger);
        requester.acceptOwnership();
        vm.prank(owner);
        vm.expectRevert(StoreAdmin.NotOwner.selector);
        requester.confirmReviewExpiry(askId);
        uint256 balance = imd.balanceOf(creator);
        vm.prank(stranger);
        vm.expectEmit(true, true, false, true, address(requester));
        emit HookJobRequester.ReviewUnanswered(jobId, askId, 0, "owner confirmed expiry");
        requester.confirmReviewExpiry(askId);
        assertEq(imd.balanceOf(creator), balance, "closure charges and refunds nothing");
        assertEq(requester.reviewOf(askId), bytes32(0));
        assertTrue(requester.usedIntakeRequestIds(askId));
        assertEq(uint8(_review(jobId)), uint8(HookJobRequester.ReviewStatus.Unanswered));
        vm.prank(creator);
        bytes32 retry = requester.requestReview(jobId);
        assertFalse(requester.reviewExpiryRequested(retry), "approval cannot carry to a retry");
        vm.warp(requester.getReviewAsk(retry).deadline + 1);
        vm.startPrank(stranger);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.UnknownOrSettled.selector, askId));
        requester.confirmReviewExpiry(askId);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.ReviewExpiryNotRequested.selector, retry));
        requester.confirmReviewExpiry(retry);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.UnknownOrSettled.selector, bytes32(0)));
        requester.confirmReviewExpiry(bytes32(0));
        vm.stopPrank();
        // An owner-confirmed terminal ask cannot settle its retry or reuse the old Intake ID.
        assertFalse(_deliver(askId, _attestation(askId, true)));
        assertTrue(_deliver(retry, _attestation(retry, false)));
        assertEq(requester.reviewOf(retry), jobId);
        assertEq(imd.balanceOf(creator), balance - PRICE);
    }

    function testIntakeFailureAfterExpiryRequestAllowsRetryAndInvalidatesOldApproval() public {
        (bytes32 jobId, bytes32 askId) = _unbound();
        vm.warp(requester.getReviewAsk(askId).deadline + 1);
        vm.prank(creator);
        requester.expireReview(jobId);
        assertTrue(intake.fail(askId, 2, "no answer", 0, 0));
        bytes32 retry = _requestReview(jobId);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.UnknownOrSettled.selector, askId));
        requester.confirmReviewExpiry(askId);
        assertTrue(_deliver(retry, _attestation(retry, false)));
        assertEq(uint8(_review(jobId)), uint8(HookJobRequester.ReviewStatus.NotPassed));
    }

    function testFuzzExactConflictRecoveryPreservesOtherAskAndReplayProtection(
        bool consumeOther,
        bool receiptBeforeReservation,
        bool passed
    ) public {
        (, bytes32 askA) = _unbound();
        (bytes32 jobB, bytes32 askB) = _unbound();
        OracleAttestation.Attestation memory a = _attestation(askA, true);
        OracleAttestation.Attestation memory b = _attestation(askB, passed);
        b.requestId = a.requestId; // Protocol collision: each ask still has its own question.
        if (receiptBeforeReservation) assertTrue(_deliver(askB, b));
        _confirm(askA, a);
        if (!receiptBeforeReservation) assertTrue(_deliver(askB, b));
        if (consumeOther) assertTrue(_deliver(askA, a));
        bytes32 bodyB = requester.getReviewAsk(askB).bodyHash;
        bytes32 receiptHash = keccak256(abi.encode(requester.getReviewReceipt(askB)));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.DuplicateRequestId.selector, a.requestId));
        requester.bindReview(askB, bodyB, b.requestId, b.questionHash, b.chainId, b.fromBlock, b.toBlock);
        vm.prank(creator);
        vm.expectRevert(StoreAdmin.NotOwner.selector);
        requester.discardReviewReceipt(askB, bodyB, b.requestId, b.questionHash, b.chainId, b.fromBlock, b.toBlock);
        _retryBlocked(jobB);
        vm.expectEmit(true, true, true, true, address(requester));
        emit HookJobRequester.ReviewReceiptDiscarded(
            jobB, askB, b.requestId, b.requestId, b.questionHash, b.chainId, b.fromBlock, b.toBlock
        );
        vm.expectEmit(true, true, false, true, address(requester));
        emit HookJobRequester.ReviewUnanswered(jobB, askB, 0, "receipt UUID conflict");
        _discard(askB, b);
        assertEq(keccak256(abi.encode(requester.getReviewReceipt(askB))), receiptHash);
        assertTrue(requester.discardedReviewReceipts(askB));
        assertTrue(requester.usedIntakeRequestIds(askB));
        assertEq(requester.reviewOf(askB), bytes32(0));
        assertEq(requester.getReviewAsk(askB).oracleRequestId, bytes32(0));
        assertEq(requester.intakeReviewOfOracle(a.requestId), askA);
        assertEq(requester.consumed(a.requestId), consumeOther);
        assertEq(uint8(_review(jobB)), uint8(HookJobRequester.ReviewStatus.Unanswered));
        if (!consumeOther) assertTrue(_deliver(askA, a));
        assertTrue(requester.consumed(a.requestId));
        bytes32 retry = _requestReview(jobB);
        assertTrue(_deliver(retry, _attestation(retry, false)));
        assertEq(uint8(_review(jobB)), uint8(HookJobRequester.ReviewStatus.NotPassed));
        bytes memory signature = _sign(b, signerKey);
        vm.prank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.UnknownOrSettled.selector, askB));
        requester.onReviewResult(askB, b, signature);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.ReservationNotReleasable.selector, a.requestId));
        requester.releaseReservation(a.requestId);
    }

    function testFuzzSameUuidTypoCannotDiscardGenuineNegativeEvenWithConflict(uint8 field, bool conflict) public {
        field = uint8(bound(field, 0, 3));
        (bytes32 jobId, bytes32 askId) = _unbound();
        OracleAttestation.Attestation memory a = _attestation(askId, false);
        assertTrue(_deliver(askId, a));
        if (conflict) {
            (, bytes32 other) = _unbound();
            OracleAttestation.Attestation memory b = _attestation(other, true);
            b.requestId = a.requestId;
            _confirm(other, b);
        }
        bytes32 receiptHash = keccak256(abi.encode(requester.getReviewReceipt(askId)));
        OracleAttestation.Attestation memory typo = _attestation(askId, false);
        if (field == 0) typo.questionHash ^= bytes32(uint256(1));
        if (field == 1) typo.chainId++;
        if (field == 2) typo.fromBlock--;
        if (field == 3) typo.toBlock++;
        bytes32 body = requester.getReviewAsk(askId).bodyHash;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.ReviewAttestationMismatch.selector, askId));
        requester.discardReviewReceipt(
            askId, body, typo.requestId, typo.questionHash, typo.chainId, typo.fromBlock, typo.toBlock
        );
        assertEq(keccak256(abi.encode(requester.getReviewReceipt(askId))), receiptHash);
        assertFalse(requester.discardedReviewReceipts(askId));
        assertEq(uint8(_review(jobId)), uint8(HookJobRequester.ReviewStatus.Pending));
        _retryBlocked(jobId);
        if (conflict) {
            _discard(askId, a);
        } else {
            _confirm(askId, a);
            assertEq(uint8(_review(jobId)), uint8(HookJobRequester.ReviewStatus.NotPassed));
        }
    }

    function testFuzzUnavailableDifferentTrueUuidCannotDiscardGenuineNegative(uint8 holderState) public {
        holderState = uint8(bound(holderState, 0, 2)); // pending, terminal unused, consumed
        (bytes32 jobId, bytes32 askId) = _unbound();
        OracleAttestation.Attestation memory a = _attestation(askId, false);
        assertTrue(_deliver(askId, a));
        (, bytes32 other) = _reviewPending();
        OracleAttestation.Attestation memory b = _attestation(other, true);
        if (holderState == 1) assertTrue(intake.fail(other, 2, "no answer", 0, 0));
        if (holderState == 2) assertTrue(_deliver(other, b));
        bytes32 body = requester.getReviewAsk(askId).bodyHash;
        bytes32 receiptHash = keccak256(abi.encode(requester.getReviewReceipt(askId)));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.DuplicateRequestId.selector, b.requestId));
        requester.discardReviewReceipt(askId, body, b.requestId, b.questionHash, b.chainId, b.fromBlock, b.toBlock);
        assertEq(keccak256(abi.encode(requester.getReviewReceipt(askId))), receiptHash);
        assertFalse(requester.discardedReviewReceipts(askId));
        assertEq(requester.intakeReviewOfOracle(b.requestId), other);
        assertEq(requester.consumed(b.requestId), holderState == 2);
        _retryBlocked(jobId);
        _confirm(askId, a);
        assertEq(uint8(_review(jobId)), uint8(HookJobRequester.ReviewStatus.NotPassed));
    }
}
