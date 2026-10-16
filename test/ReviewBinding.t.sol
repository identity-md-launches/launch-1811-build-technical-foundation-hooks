// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookJobRequesterFixture} from "./HookJobRequester.t.sol";
import {HookJobRequester} from "../src/imd/HookJobRequester.sol";
import {OracleAttestation, OracleAttestationConsumer} from "../src/imd/OracleAttestation.sol";
import {StoreAdmin} from "../src/store/StoreAdmin.sol";
import {ImdTemplates} from "./helpers/ImdTemplates.sol";

contract ReviewBindingTest is HookJobRequesterFixture {
    function _unbound() internal returns (bytes32 jobId, bytes32 askId) {
        jobId = _delivered();
        vm.prank(creator);
        askId = requester.requestReview(jobId);
    }

    function _expectMismatch(bytes32 askId, OracleAttestation.Attestation memory a) internal {
        bytes memory sig = _sign(a, signerKey);
        vm.prank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.ReviewAttestationMismatch.selector, askId));
        requester.onReviewResult(askId, a, sig);
        assertFalse(requester.consumed(a.requestId));
    }

    function testSwappedHonestAnswersLeaveBothPendingThenSettleTheirOwnAsks() public {
        (bytes32 jobA, bytes32 askA) = _reviewPending();
        (bytes32 jobB, bytes32 askB) = _reviewPending();
        OracleAttestation.Attestation memory a = _attestation(askA, false);
        OracleAttestation.Attestation memory b = _attestation(askB, true);
        assertNotEq(askA, a.requestId, "Intake ID is not the oracle UUID");
        assertNotEq(askB, b.requestId);
        assertNotEq(a.questionHash, b.questionHash);
        _expectMismatch(askA, b);
        _expectMismatch(askB, a);
        assertEq(requester.reviewOf(askA), jobA);
        assertEq(requester.reviewOf(askB), jobB);
        assertEq(uint8(_review(jobA)), uint8(HookJobRequester.ReviewStatus.Pending));
        assertEq(uint8(_review(jobB)), uint8(HookJobRequester.ReviewStatus.Pending));
        assertTrue(intake.complete(askB, abi.encode(askB, b, _sign(b, signerKey))), "200k stipend");
        assertTrue(intake.complete(askA, abi.encode(askA, a, _sign(a, signerKey))), "200k stipend");
        assertEq(uint8(_review(jobA)), uint8(HookJobRequester.ReviewStatus.NotPassed));
        assertEq(uint8(_review(jobB)), uint8(HookJobRequester.ReviewStatus.Passed));
    }

    function testSignedWrongQuestionIdChainOrWindowCannotSettle() public {
        (, bytes32 askId) = _reviewPending();
        OracleAttestation.Attestation memory a = _attestation(askId, true);
        a.questionHash = keccak256("a different question, honestly signed");
        _expectMismatch(askId, a);
        a = _attestation(askId, true);
        a.requestId = askId; // Even equality to the callback ID is not an authenticated mapping.
        _expectMismatch(askId, a);
        a = _attestation(askId, true);
        a.chainId++;
        _expectMismatch(askId, a);
        a = _attestation(askId, true);
        a.fromBlock++;
        _expectMismatch(askId, a);
        a = _attestation(askId, true);
        a.toBlock++;
        _expectMismatch(askId, a);
        a = _attestation(askId, true);
        assertTrue(intake.complete(askId, abi.encode(askId, a, _sign(a, signerKey))));
    }

    function testUnboundReceiptDoesNotTrustMatchingIntakeIdAndRawBodyHash() public {
        (bytes32 jobId, bytes32 askId) = _unbound();
        OracleAttestation.Attestation memory a = _attestation(askId, true);
        a.requestId = askId;
        a.questionHash = keccak256(intake.bodyOf(askId));
        bytes memory sig = _sign(a, signerKey);
        assertTrue(intake.complete(askId, abi.encode(askId, a, sig)));
        assertEq(uint8(_review(jobId)), uint8(HookJobRequester.ReviewStatus.Pending));
        assertFalse(requester.consumed(a.requestId));
        OracleAttestation.Attestation memory expected = _attestation(askId, true);
        bytes32 bodyHash = requester.getReviewAsk(askId).bodyHash;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.ReviewAttestationMismatch.selector, askId));
        requester.bindReview(askId, bodyHash, expected.requestId, expected.questionHash, expected.chainId, 1, 2);
        vm.warp(requester.getJob(jobId).reviewDeadline + 1);
        vm.prank(creator);
        requester.expireReview(jobId);
        assertEq(uint8(_review(jobId)), uint8(HookJobRequester.ReviewStatus.Unanswered));
    }

    function testBindingRequiresOwnerAndExactRecordedBodyAndCannotBeOverwritten() public {
        (bytes32 jobId, bytes32 askId) = _unbound();
        OracleAttestation.Attestation memory a = _attestation(askId, true);
        bytes32 bodyHash = keccak256(intake.bodyOf(askId));
        assertEq(requester.getReviewAsk(askId).bodyHash, bodyHash);
        vm.prank(creator);
        vm.expectRevert(StoreAdmin.NotOwner.selector);
        requester.bindReview(askId, bodyHash, a.requestId, a.questionHash, a.chainId, 1, 2);
        vm.prank(address(intake));
        vm.expectRevert(StoreAdmin.NotOwner.selector);
        requester.bindReview(askId, bodyHash, a.requestId, a.questionHash, a.chainId, 1, 2);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.ReviewBodyMismatch.selector, bodyHash, bytes32(0)));
        requester.bindReview(askId, bytes32(0), a.requestId, a.questionHash, a.chainId, 1, 2);
        vm.prank(owner);
        vm.expectEmit(true, true, true, true, address(requester));
        emit HookJobRequester.ReviewBound(jobId, askId, a.requestId, bodyHash, a.questionHash, a.chainId, 1, 2);
        requester.bindReview(askId, bodyHash, a.requestId, a.questionHash, a.chainId, 1, 2);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.ReviewAlreadyBound.selector, askId));
        requester.bindReview(askId, bodyHash, keccak256("replacement"), a.questionHash, a.chainId, 1, 2);
        assertEq(requester.intakeReviewOfOracle(a.requestId), askId);
    }

    function testInvalidOrUnknownBindingsRefused() public {
        (, bytes32 askId) = _unbound();
        OracleAttestation.Attestation memory a = _attestation(askId, true);
        bytes32 bodyHash = requester.getReviewAsk(askId).bodyHash;
        vm.startPrank(owner);
        vm.expectRevert(HookJobRequester.InvalidReviewBinding.selector);
        requester.bindReview(askId, bodyHash, bytes32(0), a.questionHash, a.chainId, 1, 2);
        vm.expectRevert(HookJobRequester.InvalidReviewBinding.selector);
        requester.bindReview(askId, bodyHash, a.requestId, bytes32(0), a.chainId, 1, 2);
        vm.expectRevert(HookJobRequester.InvalidReviewBinding.selector);
        requester.bindReview(askId, bodyHash, a.requestId, a.questionHash, 0, 1, 2);
        vm.expectRevert(HookJobRequester.InvalidReviewBinding.selector);
        requester.bindReview(askId, bodyHash, a.requestId, a.questionHash, a.chainId, 2, 1);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.UnknownOrSettled.selector, bytes32(0)));
        requester.bindReview(bytes32(0), bodyHash, a.requestId, a.questionHash, a.chainId, 1, 2);
        vm.stopPrank();
        assertEq(requester.getReviewAsk(askId).oracleRequestId, bytes32(0));
    }

    function testFuzzOracleIdReservationSurvivesFailureExpiryAndSettlement(uint8 outcome) public {
        outcome = uint8(bound(outcome, 0, 2));
        (bytes32 jobId, bytes32 askId) = _reviewPending();
        OracleAttestation.Attestation memory a = _attestation(askId, true);
        if (outcome == 0) {
            assertTrue(intake.fail(askId, 2, "disagreed", 2, 7));
        } else if (outcome == 1) {
            vm.warp(requester.getJob(jobId).reviewDeadline + 1);
            vm.prank(creator);
            requester.expireReview(jobId);
        } else {
            assertTrue(intake.complete(askId, abi.encode(askId, a, _sign(a, signerKey))));
        }
        (, bytes32 nextAsk) = _unbound();
        bytes32 nextBody = requester.getReviewAsk(nextAsk).bodyHash;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.DuplicateRequestId.selector, a.requestId));
        requester.bindReview(nextAsk, nextBody, a.requestId, a.questionHash, a.chainId, 1, 2);
        assertEq(requester.intakeReviewOfOracle(a.requestId), askId);
        assertEq(requester.getReviewAsk(nextAsk).oracleRequestId, bytes32(0));
        _bind(nextAsk);
    }

    function testLateValidAnswerAndLateBindingAllowedUntilExplicitExpiry() public {
        (bytes32 jobId, bytes32 askId) = _reviewPending();
        (, bytes32 unboundId) = _unbound();
        uint64 deadline = requester.getJob(jobId).reviewDeadline;
        vm.warp(deadline + 1);
        OracleAttestation.Attestation memory a = _attestation(askId, true);
        bytes memory sig = _sign(a, signerKey);
        assertTrue(intake.complete(askId, abi.encode(askId, a, sig)));
        _bind(unboundId);
        OracleAttestation.Attestation memory b = _attestation(unboundId, false);
        assertTrue(intake.complete(unboundId, abi.encode(unboundId, b, _sign(b, signerKey))));
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.UnknownOrSettled.selector, jobId));
        requester.expireReview(jobId);
        assertTrue(requester.consumed(a.requestId));
    }

    function testAnswerAtDeadlineAcceptedAndExcessiveBackwardSkewRefused() public {
        (, bytes32 askId) = _reviewPending();
        HookJobRequester.ReviewAsk memory ask = requester.getReviewAsk(askId);
        OracleAttestation.Attestation memory a = _attestation(askId, true);
        a.issuedAt = ask.askedAt - requester.ISSUED_AT_TOLERANCE() - 1;
        bytes memory sig = _sign(a, signerKey);
        vm.prank(address(intake));
        vm.expectRevert(
            abi.encodeWithSelector(HookJobRequester.AttestationPredatesAsk.selector, a.issuedAt, ask.askedAt)
        );
        requester.onReviewResult(askId, a, sig);
        vm.warp(ask.deadline);
        a = _attestation(askId, false);
        assertTrue(intake.complete(askId, abi.encode(askId, a, _sign(a, signerKey))));
    }

    function testExpiredAskAnswerCannotSettleRetryOfIdenticalQuestion() public {
        (bytes32 jobId, bytes32 askId) = _reviewPending();
        OracleAttestation.Attestation memory oldAnswer = _attestation(askId, true);
        oldAnswer.expiresAt = uint64(block.timestamp + 7 days);
        bytes memory oldSignature = _sign(oldAnswer, signerKey);
        vm.warp(requester.getJob(jobId).reviewDeadline + 1);
        vm.prank(creator);
        requester.expireReview(jobId);
        bytes32 retry = _requestReview(jobId);
        OracleAttestation.Attestation memory fresh = _attestation(retry, false);
        assertEq(fresh.questionHash, oldAnswer.questionHash, "same question still requires its own request ID");
        vm.prank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.UnknownOrSettled.selector, askId));
        requester.onReviewResult(askId, oldAnswer, oldSignature);
        vm.prank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.ReviewAttestationMismatch.selector, retry));
        requester.onReviewResult(retry, oldAnswer, oldSignature);
        assertFalse(requester.consumed(oldAnswer.requestId));
        assertTrue(intake.complete(retry, abi.encode(retry, fresh, _sign(fresh, signerKey))));
        assertEq(uint8(_review(jobId)), uint8(HookJobRequester.ReviewStatus.NotPassed));
    }

    function testFuzzIntakeIdCannotBeReusedAfterReviewCloses(uint8 outcome) public {
        outcome = uint8(bound(outcome, 0, 2));
        (bytes32 jobId, bytes32 askId) = _reviewPending();
        if (outcome == 0) {
            assertTrue(intake.fail(askId, 1, "body_invalid", 0, 0));
        } else if (outcome == 1) {
            vm.warp(requester.getJob(jobId).reviewDeadline + 1);
            vm.prank(creator);
            requester.expireReview(jobId);
        } else {
            OracleAttestation.Attestation memory a = _attestation(askId, true);
            assertTrue(intake.complete(askId, abi.encode(askId, a, _sign(a, signerKey))));
        }
        uint256 balance = imd.balanceOf(creator);
        intake.setReuseIds(true);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.DuplicateRequestId.selector, askId));
        requester.openJob(SPEC_HASH, "colliding job");
        if (outcome != 2) {
            vm.prank(creator);
            vm.expectRevert(abi.encodeWithSelector(HookJobRequester.DuplicateRequestId.selector, askId));
            requester.requestReview(jobId);
        }
        assertEq(imd.balanceOf(creator), balance, "failed asks roll payment back");
        assertTrue(requester.usedIntakeRequestIds(askId));
    }

    function testTemplateAndTimeoutChangesDoNotChangePendingAskContext() public {
        (, bytes32 askId) = _reviewPending();
        HookJobRequester.ReviewAsk memory ask = requester.getReviewAsk(askId);
        vm.startPrank(owner);
        requester.setReviewTemplate(ORACLE_ACTION, "different question ", "?", 2, 1);
        requester.setTimeouts(1 hours, 1 hours);
        vm.stopPrank();
        OracleAttestation.Attestation memory a = _attestation(askId, true);
        a.panelSize = 2;
        a.quorum = 1;
        a.agreed = 2;
        bytes memory sig = _sign(a, signerKey);
        vm.prank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.PanelTooWeak.selector, uint16(2), uint16(1), uint16(2)));
        requester.onReviewResult(askId, a, sig);
        assertEq(requester.getReviewAsk(askId).bodyHash, ask.bodyHash);
        assertEq(requester.getReviewAsk(askId).deadline, ask.deadline);
        a = _attestation(askId, true);
        assertTrue(intake.complete(askId, abi.encode(askId, a, _sign(a, signerKey))));
    }

    function testSignedPanelQuorumAndCountsMustBeConsistent() public {
        (, bytes32 askId) = _reviewPending();
        OracleAttestation.Attestation memory a = _attestation(askId, true);
        a.quorum = 1;
        bytes memory sig = _sign(a, signerKey);
        vm.prank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.PanelTooWeak.selector, uint16(7), uint16(1), uint16(6)));
        requester.onReviewResult(askId, a, sig);
        a.quorum = 5;
        a.agreed = 8;
        sig = _sign(a, signerKey);
        vm.prank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.PanelTooWeak.selector, uint16(7), uint16(5), uint16(8)));
        requester.onReviewResult(askId, a, sig);
    }

    function testOwnerRotationPowersApplyToAlreadyPendingRequestsAsDocumented() public {
        bytes32 openJobId = _open();
        (bytes32 jobId, bytes32 askId) = _reviewPending();
        OracleAttestation.Attestation memory a = _attestation(askId, true);
        uint256 ownerKey = uint256(keccak256("owner-controlled test signing key"));
        bytes memory sig = _sign(a, ownerKey);
        vm.startPrank(owner);
        requester.setIntake(owner);
        requester.setOracleSigner(vm.addr(ownerKey));
        requester.onJobResult(openJobId, "owner-controlled completion");
        requester.onReviewResult(askId, a, sig);
        requester.setIntake(address(intake));
        requester.setOracleSigner(signer);
        vm.stopPrank();
        assertEq(uint8(_review(jobId)), uint8(HookJobRequester.ReviewStatus.Passed));
        assertEq(uint8(_status(openJobId)), uint8(HookJobRequester.JobStatus.Delivered));
    }
}

