// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookJobRequesterFixture} from "./HookJobRequester.t.sol";
import {HookJobRequester} from "../src/imd/HookJobRequester.sol";
import {OracleAttestation, OracleAttestationConsumer} from "../src/imd/OracleAttestation.sol";
import {OracleRegistryMock} from "./OracleSigner.t.sol";
import {StoreAdmin} from "../src/store/StoreAdmin.sol";

/// @dev No automatic binding in these fixtures. Every real delivery goes through MockIntake's
/// one-attempt, 200,000-gas call; a callback revert still settles Intake and keeps the paid fee.
contract ReviewDeliveryTest is HookJobRequesterFixture {
    function _unboundReview() internal returns (bytes32 jobId, bytes32 askId) {
        jobId = _delivered();
        vm.prank(creator);
        askId = requester.requestReview(jobId);
    }

    /// @dev Tests supply independently chosen expected fields. This is NOT a live mapping source
    /// or a production instruction to trust whatever arrives in a receipt.
    function _confirm(bytes32 askId, OracleAttestation.Attestation memory expected) internal {
        bytes32 bodyHash = keccak256(intake.bodyOf(askId));
        vm.prank(owner);
        requester.bindReview(
            askId,
            bodyHash,
            expected.requestId,
            expected.questionHash,
            expected.chainId,
            expected.fromBlock,
            expected.toBlock
        );
    }

    function _deliver(bytes32 askId, OracleAttestation.Attestation memory a) internal returns (bool) {
        bytes memory signature = _sign(a, signerKey);
        vm.cool(address(requester));
        vm.cool(signer);
        return intake.complete(askId, abi.encode(askId, a, signature));
    }

    function _assertReceipt(bytes32 jobId, bytes32 askId, OracleAttestation.Attestation memory a) internal view {
        HookJobRequester.ReviewReceipt memory receipt = requester.getReviewReceipt(askId);
        assertEq(receipt.oracleRequestId, a.requestId);
        assertEq(receipt.questionHash, a.questionHash);
        assertEq(receipt.questionChainId, a.chainId);
        assertEq(receipt.fromBlock, a.fromBlock);
        assertEq(receipt.toBlock, a.toBlock);
        assertEq(receipt.panelJobId, a.panelJobId);
        assertEq(receipt.panelSize, a.panelSize);
        assertEq(receipt.agreed, a.agreed);
        assertEq(receipt.passed, abi.decode(a.answer, (bool)));
        assertEq(receipt.receivedAt, vm.getBlockTimestamp());
        assertEq(uint8(_review(jobId)), uint8(HookJobRequester.ReviewStatus.Pending));
        assertEq(requester.reviewOf(askId), jobId);
        assertEq(requester.getReviewAsk(askId).oracleRequestId, bytes32(0));
        assertEq(requester.intakeReviewOfOracle(a.requestId), bytes32(0));
        assertFalse(requester.consumed(a.requestId));
    }

    function _assertVerdict(bytes32 jobId, bytes32 askId, OracleAttestation.Attestation memory a) internal view {
        HookJobRequester.Job memory job = requester.getJob(jobId);
        bool passed = abi.decode(a.answer, (bool));
        assertEq(
            uint8(job.review),
            uint8(passed ? HookJobRequester.ReviewStatus.Passed : HookJobRequester.ReviewStatus.NotPassed)
        );
        assertEq(job.reviewPanelSize, a.panelSize);
        assertEq(job.reviewAgreed, a.agreed);
        assertEq(job.reviewPanelJobId, a.panelJobId);
        assertEq(requester.reviewOf(askId), bytes32(0));
        assertEq(requester.intakeReviewOfOracle(a.requestId), askId);
        assertTrue(requester.consumed(a.requestId));
    }

    function testFuzzEarlyOneAttemptCallbackRetainedThenConfirmedWithoutAnotherFee(bool passed) public {
        uint256 initialBalance = imd.balanceOf(creator);
        (bytes32 jobId, bytes32 askId) = _unboundReview();
        assertEq(imd.balanceOf(creator), initialBalance - 2 * PRICE);
        assertEq(vm.parseJsonUint(string(intake.bodyOf(askId)), ".window.hours"), 1);
        vm.warp(vm.getBlockTimestamp() + 5 minutes);
        OracleAttestation.Attestation memory a = _attestation(askId, passed);
        // The plane resolves this AFTER payment; neither the UUID nor these blocks/hash were pinned.
        a.fromBlock = 1000;
        a.toBlock = 1300;
        a.questionHash = keccak256("independently authenticated resolved question fixture");
        vm.expectEmit(true, true, true, true, address(requester));
        emit HookJobRequester.ReviewReceived(jobId, askId, a.requestId, requester.attestationDigest(a));
        assertTrue(_deliver(askId, a), "the sole callback must succeed before owner binding");
        _assertReceipt(jobId, askId, a);
        (,,,,,, bool settled) = intake.reqs(askId);
        assertTrue(settled, "Intake has finished its only attempt");
        bytes memory payload = abi.encode(askId, a, _sign(a, signerKey));
        vm.expectRevert("not pending");
        intake.complete(askId, payload);
        vm.expectRevert("not pending");
        intake.fail(askId, 2, "no retry", 0, 0);
        _confirm(askId, a);
        _assertVerdict(jobId, askId, a);
        assertEq(imd.balanceOf(creator), initialBalance - 2 * PRICE, "confirmation charges no second review fee");
        assertEq(imd.balanceOf(address(intake)), 2 * PRICE);
        assertEq(imd.balanceOf(address(requester)), 0);
        assertEq(imd.allowance(address(requester), address(intake)), 0);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.NotReviewable.selector, jobId));
        requester.requestReview(jobId);
    }

    function testEarlyErc1271ReceiptFitsColdStipendAndSurvivesLaterRevocation() public {
        (bytes32 jobId, bytes32 askId) = _unboundReview();
        OracleRegistryMock registry = new OracleRegistryMock(signer);
        vm.prank(owner);
        requester.setOracleSigner(address(registry));
        OracleAttestation.Attestation memory a = _attestation(askId, false);
        vm.cool(address(registry));
        assertTrue(_deliver(askId, a), "cold ERC1271 plus receipt storage fits 200k");
        _assertReceipt(jobId, askId, a);
        registry.setMode(1);
        // Verification was final at receipt, like an immediately settled answer. Binding does
        // not reopen signer authority/freshness or turn a later revocation into a lost callback.
        vm.warp(requester.getReviewAsk(askId).deadline + 1);
        assertGt(vm.getBlockTimestamp(), a.expiresAt);
        _confirm(askId, a);
        _assertVerdict(jobId, askId, a);
    }

    function testEarlyEip7702KeyReceiptFitsColdStipend() public {
        (bytes32 jobId, bytes32 askId) = _unboundReview();
        vm.etch(signer, abi.encodePacked(hex"ef0100", makeAddr("delegated signer code")));
        OracleAttestation.Attestation memory a = _attestation(askId, true);
        assertTrue(_deliver(askId, a));
        _confirm(askId, a);
        _assertVerdict(jobId, askId, a);
    }

    function testReceiptCanBeConfirmedAfterSignatureExpiryTimeoutAndAuthorityRotation() public {
        (bytes32 jobId, bytes32 askId) = _unboundReview();
        OracleAttestation.Attestation memory a = _attestation(askId, true);
        assertTrue(_deliver(askId, a));
        uint64 receivedAt = requester.getReviewReceipt(askId).receivedAt;
        vm.warp(requester.getReviewAsk(askId).deadline + 1);
        vm.startPrank(owner);
        requester.setOracleSigner(stranger);
        requester.setIntake(stranger);
        requester.setReviewTemplate(ORACLE_ACTION, "new template ", "?", 10, 9);
        requester.setTimeouts(1 hours, 1 hours);
        vm.stopPrank();
        _confirm(askId, a);
        _assertVerdict(jobId, askId, a);
        assertEq(requester.getReviewReceipt(askId).receivedAt, receivedAt);
    }

    function testFuzzBindingMustMatchEveryRetainedFieldAndFailedBindingCanBeCorrected(uint8 field) public {
        field = uint8(bound(field, 0, 4));
        (bytes32 jobId, bytes32 askId) = _unboundReview();
        OracleAttestation.Attestation memory a = _attestation(askId, true);
        assertTrue(_deliver(askId, a));
        OracleAttestation.Attestation memory wrong = _attestation(askId, true);
        if (field == 0) wrong.requestId = keccak256("other UUID");
        if (field == 1) wrong.questionHash = keccak256("other canonical question");
        if (field == 2) wrong.chainId++;
        if (field == 3) wrong.fromBlock++;
        if (field == 4) wrong.toBlock++;
        bytes32 bodyHash = requester.getReviewAsk(askId).bodyHash;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.ReviewAttestationMismatch.selector, askId));
        requester.bindReview(
            askId, bodyHash, wrong.requestId, wrong.questionHash, wrong.chainId, wrong.fromBlock, wrong.toBlock
        );
        _assertReceipt(jobId, askId, a);
        assertEq(requester.intakeReviewOfOracle(wrong.requestId), bytes32(0));
        _confirm(askId, a);
        _assertVerdict(jobId, askId, a);
    }

    function testSwappedEarlyYesAndNoAnswersCannotBecomeVerdicts() public {
        (bytes32 jobA, bytes32 askA) = _unboundReview();
        (bytes32 jobB, bytes32 askB) = _unboundReview();
        OracleAttestation.Attestation memory a = _attestation(askA, false);
        OracleAttestation.Attestation memory b = _attestation(askB, true);
        assertTrue(_deliver(askA, b));
        assertTrue(_deliver(askB, a));
        bytes32 bodyA = requester.getReviewAsk(askA).bodyHash;
        bytes32 bodyB = requester.getReviewAsk(askB).bodyHash;
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.ReviewAttestationMismatch.selector, askA));
        requester.bindReview(askA, bodyA, a.requestId, a.questionHash, a.chainId, a.fromBlock, a.toBlock);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.ReviewAttestationMismatch.selector, askB));
        requester.bindReview(askB, bodyB, b.requestId, b.questionHash, b.chainId, b.fromBlock, b.toBlock);
        vm.stopPrank();
        _assertReceipt(jobA, askA, b);
        _assertReceipt(jobB, askB, a);
    }

    function testUnconfirmedDuplicateCannotReserveOrConsumeTheActualAsksUuid() public {
        (bytes32 jobA, bytes32 askA) = _unboundReview();
        (bytes32 jobB, bytes32 askB) = _unboundReview();
        OracleAttestation.Attestation memory a = _attestation(askA, false);
        assertTrue(_deliver(askB, a), "swapped duplicate only creates a receipt");
        assertTrue(_deliver(askA, a));
        _confirm(askA, a);
        _assertVerdict(jobA, askA, a);
        bytes32 bodyB = requester.getReviewAsk(askB).bodyHash;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.DuplicateRequestId.selector, a.requestId));
        requester.bindReview(askB, bodyB, a.requestId, a.questionHash, a.chainId, a.fromBlock, a.toBlock);
        assertEq(uint8(_review(jobB)), uint8(HookJobRequester.ReviewStatus.Pending));
        assertEq(requester.getReviewAsk(askB).oracleRequestId, bytes32(0));
        assertEq(requester.intakeReviewOfOracle(a.requestId), askA);
    }

    function testReservedOrConsumedUuidCannotBeDeliveredToAnotherUnboundAsk() public {
        (, bytes32 askA) = _reviewPending();
        (bytes32 jobB, bytes32 askB) = _unboundReview();
        OracleAttestation.Attestation memory a = _attestation(askA, true);
        assertFalse(_deliver(askB, a), "pre-bound UUID belongs only to ask A");
        assertEq(requester.getReviewReceipt(askB).oracleRequestId, bytes32(0));
        assertEq(uint8(_review(jobB)), uint8(HookJobRequester.ReviewStatus.Pending));
        assertTrue(_deliver(askA, a));
        (bytes32 jobC, bytes32 askC) = _unboundReview();
        assertFalse(_deliver(askC, a), "consumed UUID cannot be cached on another ask");
        assertEq(requester.getReviewReceipt(askC).oracleRequestId, bytes32(0));
        assertEq(uint8(_review(jobC)), uint8(HookJobRequester.ReviewStatus.Pending));
    }

    function testReceiptCannotBeOverwrittenOrClearedBySecondIntakeCallback() public {
        (bytes32 jobId, bytes32 askId) = _unboundReview();
        OracleAttestation.Attestation memory a = _attestation(askId, false);
        assertTrue(_deliver(askId, a));
        OracleAttestation.Attestation memory replacement = _attestation(askId, true);
        bytes memory signature = _sign(replacement, signerKey);
        vm.startPrank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.ReviewAlreadyReceived.selector, askId));
        requester.onReviewResult(askId, replacement, signature);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.ReviewAlreadyReceived.selector, askId));
        requester.onReviewFailure(askId, 2, "overwrite", 0, 0, "");
        vm.stopPrank();
        _assertReceipt(jobId, askId, a);
        _confirm(askId, a);
        _assertVerdict(jobId, askId, a);
    }

    function testOnlyCurrentIntakeMayRetainAndOnlyOwnerMayConfirm() public {
        (bytes32 jobId, bytes32 askId) = _unboundReview();
        OracleAttestation.Attestation memory a = _attestation(askId, true);
        bytes memory signature = _sign(a, signerKey);
        bytes32 bodyHash = requester.getReviewAsk(askId).bodyHash;
        vm.prank(stranger);
        vm.expectRevert(HookJobRequester.NotTheIntake.selector);
        requester.onReviewResult(askId, a, signature);
        assertEq(requester.getReviewReceipt(askId).oracleRequestId, bytes32(0));
        assertTrue(_deliver(askId, a));
        vm.prank(creator);
        vm.expectRevert(StoreAdmin.NotOwner.selector);
        requester.bindReview(askId, bodyHash, a.requestId, a.questionHash, a.chainId, a.fromBlock, a.toBlock);
        vm.prank(address(intake));
        vm.expectRevert(StoreAdmin.NotOwner.selector);
        requester.bindReview(askId, bodyHash, a.requestId, a.questionHash, a.chainId, a.fromBlock, a.toBlock);
        _assertReceipt(jobId, askId, a);
        _confirm(askId, a);
    }

    function testReceiptBindingStillRequiresExactBodyFingerprint() public {
        (, bytes32 askId) = _unboundReview();
        OracleAttestation.Attestation memory a = _attestation(askId, true);
        assertTrue(_deliver(askId, a));
        bytes32 bodyHash = requester.getReviewAsk(askId).bodyHash;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.ReviewBodyMismatch.selector, bodyHash, bytes32(0)));
        requester.bindReview(askId, bytes32(0), a.requestId, a.questionHash, a.chainId, a.fromBlock, a.toBlock);
        _confirm(askId, a);
    }

    function testConfirmedReceiptCannotBeReplayedOrRebound() public {
        (, bytes32 askId) = _unboundReview();
        OracleAttestation.Attestation memory a = _attestation(askId, true);
        assertTrue(_deliver(askId, a));
        _confirm(askId, a);
        bytes memory signature = _sign(a, signerKey);
        bytes32 bodyHash = requester.getReviewAsk(askId).bodyHash;
        vm.prank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.UnknownOrSettled.selector, askId));
        requester.onReviewResult(askId, a, signature);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.UnknownOrSettled.selector, askId));
        requester.bindReview(askId, bodyHash, a.requestId, a.questionHash, a.chainId, a.fromBlock, a.toBlock);
        assertTrue(requester.consumed(a.requestId));
    }

    function testFuzzRequesterCannotDiscardRetainedAnswerOrBuyAnotherReview(bool passed) public {
        (bytes32 jobId, bytes32 askId) = _unboundReview();
        OracleAttestation.Attestation memory answer = _attestation(askId, passed);
        assertTrue(_deliver(askId, answer));
        uint64 deadline = requester.getReviewAsk(askId).deadline;
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.DeadlineNotReached.selector, deadline));
        requester.expireReview(jobId);
        vm.warp(deadline + 1);
        vm.prank(stranger);
        vm.expectRevert(HookJobRequester.NotRequester.selector);
        requester.expireReview(jobId);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.ReviewAlreadyReceived.selector, askId));
        requester.expireReview(jobId);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.NotReviewable.selector, jobId));
        requester.requestReview(jobId);
        assertEq(requester.reviewOf(askId), jobId);
        assertEq(requester.getReviewReceipt(askId).oracleRequestId, answer.requestId);
        assertEq(requester.getReviewReceipt(askId).passed, passed);
        _confirm(askId, answer);
        _assertVerdict(jobId, askId, answer);
        assertEq(imd.balanceOf(address(intake)), 2 * PRICE, "no second review fee");
    }

    function testInvalidOneAttemptCallbackLosesFeeAndCannotRetryOrCreateReceipt() public {
        uint256 initialBalance = imd.balanceOf(creator);
        (bytes32 jobId, bytes32 askId) = _unboundReview();
        OracleAttestation.Attestation memory a = _attestation(askId, true);
        bytes memory badSignature = _sign(a, signerKey + 1);
        assertFalse(intake.complete(askId, abi.encode(askId, a, badSignature)));
        (,,,,,, bool settled) = intake.reqs(askId);
        assertTrue(settled, "failed callbacks are terminal at Intake too");
        assertEq(requester.getReviewReceipt(askId).oracleRequestId, bytes32(0));
        assertFalse(requester.consumed(a.requestId));
        assertEq(uint8(_review(jobId)), uint8(HookJobRequester.ReviewStatus.Pending));
        _confirm(askId, a);
        assertEq(uint8(_review(jobId)), uint8(HookJobRequester.ReviewStatus.Pending), "binding cannot invent a receipt");
        bytes memory payload = abi.encode(askId, a, _sign(a, signerKey));
        vm.expectRevert("not pending");
        intake.complete(askId, payload);
        vm.warp(requester.getReviewAsk(askId).deadline + 1);
        vm.prank(creator);
        requester.expireReview(jobId);
        assertEq(imd.balanceOf(creator), initialBalance - 2 * PRICE, "no refund on invalid delivery");
        assertEq(imd.balanceOf(address(intake)), 2 * PRICE);
        _requestReview(jobId);
        assertEq(imd.balanceOf(creator), initialBalance - 3 * PRICE, "retry is a new paid ask");
    }

    function testFuzzInvalidEarlyAnswerNeverCreatesReceiptOrVerdict(uint8 fault) public {
        fault = uint8(bound(fault, 0, 17));
        (bytes32 jobId, bytes32 askId) = _unboundReview();
        OracleAttestation.Attestation memory a = _attestation(askId, true);
        if (fault == 0) a.answerType = OracleAttestation.ANSWER_UINT256;
        if (fault == 1) a.answer = abi.encode(uint256(2)); // Not an ABI bool.
        if (fault == 2) a.answer = hex"01";
        if (fault == 3) a.expiresAt = uint64(vm.getBlockTimestamp() - 1);
        if (fault == 4) a.issuedAt -= requester.ISSUED_AT_TOLERANCE() + 1;
        if (fault == 5) a.issuedAt += requester.ISSUED_AT_TOLERANCE() + 1;
        if (fault == 6) a.requestId = bytes32(0);
        if (fault == 7) a.questionHash = bytes32(0);
        if (fault == 8) a.chainId = 0;
        if (fault == 9) a.fromBlock = a.toBlock + 1;
        if (fault == 10) a.panelSize = 3;
        if (fault == 11) a.quorum = 3;
        if (fault == 12) a.agreed = 4;
        if (fault == 13) a.agreed = 8;
        bytes memory signature = _sign(a, signerKey);
        if (fault == 14) signature = _sign(a, signerKey + 1);
        if (fault == 15) a.answer = abi.encode(false); // Tampered after signing.
        if (fault == 16) signature = hex"01";
        if (fault == 17) {
            vm.chainId(31338);
            signature = _sign(a, signerKey);
            vm.chainId(31337);
        }
        assertFalse(intake.complete(askId, abi.encode(askId, a, signature)));
        assertEq(uint8(_review(jobId)), uint8(HookJobRequester.ReviewStatus.Pending));
        assertEq(requester.reviewOf(askId), jobId);
        assertEq(requester.getReviewReceipt(askId).oracleRequestId, bytes32(0));
        assertFalse(requester.consumed(a.requestId));
        assertEq(imd.balanceOf(address(intake)), 2 * PRICE);
    }

    function testMalformedOneShotCallbackCannotCreateReceipt() public {
        (bytes32 jobId, bytes32 askId) = _unboundReview();
        assertFalse(intake.complete(askId, abi.encode(askId)));
        assertEq(requester.getReviewReceipt(askId).oracleRequestId, bytes32(0));
        assertEq(uint8(_review(jobId)), uint8(HookJobRequester.ReviewStatus.Pending));
    }

    function testIntakeFailureBeforeReceiptIsTerminalAndBindingCannotInventAnAnswer() public {
        (bytes32 jobId, bytes32 askId) = _unboundReview();
        OracleAttestation.Attestation memory a = _attestation(askId, false);
        assertTrue(intake.fail(askId, 2, "disagreed", 2, 7));
        bytes32 bodyHash = requester.getReviewAsk(askId).bodyHash;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.UnknownOrSettled.selector, askId));
        requester.bindReview(askId, bodyHash, a.requestId, a.questionHash, a.chainId, a.fromBlock, a.toBlock);
        bytes memory signature = _sign(a, signerKey);
        vm.prank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.UnknownOrSettled.selector, askId));
        requester.onReviewResult(askId, a, signature);
        assertEq(uint8(_review(jobId)), uint8(HookJobRequester.ReviewStatus.Unanswered));
        assertFalse(requester.consumed(a.requestId));
    }

    function testFuzzClockSkewToleranceIsSymmetricAtAskTime(int16 skew, bool prebound) public {
        skew = int16(bound(int256(skew), -360, 360));
        (bytes32 jobId, bytes32 askId) = _unboundReview();
        if (prebound) _bind(askId);
        OracleAttestation.Attestation memory a = _attestation(askId, true);
        a.issuedAt = uint64(uint256(int256(vm.getBlockTimestamp()) + skew));
        bool accepted = skew >= -300 && skew <= 300;
        assertEq(_deliver(askId, a), accepted);
        if (accepted) {
            if (!prebound) _confirm(askId, a);
            _assertVerdict(jobId, askId, a);
        } else {
            assertFalse(requester.consumed(a.requestId));
            assertEq(requester.getReviewReceipt(askId).oracleRequestId, bytes32(0));
        }
    }

    function testOneSecondBackwardSkewAndExactFiveMinuteBoundaryAccepted() public {
        for (uint64 skew = 1; skew <= 300; skew += 299) {
            (bytes32 jobId, bytes32 askId) = _unboundReview();
            OracleAttestation.Attestation memory a = _attestation(askId, true);
            a.issuedAt -= skew;
            vm.warp(vm.getBlockTimestamp() + 3 minutes);
            assertTrue(_deliver(askId, a));
            _confirm(askId, a);
            _assertVerdict(jobId, askId, a);
        }
    }

    function testTimestampExtremesDoNotOverflowSkewCheck() public {
        vm.warp(1);
        (bytes32 jobId, bytes32 askId) = _unboundReview();
        OracleAttestation.Attestation memory a = _attestation(askId, true);
        a.issuedAt = type(uint64).max;
        bytes memory signature = _sign(a, signerKey);
        vm.prank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(OracleAttestationConsumer.AttestationNotYetValid.selector, a.issuedAt));
        requester.onReviewResult(askId, a, signature);
        a.issuedAt = 0;
        assertTrue(_deliver(askId, a));
        _confirm(askId, a);
        _assertVerdict(jobId, askId, a);
    }

    function testFuzzFreshLateAnswerAcceptedUntilExplicitExpiry(bool prebound, uint32 delay) public {
        delay = uint32(bound(delay, 1, 60 days));
        vm.prank(owner);
        requester.setTimeouts(7 days, 1 hours);
        (bytes32 jobId, bytes32 askId) = _unboundReview();
        if (prebound) _bind(askId);
        vm.warp(uint256(requester.getReviewAsk(askId).deadline) + delay);
        OracleAttestation.Attestation memory a = _attestation(askId, false);
        assertTrue(_deliver(askId, a), "timeout only enables explicit abandonment");
        if (!prebound) _confirm(askId, a);
        _assertVerdict(jobId, askId, a);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.UnknownOrSettled.selector, jobId));
        requester.expireReview(jobId);
    }

    function testFreshLateAnswerRejectedIfRequesterExpiresFirst() public {
        (bytes32 jobId, bytes32 askId) = _reviewPending();
        vm.warp(requester.getReviewAsk(askId).deadline + 1);
        vm.prank(creator);
        requester.expireReview(jobId);
        OracleAttestation.Attestation memory a = _attestation(askId, true);
        assertFalse(_deliver(askId, a));
        assertFalse(requester.consumed(a.requestId));
        assertEq(uint8(_review(jobId)), uint8(HookJobRequester.ReviewStatus.Unanswered));
    }

    function testSignatureExpiryStillControlsArrivalEvenAfterAskDeadline() public {
        vm.prank(owner);
        requester.setTimeouts(7 days, 1 hours);
        (, bytes32 askId) = _unboundReview();
        OracleAttestation.Attestation memory a = _attestation(askId, true);
        vm.warp(requester.getReviewAsk(askId).deadline + 1);
        assertFalse(_deliver(askId, a), "expired signature cannot become a durable receipt");
        assertEq(requester.getReviewReceipt(askId).oracleRequestId, bytes32(0));
        assertFalse(requester.consumed(a.requestId));
    }

    function testAnswerAtExactSignatureExpiryCanBeRetainedAndConfirmedLater() public {
        (bytes32 jobId, bytes32 askId) = _unboundReview();
        OracleAttestation.Attestation memory a = _attestation(askId, true);
        vm.warp(a.expiresAt);
        assertTrue(_deliver(askId, a));
        vm.warp(vm.getBlockTimestamp() + 1);
        _confirm(askId, a);
        _assertVerdict(jobId, askId, a);
    }
}
