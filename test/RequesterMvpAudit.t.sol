// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookJobRequesterFixture} from "./HookJobRequester.t.sol";
import {HookJobRequester} from "../src/imd/HookJobRequester.sol";
import {OracleAttestation, OracleAttestationConsumer} from "../src/imd/OracleAttestation.sol";
import {StoreAdmin} from "../src/store/StoreAdmin.sol";
import {ExactStoreToken} from "../src/store/ExactStoreToken.sol";
import {StoreTokenMock} from "./helpers/StoreTokenMock.sol";

contract RequesterMvpLifecycleTest is HookJobRequesterFixture {
    function _unbound() private returns (bytes32 jobId, bytes32 askId) {
        jobId = _delivered();
        vm.prank(creator);
        askId = requester.requestReview(jobId, PRICE);
    }

    function _confirm(bytes32 askId, OracleAttestation.Attestation memory a) private {
        bytes32 bodyHash = requester.getReviewAsk(askId).bodyHash;
        vm.prank(owner);
        requester.bindReview(askId, bodyHash, a.requestId, a.questionHash, a.chainId, a.fromBlock, a.toBlock);
    }

    function _deliver(bytes32 askId, OracleAttestation.Attestation memory a) private returns (bool) {
        bytes memory payload = abi.encode(askId, a, _sign(a, signerKey));
        vm.cool(address(requester));
        return intake.complete(askId, payload);
    }

    function testFuzzJobFailureAndExpiryOrderingCannotChangeReviewEligibility(uint8 order, bool passed) public {
        order = uint8(bound(order, 0, 2));
        bytes32 jobId = _open();
        vm.warp(requester.getJob(jobId).deadline + 1);
        bytes32 askId;
        if (order != 0) {
            vm.prank(creator);
            requester.expireJob(jobId);
            if (order == 2) askId = _requestReview(jobId);
        }
        // Real one-shot failure, including after expiry or after the review was already paid for.
        vm.cool(address(requester));
        assertTrue(intake.fail(jobId, 2, "build_failed", 0, 0));
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.UnknownOrSettled.selector, jobId));
        requester.expireJob(jobId);
        if (order != 2) askId = _requestReview(jobId);
        assertEq(uint8(_status(jobId)), uint8(HookJobRequester.JobStatus.Failed));
        assertEq(requester.getJob(jobId).failureReason, bytes32("build_failed"));
        assertEq(uint8(_review(jobId)), uint8(HookJobRequester.ReviewStatus.Pending));
        assertTrue(_deliver(askId, _attestation(askId, passed)));
        assertEq(
            uint8(_review(jobId)),
            uint8(passed ? HookJobRequester.ReviewStatus.Passed : HookJobRequester.ReviewStatus.NotPassed)
        );
        assertEq(imd.balanceOf(address(intake)), 2 * PRICE);
        vm.prank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.UnknownOrSettled.selector, jobId));
        requester.onJobFailure(jobId, 1, "duplicate", 0, 0, "");
    }

    function testLateFailureCannotClearFinalizedNegativeReview() public {
        bytes32 jobId = _open();
        vm.warp(requester.getJob(jobId).deadline + 1);
        vm.prank(creator);
        requester.expireJob(jobId);
        bytes32 askId = _requestReview(jobId);
        OracleAttestation.Attestation memory a = _attestation(askId, false);
        assertTrue(_deliver(askId, a));
        assertTrue(intake.fail(jobId, 2, "late_failure", 0, 0));
        assertEq(uint8(_review(jobId)), uint8(HookJobRequester.ReviewStatus.NotPassed));
        assertTrue(requester.consumed(a.requestId));
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.NotReviewable.selector, jobId));
        requester.requestReview(jobId, PRICE);
    }

    function testFuzzWrongPrebindingRetainsOneShotAnswerAndCanBeCorrected(uint8 field, bool passed) public {
        field = uint8(bound(field, 0, 4));
        (bytes32 jobId, bytes32 askId) = _unbound();
        OracleAttestation.Attestation memory wrong = _attestation(askId, passed);
        if (field == 0) wrong.requestId = keccak256("operator UUID typo");
        if (field == 1) wrong.questionHash = keccak256("operator question typo");
        if (field == 2) ++wrong.chainId;
        if (field == 3) wrong.fromBlock = 0;
        if (field == 4) ++wrong.toBlock;
        _confirm(askId, wrong);
        OracleAttestation.Attestation memory a = _attestation(askId, passed);
        assertTrue(_deliver(askId, a), "mismatched pre-binding must not burn one-shot answer");
        bytes memory history = abi.encode(requester.getReviewReceipt(askId));
        assertEq(requester.getReviewReceipt(askId).oracleRequestId, a.requestId);
        assertEq(uint8(_review(jobId)), uint8(HookJobRequester.ReviewStatus.Pending));
        assertFalse(requester.consumed(a.requestId));
        assertFalse(requester.consumed(wrong.requestId));
        assertEq(requester.intakeReviewOfOracle(wrong.requestId), askId);
        bytes memory payload = abi.encode(askId, a, _sign(a, signerKey));
        vm.expectRevert("not pending");
        intake.complete(askId, payload);
        vm.warp(requester.getReviewAsk(askId).deadline + 1);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.ReviewAlreadyReceived.selector, askId));
        requester.expireReview(jobId);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.ReviewAlreadyReceived.selector, askId));
        requester.confirmReviewExpiry(askId);
        bytes32 bodyHash = requester.getReviewAsk(askId).bodyHash;
        vm.prank(owner);
        requester.resetReviewBinding(askId, bodyHash);
        assertEq(requester.intakeReviewOfOracle(wrong.requestId), bytes32(0));
        _confirm(askId, a); // Delayed confirmation does not need a fresh signature or fee.
        assertEq(
            uint8(_review(jobId)),
            uint8(passed ? HookJobRequester.ReviewStatus.Passed : HookJobRequester.ReviewStatus.NotPassed)
        );
        assertTrue(requester.consumed(a.requestId));
        assertEq(abi.encode(requester.getReviewReceipt(askId)), history);
        assertEq(imd.balanceOf(address(intake)), 2 * PRICE);
    }

    function testBindingResetRequiresOwnerExactBodyAndPendingBoundAsk() public {
        (bytes32 jobId, bytes32 askId) = _unbound();
        bytes32 body = requester.getReviewAsk(askId).bodyHash;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.ReviewNotBound.selector, askId));
        requester.resetReviewBinding(askId, body);
        _bind(askId);
        vm.prank(creator);
        vm.expectRevert(StoreAdmin.NotOwner.selector);
        requester.resetReviewBinding(askId, body);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.ReviewBodyMismatch.selector, body, bytes32(0)));
        requester.resetReviewBinding(askId, bytes32(0));
        vm.prank(owner);
        requester.resetReviewBinding(askId, body); // Correction can also precede arrival.
        OracleAttestation.Attestation memory a = _attestation(askId, false);
        assertTrue(_deliver(askId, a));
        _confirm(askId, a);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.UnknownOrSettled.selector, askId));
        requester.resetReviewBinding(askId, body);
        assertEq(uint8(_review(jobId)), uint8(HookJobRequester.ReviewStatus.NotPassed));
        assertTrue(requester.consumed(a.requestId));
    }

    function testSwappedPreboundDeliveriesStayPendingAndNeverConsumeEachOthersUuid() public {
        (bytes32 jobA, bytes32 askA) = _reviewPending();
        (bytes32 jobB, bytes32 askB) = _reviewPending();
        OracleAttestation.Attestation memory a = _attestation(askA, false);
        OracleAttestation.Attestation memory b = _attestation(askB, true);
        assertTrue(_deliver(askA, b));
        assertTrue(_deliver(askB, a));
        bytes32 bodyA = requester.getReviewAsk(askA).bodyHash;
        bytes32 bodyB = requester.getReviewAsk(askB).bodyHash;
        vm.startPrank(owner);
        requester.resetReviewBinding(askA, bodyA);
        requester.resetReviewBinding(askB, bodyB);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.ReviewAttestationMismatch.selector, askA));
        requester.bindReview(askA, bodyA, a.requestId, a.questionHash, a.chainId, a.fromBlock, a.toBlock);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.ReviewAttestationMismatch.selector, askB));
        requester.bindReview(askB, bodyB, b.requestId, b.questionHash, b.chainId, b.fromBlock, b.toBlock);
        // True contexts differ in UUID: existing guarded misdelivery recovery remains usable.
        requester.discardReviewReceipt(askA, bodyA, a.requestId, a.questionHash, a.chainId, a.fromBlock, a.toBlock);
        requester.discardReviewReceipt(askB, bodyB, b.requestId, b.questionHash, b.chainId, b.fromBlock, b.toBlock);
        vm.stopPrank();
        assertFalse(requester.consumed(a.requestId));
        assertFalse(requester.consumed(b.requestId));
        assertEq(uint8(_review(jobA)), uint8(HookJobRequester.ReviewStatus.Unanswered));
        assertEq(uint8(_review(jobB)), uint8(HookJobRequester.ReviewStatus.Unanswered));
        assertEq(requester.getReviewReceipt(askA).oracleRequestId, b.requestId);
    }

    function testOwnerClosesAbandonedAskOnlyAfterDeadlineAndCannotCloseItsRetry() public {
        (bytes32 jobId, bytes32 askId) = _reviewPending();
        uint64 deadline = requester.getReviewAsk(askId).deadline;
        vm.warp(deadline);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.DeadlineNotReached.selector, deadline));
        requester.confirmReviewExpiry(askId);
        vm.warp(uint256(deadline) + 1);
        vm.prank(creator);
        vm.expectRevert(StoreAdmin.NotOwner.selector);
        requester.confirmReviewExpiry(askId);
        assertFalse(requester.reviewExpiryRequested(askId));
        uint256 balance = imd.balanceOf(creator);
        _confirmExpiry(askId); // Abandoned requester never requested expiry.
        assertEq(imd.balanceOf(creator), balance);
        assertEq(uint8(_review(jobId)), uint8(HookJobRequester.ReviewStatus.Unanswered));
        bytes32 retry = _requestReview(jobId);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.UnknownOrSettled.selector, askId));
        requester.confirmReviewExpiry(askId);
        assertFalse(_deliver(askId, _attestation(askId, false)));
        assertTrue(_deliver(retry, _attestation(retry, false)));
        assertEq(uint8(_review(jobId)), uint8(HookJobRequester.ReviewStatus.NotPassed));
    }

    function testAbandonedAskReceiptBlocksClosureWithoutRequesterExpiryRequest() public {
        (bytes32 jobId, bytes32 askId) = _unbound();
        vm.warp(requester.getReviewAsk(askId).deadline + 1);
        OracleAttestation.Attestation memory a = _attestation(askId, false);
        assertTrue(_deliver(askId, a));
        assertFalse(requester.reviewExpiryRequested(askId));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.ReviewAlreadyReceived.selector, askId));
        requester.confirmReviewExpiry(askId);
        _confirm(askId, a);
        assertEq(uint8(_review(jobId)), uint8(HookJobRequester.ReviewStatus.NotPassed));
    }

    function testFuzzCompromisedEpochBlocksRetainedAnswersAndAllowsHonestClosure(bool passed, bool prebound) public {
        (bytes32 jobId, bytes32 askId) = _unbound();
        OracleAttestation.Attestation memory a = _attestation(askId, passed);
        if (prebound) {
            OracleAttestation.Attestation memory wrong = _attestation(askId, passed);
            wrong.questionHash = keccak256("wrong pre-binding");
            _confirm(askId, wrong);
        }
        assertTrue(_deliver(askId, a));
        bytes memory history = abi.encode(requester.getReviewReceipt(askId));
        assertEq(requester.reviewReceiptSignerEpoch(askId), 1);
        bytes32 incident = keccak256("authenticated compromised signer incident report");
        uint256 nextKey = uint256(keccak256("safe test signer"));
        vm.startPrank(owner);
        requester.setOracleSigner(vm.addr(nextKey));
        requester.revokeSignerEpoch(1, incident);
        if (prebound) requester.resetReviewBinding(askId, requester.getReviewAsk(askId).bodyHash);
        vm.stopPrank();
        bytes32 body = requester.getReviewAsk(askId).bodyHash;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.SignerEpochRevoked.selector, uint32(1)));
        requester.bindReview(askId, body, a.requestId, a.questionHash, a.chainId, a.fromBlock, a.toBlock);
        vm.prank(creator);
        vm.expectRevert(StoreAdmin.NotOwner.selector);
        requester.closeRevokedReviewReceipt(askId);
        vm.prank(owner);
        requester.closeRevokedReviewReceipt(askId);
        assertTrue(requester.revokedReviewReceipts(askId));
        assertEq(abi.encode(requester.getReviewReceipt(askId)), history);
        assertTrue(requester.usedIntakeRequestIds(askId));
        assertFalse(requester.consumed(a.requestId));
        assertEq(uint8(_review(jobId)), uint8(HookJobRequester.ReviewStatus.Unanswered));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.UnknownOrSettled.selector, askId));
        requester.closeRevokedReviewReceipt(askId);
        bytes memory payload = abi.encode(askId, a, _sign(a, signerKey));
        vm.expectRevert("not pending");
        intake.complete(askId, payload);
        bytes32 retry = _requestReview(jobId);
        OracleAttestation.Attestation memory fresh = _attestation(retry, false);
        bytes memory staleSignature = _sign(fresh, signerKey);
        vm.prank(address(intake));
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        requester.onReviewResult(retry, fresh, staleSignature);
        assertTrue(intake.complete(retry, abi.encode(retry, fresh, _sign(fresh, nextKey))));
        assertEq(uint8(_review(jobId)), uint8(HookJobRequester.ReviewStatus.NotPassed));
        assertTrue(requester.consumed(fresh.requestId));
    }

    function testIncidentRevocationIsExplicitAndCannotUndoFinalizedVerdicts() public {
        (bytes32 jobId, bytes32 askId) = _unbound();
        OracleAttestation.Attestation memory a = _attestation(askId, false);
        assertTrue(_deliver(askId, a));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.SignerEpochNotRevoked.selector, uint32(1)));
        requester.closeRevokedReviewReceipt(askId);
        vm.prank(owner);
        requester.setOracleSigner(stranger);
        _confirm(askId, a); // Routine rotation still preserves historical verification.
        vm.prank(owner);
        requester.revokeSignerEpoch(1, keccak256("incident"));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.UnknownOrSettled.selector, askId));
        requester.closeRevokedReviewReceipt(askId);
        assertEq(uint8(_review(jobId)), uint8(HookJobRequester.ReviewStatus.NotPassed));
        assertTrue(requester.consumed(a.requestId));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.ReservationNotReleasable.selector, a.requestId));
        requester.releaseReservation(a.requestId);
    }

    function testRevocationValidatesAuthorityEpochAndEvidence() public {
        vm.prank(creator);
        vm.expectRevert(StoreAdmin.NotOwner.selector);
        requester.revokeSignerEpoch(1, keccak256("incident"));
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.InvalidSignerEpoch.selector, uint32(1)));
        requester.revokeSignerEpoch(1, keccak256("incident"));
        requester.setOracleSigner(stranger);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.InvalidSignerEpoch.selector, uint32(0)));
        requester.revokeSignerEpoch(0, keccak256("incident"));
        vm.expectRevert(HookJobRequester.InvalidIncidentHash.selector);
        requester.revokeSignerEpoch(1, bytes32(0));
        requester.revokeSignerEpoch(1, keccak256("incident"));
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.SignerEpochRevoked.selector, uint32(1)));
        requester.revokeSignerEpoch(1, keccak256("another incident"));
        vm.stopPrank();
    }

    function testRevocationFreezesEveryOldReceiptButNotANewEpochReceipt() public {
        (bytes32 jobA, bytes32 askA) = _unbound();
        (bytes32 jobB, bytes32 askB) = _unbound();
        (bytes32 jobC, bytes32 askC) = _unbound();
        OracleAttestation.Attestation memory a = _attestation(askA, false);
        OracleAttestation.Attestation memory b = _attestation(askB, true);
        assertTrue(_deliver(askA, a));
        assertTrue(_deliver(askB, b));
        uint256 nextKey = uint256(keccak256("new epoch test key"));
        vm.prank(owner);
        requester.setOracleSigner(vm.addr(nextKey));
        OracleAttestation.Attestation memory c = _attestation(askC, false);
        assertTrue(intake.complete(askC, abi.encode(askC, c, _sign(c, nextKey))));
        assertEq(requester.reviewReceiptSignerEpoch(askC), 2, "receipt epoch is not the ask epoch");
        vm.prank(owner);
        requester.revokeSignerEpoch(1, keccak256("incident"));
        bytes32 bodyA = requester.getReviewAsk(askA).bodyHash;
        bytes32 bodyB = requester.getReviewAsk(askB).bodyHash;
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.SignerEpochRevoked.selector, uint32(1)));
        requester.bindReview(askA, bodyA, a.requestId, a.questionHash, a.chainId, a.fromBlock, a.toBlock);
        requester.closeRevokedReviewReceipt(askA);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.SignerEpochRevoked.selector, uint32(1)));
        requester.bindReview(askB, bodyB, b.requestId, b.questionHash, b.chainId, b.fromBlock, b.toBlock);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.SignerEpochNotRevoked.selector, uint32(2)));
        requester.closeRevokedReviewReceipt(askC);
        vm.stopPrank();
        _confirm(askC, c);
        assertEq(uint8(_review(jobA)), uint8(HookJobRequester.ReviewStatus.Unanswered));
        assertEq(uint8(_review(jobB)), uint8(HookJobRequester.ReviewStatus.Pending));
        assertEq(uint8(_review(jobC)), uint8(HookJobRequester.ReviewStatus.NotPassed));
        assertTrue(requester.consumed(c.requestId));
        assertFalse(requester.consumed(a.requestId));
        assertFalse(requester.consumed(b.requestId));
    }

    function testRevokedBoundMismatchClosesWithoutResetAndReservationReleasePreservesHistory() public {
        (, bytes32 askId) = _reviewPending();
        OracleAttestation.Attestation memory a = _attestation(askId, true);
        a.questionHash = keccak256("compromised signer wrong fields");
        assertTrue(_deliver(askId, a));
        bytes memory history = abi.encode(requester.getReviewReceipt(askId));
        vm.startPrank(owner);
        requester.setOracleSigner(stranger);
        requester.revokeSignerEpoch(1, keccak256("incident"));
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.ReservationNotReleasable.selector, a.requestId));
        requester.releaseReservation(a.requestId);
        requester.closeRevokedReviewReceipt(askId);
        assertEq(requester.intakeReviewOfOracle(a.requestId), askId, "closure does not silently release");
        requester.releaseReservation(a.requestId);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.ReservationNotReleasable.selector, a.requestId));
        requester.releaseReservation(a.requestId);
        vm.stopPrank();
        assertEq(abi.encode(requester.getReviewReceipt(askId)), history);
        assertEq(requester.getReviewAsk(askId).oracleRequestId, a.requestId);
        assertTrue(requester.usedIntakeRequestIds(askId));
        assertFalse(requester.consumed(a.requestId));
        assertEq(requester.intakeReviewOfOracle(a.requestId), bytes32(0));
    }

    function testUnknownOrMissingReceiptCannotBeIncidentClosed() public {
        (, bytes32 askId) = _unbound();
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.ReviewNotReceived.selector, askId));
        requester.closeRevokedReviewReceipt(askId);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.UnknownOrSettled.selector, bytes32(0)));
        requester.closeRevokedReviewReceipt(bytes32(0));
        vm.stopPrank();
    }
}