contract RequesterOwnershipTest is HookJobRequesterFixture {
    function testZeroAndSelfHandoversRefusedWithoutLosingControl() public {
        vm.startPrank(owner);
        vm.expectRevert(StoreAdmin.InvalidAddress.selector);
        requester.transferOwnership(address(0));
        vm.expectRevert(StoreAdmin.InvalidAddress.selector);
        requester.transferOwnership(address(requester));
        requester.setFailureHook(false);
        vm.stopPrank();
        assertEq(requester.owner(), owner);
        assertEq(requester.pendingOwner(), address(0));
    }

    function testMistypedHandoverCanBeCancelledOrReplacedAndOnlyNomineeAccepts() public {
        address intended = makeAddr("intended owner");
        address typo = makeAddr("mistyped owner");
        vm.prank(owner);
        requester.transferOwnership(typo);
        assertEq(requester.owner(), owner);
        assertEq(requester.pendingOwner(), typo);
        vm.prank(typo);
        vm.expectRevert(StoreAdmin.NotOwner.selector);
        requester.setOracleSigner(stranger);
        vm.prank(intended);
        vm.expectRevert(StoreAdmin.NotPendingOwner.selector);
        requester.acceptOwnership();
        vm.prank(stranger);
        vm.expectRevert(StoreAdmin.NotOwner.selector);
        requester.cancelOwnershipTransfer();
        vm.prank(owner);
        requester.cancelOwnershipTransfer();
        vm.prank(typo);
        vm.expectRevert(StoreAdmin.NotPendingOwner.selector);
        requester.acceptOwnership();
        vm.prank(owner);
        requester.transferOwnership(typo);
        vm.prank(owner);
        requester.transferOwnership(intended);
        vm.prank(typo);
        vm.expectRevert(StoreAdmin.NotPendingOwner.selector);
        requester.acceptOwnership();
        vm.prank(intended);
        vm.expectEmit(true, true, false, true, address(requester));
        emit StoreAdmin.OwnershipTransferred(owner, intended);
        requester.acceptOwnership();
        assertEq(requester.owner(), intended);
        assertEq(requester.pendingOwner(), address(0));
        vm.prank(owner);
        vm.expectRevert(StoreAdmin.NotOwner.selector);
        requester.setFailureHook(false);
        vm.prank(intended);
        requester.setFailureHook(false);
        assertFalse(requester.failureHook());
    }
}
