// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookJobRequesterFixture} from "./HookJobRequester.t.sol";
import {HookJobRequester} from "../src/imd/HookJobRequester.sol";
import {OracleAttestation} from "../src/imd/OracleAttestation.sol";
import {StoreAdmin} from "../src/store/StoreAdmin.sol";
import {MockIntake} from "./helpers/MockIntake.sol";
import {ImdTemplates} from "./helpers/ImdTemplates.sol";

/// @dev Reproductions for audit 648ba2e5: a retained answer with the ask's own UUID but another
/// signed question/chain/window had no closure at all; a body quorum below the configured minimum
/// burned an answer whose agreement met it; and step markers were checked on the joined template,
/// not on what a real body contains. Every delivery here is MockIntake's one-attempt 200k call.
contract AuditContextMismatchProofTest is HookJobRequesterFixture {
    bytes32 internal constant CONTEXT_MISMATCH = "receipt context mismatch";

    function _unbound() internal returns (bytes32 jobId, bytes32 askId) {
        jobId = _delivered();
        vm.prank(creator);
        askId = requester.requestReview(jobId, PRICE);
    }

    function _deliver(bytes32 askId, OracleAttestation.Attestation memory a) internal returns (bool) {
        bytes memory signature = _sign(a, signerKey);
        vm.cool(address(requester));
        vm.cool(signer);
        return intake.complete(askId, abi.encode(askId, a, signature));
    }

    function _bindTo(bytes32 askId, OracleAttestation.Attestation memory a) internal {
        bytes32 bodyHash = requester.getReviewAsk(askId).bodyHash;
        vm.prank(owner);
        requester.bindReview(askId, bodyHash, a.requestId, a.questionHash, a.chainId, a.fromBlock, a.toBlock);
    }

    function _discardMismatched(bytes32 askId, OracleAttestation.Attestation memory truth) internal {
        bytes32 bodyHash = requester.getReviewAsk(askId).bodyHash;
        bytes32 receiptHash = requester.reviewReceiptHash(askId);
        vm.prank(owner);
        requester.discardMismatchedReviewReceipt(
            askId, bodyHash, receiptHash, truth.questionHash, truth.chainId, truth.fromBlock, truth.toBlock
        );
    }

    /// @dev Same UUID as the ask's true context, one signed context field changed.
    function _signedVariant(OracleAttestation.Attestation memory truth, uint8 field, bool passed)
        internal
        pure
        returns (OracleAttestation.Attestation memory signed)
    {
        // Memory structs assign by reference; copy so the true context stays intact.
        signed = abi.decode(abi.encode(truth), (OracleAttestation.Attestation));
        signed.answer = abi.encode(passed);
        if (field == 0) signed.questionHash = keccak256("the panel answered another question document");
        if (field == 1) signed.chainId = 1;
        if (field == 2) signed.fromBlock = 0;
        if (field == 3) signed.toBlock = truth.toBlock + 1;
    }

    function _contains(bytes memory haystack, bytes memory needle) internal pure returns (bool) {
        if (needle.length > haystack.length) return false;
        for (uint256 i; i + needle.length <= haystack.length; ++i) {
            bool same = true;
            for (uint256 j; j < needle.length && same; ++j) {
                same = haystack[i + j] == needle[j];
            }
            if (same) return true;
        }
        return false;
    }

    // ---------------------------------------------------------------- finding 1: same UUID, other signed context

    function testFuzzSameUuidOtherSignedContextWasStuckAndNowClosesHonestly(uint8 field, bool passed) public {
        field = uint8(bound(field, 0, 3));
        (bytes32 jobId, bytes32 askId) = _unbound();
        OracleAttestation.Attestation memory truth = _attestation(askId, passed);
        OracleAttestation.Attestation memory signed = _signedVariant(truth, field, passed);
        assertTrue(_deliver(askId, signed), "valid signed answer is retained in one shot");
        HookJobRequester.ReviewReceipt memory receipt = requester.getReviewReceipt(askId);
        assertEq(receipt.oracleRequestId, truth.requestId);
        assertEq(receipt.passed, passed);
        bytes32 bodyHash = requester.getReviewAsk(askId).bodyHash;

        // Reproduction: every pre-existing path refuses, so the ask could never leave Pending.
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.ReviewAttestationMismatch.selector, askId));
        requester.bindReview(
            askId, bodyHash, truth.requestId, truth.questionHash, truth.chainId, truth.fromBlock, truth.toBlock
        );
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.ReviewAttestationMismatch.selector, askId));
        requester.discardReviewReceipt(
            askId, bodyHash, truth.requestId, truth.questionHash, truth.chainId, truth.fromBlock, truth.toBlock
        );
        vm.warp(requester.getReviewAsk(askId).deadline + 1);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.ReviewAlreadyReceived.selector, askId));
        requester.expireReview(jobId);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.ReviewAlreadyReceived.selector, askId));
        requester.confirmReviewExpiry(askId);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.NotReviewable.selector, jobId));
        requester.requestReview(jobId, PRICE);
        assertEq(uint8(_review(jobId)), uint8(HookJobRequester.ReviewStatus.Pending));

        // Fix: the owner sets the answer aside explicitly, naming the exact receipt and the true context.
        vm.expectEmit(true, true, true, true, address(requester));
        emit HookJobRequester.ReviewReceiptDiscarded(
            jobId,
            askId,
            truth.requestId,
            truth.requestId,
            truth.questionHash,
            truth.chainId,
            truth.fromBlock,
            truth.toBlock
        );
        vm.expectEmit(true, true, true, true, address(requester));
        emit HookJobRequester.ReviewUnanswered(jobId, askId, 0, CONTEXT_MISMATCH);
        _discardMismatched(askId, truth);
        assertEq(uint8(_review(jobId)), uint8(HookJobRequester.ReviewStatus.Unanswered));
        assertTrue(requester.discardedReviewReceipts(askId));
        assertEq(requester.reviewOf(askId), bytes32(0));
        assertEq(requester.getJob(jobId).reviewPanelSize, 0, "no verdict fields were set");
        // History is kept, verdict included; the UUID is neither consumed nor reserved.
        assertEq(abi.encode(requester.getReviewReceipt(askId)), abi.encode(receipt));
        assertFalse(requester.consumed(truth.requestId));
        assertEq(requester.intakeReviewOfOracle(truth.requestId), bytes32(0));
        assertTrue(requester.usedIntakeRequestIds(askId));
        assertEq(imd.balanceOf(address(intake)), 2 * PRICE, "no refund");

        // The closed Intake ID is terminal for every later notice.
        bytes memory trueSignature = _sign(truth, signerKey);
        vm.prank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.UnknownOrSettled.selector, askId));
        requester.onReviewResult(askId, truth, trueSignature);
        vm.prank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.UnknownOrSettled.selector, askId));
        requester.onReviewFailure(askId, 2, "late", 0, 0, "");
        bytes32 closedHash = requester.reviewReceiptHash(askId);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.UnknownOrSettled.selector, askId));
        requester.discardMismatchedReviewReceipt(askId, bodyHash, closedHash, truth.questionHash, truth.chainId, 1, 2);

        // A retry is a new paid ask with its own binding; the set-aside answer cannot settle it.
        vm.prank(creator);
        bytes32 retryId = requester.requestReview(jobId, PRICE);
        OracleAttestation.Attestation memory retryTruth = _attestation(retryId, !passed);
        _bindTo(retryId, retryTruth);
        signed.issuedAt = uint64(vm.getBlockTimestamp());
        signed.expiresAt = signed.issuedAt + 1 hours;
        assertTrue(_deliver(retryId, signed), "stale answer is retained, not finalized");
        assertEq(uint8(_review(jobId)), uint8(HookJobRequester.ReviewStatus.Pending));
        assertEq(requester.getReviewReceipt(retryId).oracleRequestId, truth.requestId);
        assertFalse(requester.consumed(truth.requestId));
    }

    function testContextMismatchRecoveryCannotSetAsideAMatchingVerdictOrBeCalledByRequester() public {
        (bytes32 jobId, bytes32 askId) = _unbound();
        OracleAttestation.Attestation memory truth = _attestation(askId, false);
        assertTrue(_deliver(askId, truth));
        bytes32 bodyHash = requester.getReviewAsk(askId).bodyHash;
        bytes32 receiptHash = requester.reviewReceiptHash(askId);
        // Not the requester, not a stranger.
        vm.prank(creator);
        vm.expectRevert(StoreAdmin.NotOwner.selector);
        requester.discardMismatchedReviewReceipt(
            askId, bodyHash, receiptHash, keccak256("some other question"), truth.chainId, 1, 2
        );
        vm.prank(stranger);
        vm.expectRevert(StoreAdmin.NotOwner.selector);
        requester.discardMismatchedReviewReceipt(
            askId, bodyHash, receiptHash, keccak256("some other question"), truth.chainId, 1, 2
        );
        // The receipt matches the ask's true context: it is a genuine NotPassed and can only be bound.
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.ReviewReceiptMatches.selector, askId));
        requester.discardMismatchedReviewReceipt(
            askId, bodyHash, receiptHash, truth.questionHash, truth.chainId, truth.fromBlock, truth.toBlock
        );
        // Wrong ask body, unacknowledged receipt and malformed context all revert before any change.
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(HookJobRequester.ReviewBodyMismatch.selector, bodyHash, keccak256("other body"))
        );
        requester.discardMismatchedReviewReceipt(
            askId, keccak256("other body"), receiptHash, keccak256("q"), truth.chainId, 1, 2
        );
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(HookJobRequester.ReviewReceiptMismatch.selector, receiptHash, bytes32(0))
        );
        requester.discardMismatchedReviewReceipt(askId, bodyHash, bytes32(0), keccak256("q"), truth.chainId, 1, 2);
        vm.prank(owner);
        vm.expectRevert(HookJobRequester.InvalidReviewBinding.selector);
        requester.discardMismatchedReviewReceipt(askId, bodyHash, receiptHash, bytes32(0), truth.chainId, 1, 2);
        vm.prank(owner);
        vm.expectRevert(HookJobRequester.InvalidReviewBinding.selector);
        requester.discardMismatchedReviewReceipt(askId, bodyHash, receiptHash, keccak256("q"), truth.chainId, 3, 2);
        assertEq(uint8(_review(jobId)), uint8(HookJobRequester.ReviewStatus.Pending));
        // The genuine negative verdict finalizes normally.
        _bindTo(askId, truth);
        assertEq(uint8(_review(jobId)), uint8(HookJobRequester.ReviewStatus.NotPassed));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.UnknownOrSettled.selector, askId));
        requester.discardMismatchedReviewReceipt(askId, bodyHash, receiptHash, keccak256("q"), truth.chainId, 1, 2);
    }

    function testContextMismatchRecoveryNeedsAnUnboundPendingAskWithAReceipt() public {
        (, bytes32 askId) = _unbound();
        OracleAttestation.Attestation memory truth = _attestation(askId, true);
        bytes32 bodyHash = requester.getReviewAsk(askId).bodyHash;
        bytes32 emptyHash = requester.reviewReceiptHash(askId);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.ReviewNotReceived.selector, askId));
        requester.discardMismatchedReviewReceipt(askId, bodyHash, emptyHash, keccak256("q"), truth.chainId, 1, 2);
        _bindTo(askId, truth);
        OracleAttestation.Attestation memory signed = _signedVariant(truth, 0, true);
        assertTrue(_deliver(askId, signed), "mismatch against a pre-binding is retained");
        bytes32 receiptHash = requester.reviewReceiptHash(askId);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.ReviewAlreadyBound.selector, askId));
        requester.discardMismatchedReviewReceipt(askId, bodyHash, receiptHash, truth.questionHash, truth.chainId, 1, 2);
        // Reset the pre-binding first, then the same recovery applies.
        vm.prank(owner);
        requester.resetReviewBinding(askId, bodyHash);
        _discardMismatched(askId, truth);
        assertTrue(requester.discardedReviewReceipts(askId));
        assertEq(requester.intakeReviewOfOracle(truth.requestId), bytes32(0));
    }

    /// @dev The acknowledgment commits to the verdict: a receipt hash computed for the opposite
    /// answer is refused, so tooling cannot set aside a NotPassed while describing a Passed.
    function testReceiptAcknowledgmentCommitsToTheVerdict() public {
        (, bytes32 askId) = _unbound();
        OracleAttestation.Attestation memory truth = _attestation(askId, false);
        assertTrue(_deliver(askId, _signedVariant(truth, 0, false)));
        HookJobRequester.ReviewReceipt memory receipt = requester.getReviewReceipt(askId);
        assertFalse(receipt.passed);
        receipt.passed = true;
        bytes32 wrongHash = keccak256(abi.encode(receipt));
        bytes32 bodyHash = requester.getReviewAsk(askId).bodyHash;
        bytes32 rightHash = requester.reviewReceiptHash(askId);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.ReviewReceiptMismatch.selector, rightHash, wrongHash));
        requester.discardMismatchedReviewReceipt(
            askId, bodyHash, wrongHash, truth.questionHash, truth.chainId, truth.fromBlock, truth.toBlock
        );
        assertEq(
            requester.reviewReceiptHash(bytes32(uint256(99))),
            keccak256(abi.encode(requester.getReviewReceipt(bytes32(uint256(99)))))
        );
    }

    // ---------------------------------------------------------------- finding 2: quorum versus configured minimum

    function testFuzzBodyQuorumBelowConfiguredMinimumNoLongerBurnsAnAgreedAnswer(
        uint16 quorum,
        uint16 agreed,
        bool passed,
        bool prebound
    ) public {
        // Template minimums are panel 5, agreement 4; the fixture panel is 7.
        agreed = uint16(bound(agreed, 4, 7));
        quorum = uint16(bound(quorum, 0, agreed));
        (bytes32 jobId, bytes32 askId) = _unbound();
        OracleAttestation.Attestation memory a = _attestation(askId, passed);
        a.quorum = quorum;
        a.agreed = agreed;
        if (prebound) _bindTo(askId, a);
        assertTrue(_deliver(askId, a), "agreement at or above the configured minimum is accepted");
        if (!prebound) {
            assertEq(requester.getReviewReceipt(askId).agreed, agreed);
            _bindTo(askId, a);
        }
        assertEq(
            uint8(_review(jobId)),
            uint8(passed ? HookJobRequester.ReviewStatus.Passed : HookJobRequester.ReviewStatus.NotPassed)
        );
        assertEq(requester.getJob(jobId).reviewAgreed, agreed);
        assertEq(requester.getJob(jobId).reviewPanelSize, 7);
        assertTrue(requester.consumed(a.requestId));
    }

    function testReproductionQuorumOneWithSixAgreedIsAValidAnswer() public {
        (bytes32 jobId, bytes32 askId) = _reviewPending();
        OracleAttestation.Attestation memory a = _attestation(askId, false);
        a.quorum = 1;
        a.agreed = 6;
        assertTrue(_deliver(askId, a), "the old quorum < minAgreed check burned this one-shot answer");
        assertEq(uint8(_review(jobId)), uint8(HookJobRequester.ReviewStatus.NotPassed));
    }

    function testFuzzPanelStrengthMinimumsStillRefuseWeakAnswersInOneShot(uint8 kind) public {
        kind = uint8(bound(kind, 0, 3));
        (bytes32 jobId, bytes32 askId) = _reviewPending();
        OracleAttestation.Attestation memory a = _attestation(askId, true);
        if (kind == 0) a.panelSize = 4; // below minPanelSize 5
        if (kind == 1) {
            a.quorum = 3;
            a.agreed = 3; // meets the signed quorum, below minAgreed 4
        }
        if (kind == 2) a.agreed = 4; // below the signed quorum 5
        if (kind == 3) a.agreed = 8; // more agreement than seats
        uint256 before = imd.balanceOf(creator);
        assertFalse(_deliver(askId, a), "a weak answer fails closed and the one attempt is spent");
        assertEq(uint8(_review(jobId)), uint8(HookJobRequester.ReviewStatus.Pending));
        assertEq(requester.getReviewReceipt(askId).oracleRequestId, bytes32(0));
        assertFalse(requester.consumed(a.requestId));
        assertEq(imd.balanceOf(creator), before, "no refund and no further debit");
        bytes memory signature = _sign(a, signerKey);
        vm.prank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.PanelTooWeak.selector, a.panelSize, a.quorum, a.agreed));
        requester.onReviewResult(askId, a, signature);
        // Closure of the burned ask stays with the owner, after the deadline, exactly as before.
        vm.warp(requester.getReviewAsk(askId).deadline + 1);
        _confirmExpiry(askId);
        assertEq(uint8(_review(jobId)), uint8(HookJobRequester.ReviewStatus.Unanswered));
    }

    // ---------------------------------------------------------------- finding 3: markers in the assembled body

    function testFuzzStepMarkerSplitAcrossFragmentsIsRefused(uint8 marker, uint8 boundary, uint8 cut) public {
        marker = uint8(bound(marker, 0, 2));
        boundary = uint8(bound(boundary, 0, 1));
        bytes memory step =
            marker == 0 ? bytes("forge build") : marker == 1 ? bytes("forge test") : bytes("adversarial review");
        cut = uint8(bound(cut, 1, step.length - 1));
        bytes memory head = new bytes(cut);
        bytes memory tail = new bytes(step.length - cut);
        for (uint256 i; i < step.length; ++i) {
            if (i < cut) head[i] = step[i];
            else tail[i - cut] = step[i];
        }
        bytes memory others = marker == 0
            ? bytes(" forge test adversarial review ")
            : marker == 1 ? bytes(" forge build adversarial review ") : bytes(" forge build forge test ");
        bytes memory prefix;
        bytes memory middle;
        bytes memory suffix;
        if (boundary == 0) {
            prefix = bytes.concat(others, head);
            middle = bytes.concat(tail, " <brief>");
            suffix = "</brief>";
        } else {
            prefix = others;
            middle = bytes.concat(" <brief>", head);
            suffix = bytes.concat(tail, "</brief>");
        }
        // The joined template contains the marker; no assembled body ever does.
        assertTrue(_contains(bytes.concat(prefix, middle, suffix), step));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.TemplateMissingStep.selector, step));
        requester.setJobTemplate(JOB_ACTION, prefix, middle, suffix);
        // The accepted template from before this call still assembles complete bodies.
        bytes32 id = _open();
        assertTrue(_contains(intake.bodyOf(id), step));
    }

    function testFuzzAcceptedTemplateNamesEveryStepInEveryAssembledBody(bytes32 specHash, uint16 length, uint8 salt)
        public
    {
        length = uint16(bound(length, 1, 300));
        bytes memory brief = new bytes(length);
        for (uint256 i; i < length; ++i) {
            brief[i] = bytes1(uint8(0x61 + (uint256(salt) + i) % 26));
        }
        vm.prank(creator);
        bytes32 id = requester.openJob(specHash, brief, PRICE);
        bytes memory body = intake.bodyOf(id);
        assertTrue(_contains(body, "forge build"));
        assertTrue(_contains(body, "forge test"));
        assertTrue(_contains(body, "adversarial review"));
        assertTrue(_contains(body, brief));
        assertEq(requester.getJob(id).bodyHash, keccak256(body));
    }

    function testMarkersOnlyACreatorBriefCouldSupplyDoNotSatisfyTheTemplate() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.TemplateMissingStep.selector, bytes("forge build")));
        requester.setJobTemplate(JOB_ACTION, "{\"request\":\"<brief>", "", "</brief>\"}");
        // Markers may sit in any single fragment, including the suffix alone.
        vm.prank(owner);
        requester.setJobTemplate(
            JOB_ACTION, "{\"request\":\"<brief>", "", "</brief>, then forge build, forge test, adversarial review\"}"
        );
        vm.prank(creator);
        bytes32 id = requester.openJob(SPEC_HASH, "forge build forge test adversarial review", PRICE);
        assertTrue(_contains(intake.bodyOf(id), "then forge build, forge test, adversarial review"));
    }

    // ---------------------------------------------------------------- synchronous Intake refusal

    function testFuzzSynchronousIntakeRefusalRevertsTheWholeAskWithoutDebit(bytes4 code, bool v1) public {
        vm.assume(code != bytes4(0));
        bytes32 jobId = _delivered();
        if (v1) {
            intake.setV1(true);
            vm.prank(owner);
            requester.setFailureHook(false);
        }
        intake.setRefusal(code);
        uint256 creatorBefore = imd.balanceOf(creator);
        uint256 intakeBefore = imd.balanceOf(address(intake));
        bytes memory expected = abi.encodeWithSelector(MockIntake.SynchronousRefusal.selector, code);
        vm.prank(creator);
        vm.expectRevert(expected);
        requester.openJob(SPEC_HASH, "A swap cap hook", PRICE);
        vm.prank(creator);
        vm.expectRevert(expected);
        requester.requestReview(jobId, PRICE);
        assertEq(imd.balanceOf(creator), creatorBefore, "refusal before payment leaves the wallet untouched");
        assertEq(imd.balanceOf(address(intake)), intakeBefore);
        assertEq(imd.balanceOf(address(requester)), 0);
        assertEq(imd.allowance(address(requester), address(intake)), 0);
        assertEq(requester.jobCount(), 1);
        assertEq(uint8(_status(jobId)), uint8(HookJobRequester.JobStatus.Delivered));
        assertEq(uint8(_review(jobId)), uint8(HookJobRequester.ReviewStatus.None));
        assertEq(requester.getJob(jobId).reviewRequestId, bytes32(0));
        // Once the Intake sells the action again the same calls go through.
        intake.setRefusal(bytes4(0));
        vm.prank(creator);
        bytes32 askId = requester.requestReview(jobId, PRICE);
        assertEq(uint8(_review(jobId)), uint8(HookJobRequester.ReviewStatus.Pending));
        assertTrue(requester.usedIntakeRequestIds(askId));
        assertEq(imd.balanceOf(creator), creatorBefore - PRICE);
    }

    /// @dev An asynchronous refusal (status 1 after payment) is the other shape the live Intake
    /// may use; it closes the ask through the failure function and keeps the fee.
    function testAsynchronousRefusalAfterPaymentClosesWithoutRefund() public {
        (bytes32 jobId, bytes32 askId) = _unbound();
        uint256 before = imd.balanceOf(creator);
        assertTrue(intake.fail(askId, 1, "body_refused", 0, 0));
        assertEq(uint8(_review(jobId)), uint8(HookJobRequester.ReviewStatus.Unanswered));
        assertEq(imd.balanceOf(creator), before);
        vm.prank(creator);
        requester.requestReview(jobId, PRICE);
        assertEq(imd.balanceOf(creator), before - PRICE);
    }
}