contract RequesterMvpPaymentTest is HookJobRequesterFixture {
    function testFuzzUnderspendingIntakeRollsBackAllStateAndLeavesNothingSweepable(
        uint256 unspent,
        bool review,
        bool v1
    ) public {
        unspent = bound(unspent, 1, PRICE);
        bytes32 jobId = review ? _delivered() : bytes32(0);
        vm.prank(owner);
        requester.setFailureHook(!v1);
        intake.setV1(v1);
        intake.setUnspent(unspent);
        uint256 balance = imd.balanceOf(creator);
        uint256 intakeBalance = imd.balanceOf(address(intake));
        bytes32 previousId = intake.lastRequestId();
        uint256 count = requester.jobCount();
        vm.prank(creator);
        vm.expectRevert(HookJobRequester.InexactIntakeSpend.selector);
        if (review) requester.requestReview(jobId, PRICE);
        else requester.openJob(SPEC_HASH, "brief", PRICE);
        assertEq(imd.balanceOf(creator), balance);
        assertEq(imd.balanceOf(address(intake)), intakeBalance);
        assertEq(imd.balanceOf(address(requester)), 0);
        assertEq(imd.allowance(address(requester), address(intake)), 0);
        assertEq(requester.jobCount(), count);
        assertEq(intake.lastRequestId(), previousId);
        if (review) assertEq(uint8(_review(jobId)), uint8(HookJobRequester.ReviewStatus.None));
        vm.prank(owner);
        vm.expectRevert(HookJobRequester.TokenCallFailed.selector);
        requester.sweep(address(imd), owner, 1);
        // Restoring exact spending makes the same operation succeed.
        intake.setUnspent(0);
        vm.prank(creator);
        if (review) requester.requestReview(jobId, PRICE);
        else requester.openJob(SPEC_HASH, "brief", PRICE);
        assertEq(imd.balanceOf(creator), balance - PRICE);
    }

    function testExistingDonationsCannotHideUnderpaymentOrBecomeCallerFunds() public {
        imd.mint(address(requester), PRICE);
        intake.setUnspent(1);
        vm.prank(creator);
        vm.expectRevert(HookJobRequester.InexactIntakeSpend.selector);
        requester.openJob(SPEC_HASH, "brief", PRICE);
        assertEq(imd.balanceOf(address(requester)), PRICE);
        intake.setUnspent(0);
        _open();
        assertEq(imd.balanceOf(address(requester)), PRICE);
        vm.prank(owner);
        requester.sweep(address(imd), owner, PRICE);
        assertEq(imd.balanceOf(owner), PRICE, "only the original donation remains recoverable");
    }

    function testFuzzCallerLimitSurvivesOwnerCeilingIncreaseAndIntakePriceMove(bool review, uint96 increase) public {
        increase = uint96(bound(increase, 1, PRICE));
        bytes32 jobId = review ? _delivered() : bytes32(0);
        uint256 movedPrice = PRICE + increase;
        vm.prank(owner);
        requester.setPayment(address(imd), 3 * PRICE);
        intake.setPrice(review ? ORACLE_ACTION : JOB_ACTION, address(imd), movedPrice);
        uint256 balance = imd.balanceOf(creator);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.PriceAboveUserMaximum.selector, movedPrice, PRICE));
        if (review) requester.requestReview(jobId, PRICE);
        else requester.openJob(SPEC_HASH, "brief", PRICE);
        assertEq(imd.balanceOf(creator), balance);
        vm.prank(creator);
        if (review) requester.requestReview(jobId, movedPrice);
        else requester.openJob(SPEC_HASH, "brief", movedPrice);
        assertEq(imd.balanceOf(creator), balance - movedPrice);
        assertEq(imd.allowance(address(requester), address(intake)), 0);
    }

    function testCallerLimitZeroFailsAndLowerQuoteChargesOnlyQuote() public {
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.PriceAboveUserMaximum.selector, PRICE, 0));
        requester.openJob(SPEC_HASH, "brief", 0);
        intake.setPrice(JOB_ACTION, address(imd), PRICE / 2);
        _open();
        assertEq(imd.balanceOf(creator), 10 ether - PRICE / 2);
        assertEq(imd.balanceOf(address(requester)), 0);
    }

    function testFuzzInexactIncomingTokensCannotSpendPreexistingDonations(uint8 fault) public {
        fault = uint8(bound(fault, 0, 2));
        StoreTokenMock token = new StoreTokenMock();
        token.mint(creator, 10 * PRICE);
        token.mint(address(requester), PRICE);
        token.setMode(
            fault == 0
                ? StoreTokenMock.Mode.RecipientFee
                : fault == 1 ? StoreTokenMock.Mode.SenderFee : StoreTokenMock.Mode.NoMovement
        );
        vm.prank(owner);
        requester.setPayment(address(token), PRICE);
        intake.setPrice(JOB_ACTION, address(token), PRICE);
        vm.prank(creator);
        token.approve(address(requester), PRICE);
        vm.prank(creator);
        vm.expectRevert(ExactStoreToken.InexactTransfer.selector);
        requester.openJob(SPEC_HASH, "brief", PRICE);
        assertEq(token.balanceOf(creator), 10 * PRICE);
        assertEq(token.balanceOf(address(requester)), PRICE);
        assertEq(token.balanceOf(address(intake)), 0);
        assertEq(requester.jobCount(), 0);
    }

    function testTokenCallbackCannotReenterSweepOrChangePaymentConfiguration() public {
        StoreTokenMock token = new StoreTokenMock();
        token.mint(creator, 4 * PRICE);
        token.mint(address(requester), PRICE);
        intake.setPrice(JOB_ACTION, address(token), PRICE);
        vm.startPrank(owner);
        requester.setPayment(address(token), PRICE);
        requester.transferOwnership(address(token));
        vm.stopPrank();
        vm.prank(address(token));
        requester.acceptOwnership();
        vm.prank(creator);
        token.approve(address(requester), 3 * PRICE);
        token.setCallback(address(requester), abi.encodeCall(requester.sweep, (address(token), owner, PRICE)));
        _open();
        assertFalse(token.callbackSucceeded());
        assertEq(token.callbackResult(), abi.encodeWithSelector(HookJobRequester.Reentrancy.selector));
        assertEq(token.balanceOf(address(requester)), PRICE);
        assertEq(token.balanceOf(owner), 0);
        token.setCallback(address(requester), abi.encodeCall(requester.setPayment, (address(imd), PRICE)));
        _open();
        assertFalse(token.callbackSucceeded());
        assertEq(token.callbackResult(), abi.encodeWithSelector(HookJobRequester.Reentrancy.selector));
        assertEq(requester.asset(), address(token));
        token.setCallback(address(requester), abi.encodeCall(requester.setIntake, (stranger)));
        _open();
        assertFalse(token.callbackSucceeded());
        assertEq(token.callbackResult(), abi.encodeWithSelector(HookJobRequester.Reentrancy.selector));
        assertEq(address(requester.intake()), address(intake));
        assertEq(token.balanceOf(creator), PRICE);
        assertEq(token.balanceOf(address(intake)), 3 * PRICE);
    }
}
