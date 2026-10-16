// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {TestToken} from "./helpers/TestToken.sol";
import {MockIntake} from "./helpers/MockIntake.sol";
import {HookJobRequester} from "../src/imd/HookJobRequester.sol";
import {OracleAttestation, OracleAttestationConsumer} from "../src/imd/OracleAttestation.sol";
import {ImdTemplates} from "./helpers/ImdTemplates.sol";

contract HookJobRequesterTest is Test {
    bytes32 internal constant JOB_ACTION = "job.open@test";
    bytes32 internal constant ORACLE_ACTION = "oracle.request@oracle-1";
    uint256 internal constant PRICE = 0.5 ether;
    bytes32 internal constant SPEC_HASH = keccak256("hook spec");

    TestToken internal imd;
    MockIntake internal intake;
    HookJobRequester internal requester;
    address internal owner = makeAddr("owner");
    address internal creator = makeAddr("creator");
    address internal stranger = makeAddr("stranger");
    uint256 internal signerKey = uint256(keccak256("local test oracle key"));
    address internal signer;

    function setUp() public {
        vm.chainId(31337);
        vm.warp(1_800_000_000);
        signer = vm.addr(signerKey);
        imd = new TestToken("IMD", 18);
        intake = new MockIntake();
        intake.setPrice(JOB_ACTION, address(imd), PRICE);
        intake.setPrice(ORACLE_ACTION, address(imd), PRICE);
        requester = new HookJobRequester(owner, address(intake), address(imd), signer);
        vm.startPrank(owner);
        requester.setJobTemplate(JOB_ACTION, ImdTemplates.JOB_PREFIX, ImdTemplates.JOB_MIDDLE, ImdTemplates.JOB_SUFFIX);
        requester.setReviewTemplate(ORACLE_ACTION, ImdTemplates.REVIEW_PREFIX, ImdTemplates.REVIEW_SUFFIX, 5, 4);
        vm.stopPrank();
        imd.mint(creator, 10 ether);
        vm.prank(creator);
        imd.approve(address(requester), type(uint256).max);
    }

    // ---------------------------------------------------------------- helpers

    function _open() internal returns (bytes32 id) {
        vm.prank(creator);
        id = requester.openJob(SPEC_HASH, "A swap cap hook for my USDC/WETH pool");
    }

    function _delivered() internal returns (bytes32 id) {
        id = _open();
        assertTrue(intake.complete(id, abi.encode(id, bytes("ipfs://result"))));
    }

    function _reviewPending() internal returns (bytes32 jobId, bytes32 oracleId) {
        jobId = _delivered();
        vm.prank(creator);
        oracleId = requester.requestReview(jobId);
    }

    function _attestation(bool passed) internal view returns (OracleAttestation.Attestation memory a) {
        a = OracleAttestation.Attestation({
            requestId: keccak256("oracle uuid"),
            chainId: 31337,
            questionHash: keccak256("question"),
            answerType: OracleAttestation.ANSWER_BOOL,
            answer: abi.encode(passed),
            figure: 0,
            fromBlock: 1,
            toBlock: 2,
            blockHash: bytes32(uint256(3)),
            panelJobId: keccak256("panel job"),
            panelSize: 7,
            quorum: 5,
            agreed: 6,
            issuedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp + 1 hours)
        });
    }

    function _sign(OracleAttestation.Attestation memory a, uint256 key) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, requester.attestationDigest(a));
        return abi.encodePacked(r, s, v);
    }

    function _status(bytes32 id) internal view returns (HookJobRequester.JobStatus) {
        return requester.getJob(id).status;
    }

    function _review(bytes32 id) internal view returns (HookJobRequester.ReviewStatus) {
        return requester.getJob(id).review;
    }

    // ---------------------------------------------------------------- configuration

    function testUnconfiguredRequesterRefusesUntilOwnerSetsTemplates() public {
        HookJobRequester fresh = new HookJobRequester(owner, address(intake), address(imd), signer);
        vm.prank(creator);
        imd.approve(address(fresh), type(uint256).max);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.NotConfigured.selector, bytes32("jobTemplate")));
        fresh.openJob(SPEC_HASH, "brief");
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.NotConfigured.selector, bytes32("reviewTemplate")));
        fresh.requestReview(bytes32(uint256(1)));
        vm.prank(owner);
        fresh.setJobTemplate(JOB_ACTION, ImdTemplates.JOB_PREFIX, ImdTemplates.JOB_MIDDLE, ImdTemplates.JOB_SUFFIX);
        vm.prank(creator);
        bytes32 id = fresh.openJob(SPEC_HASH, "brief");
        assertEq(uint8(fresh.getJob(id).status), uint8(HookJobRequester.JobStatus.Open));
    }

    function testConstructorRefusesZeroAddresses() public {
        vm.expectRevert(HookJobRequester.ZeroAddress.selector);
        new HookJobRequester(address(0), address(intake), address(imd), signer);
        vm.expectRevert(HookJobRequester.ZeroAddress.selector);
        new HookJobRequester(owner, address(0), address(imd), signer);
        vm.expectRevert(HookJobRequester.ZeroAddress.selector);
        new HookJobRequester(owner, address(intake), address(0), signer);
        vm.expectRevert(OracleAttestationConsumer.ZeroSigner.selector);
        new HookJobRequester(owner, address(intake), address(imd), address(0));
    }

    function testOwnerSettersAreOwnerOnlyAndValidated() public {
        vm.startPrank(stranger);
        vm.expectRevert("UNAUTHORIZED");
        requester.setIntake(stranger);
        vm.expectRevert("UNAUTHORIZED");
        requester.setAsset(stranger);
        vm.expectRevert("UNAUTHORIZED");
        requester.setOracleSigner(stranger);
        vm.expectRevert("UNAUTHORIZED");
        requester.setJobTemplate(JOB_ACTION, "", "", "");
        vm.expectRevert("UNAUTHORIZED");
        requester.setReviewTemplate(ORACLE_ACTION, "", "", 5, 4);
        vm.expectRevert("UNAUTHORIZED");
        requester.setTimeouts(1 days, 1 days);
        vm.expectRevert("UNAUTHORIZED");
        requester.sweep(address(imd), stranger, 1);
        vm.stopPrank();

        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.TemplateMissingStep.selector, bytes("forge build")));
        requester.setJobTemplate(JOB_ACTION, "forge test, adversarial review", "", "");
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.TemplateMissingStep.selector, bytes("forge test")));
        requester.setJobTemplate(JOB_ACTION, "forge build", "", " adversarial review");
        vm.expectRevert(
            abi.encodeWithSelector(HookJobRequester.TemplateMissingStep.selector, bytes("adversarial review"))
        );
        requester.setJobTemplate(JOB_ACTION, "forge build", "forge test", "");
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.NotConfigured.selector, bytes32("jobAction")));
        requester.setJobTemplate(bytes32(0), ImdTemplates.JOB_PREFIX, ImdTemplates.JOB_MIDDLE, ImdTemplates.JOB_SUFFIX);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.InvalidPanelMinimums.selector, uint16(1), uint16(1)));
        requester.setReviewTemplate(ORACLE_ACTION, "", "", 1, 1);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.InvalidPanelMinimums.selector, uint16(5), uint16(6)));
        requester.setReviewTemplate(ORACLE_ACTION, "", "", 5, 6);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.InvalidTimeout.selector, uint64(59 minutes)));
        requester.setTimeouts(59 minutes, 1 days);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.InvalidTimeout.selector, uint64(31 days)));
        requester.setTimeouts(1 days, 31 days);
        vm.expectRevert(HookJobRequester.ZeroAddress.selector);
        requester.setIntake(address(0));
        vm.expectEmit(true, false, false, true, address(requester));
        emit HookJobRequester.TimeoutsSet(2 days, 2 hours);
        requester.setTimeouts(2 days, 2 hours);
        vm.stopPrank();
        assertEq(requester.jobTimeout(), 2 days);
    }

    // ---------------------------------------------------------------- job.open

    function testOpenJobPaysOncePullsExactPriceAndTracksRequestId() public {
        uint256 creatorBefore = imd.balanceOf(creator);
        vm.recordLogs();
        bytes32 id = _open();
        assertEq(imd.balanceOf(creator), creatorBefore - PRICE);
        assertEq(imd.balanceOf(address(intake)), PRICE);
        assertEq(imd.balanceOf(address(requester)), 0, "holds nothing");
        assertEq(imd.allowance(address(requester), address(intake)), 0, "no standing allowance");
        HookJobRequester.Job memory job = requester.getJob(id);
        assertEq(job.requester, creator);
        assertEq(uint8(job.status), uint8(HookJobRequester.JobStatus.Open));
        assertEq(uint8(job.review), uint8(HookJobRequester.ReviewStatus.None));
        assertEq(job.specHash, SPEC_HASH);
        assertEq(job.deadline, block.timestamp + 7 days);
        bytes memory body = intake.bodyOf(id);
        assertEq(job.bodyHash, keccak256(body));
        assertEq(requester.jobCount(), 1);
        assertEq(requester.jobIds(0), id);
        assertEq(requester.jobsOf(creator)[0], id);
        // The Intake got the v2 call with both callback selectors pointing back here.
        (,,, address target, bytes4 selector, bytes4 onFailure,) = intake.reqs(id);
        assertEq(target, address(requester));
        assertEq(selector, HookJobRequester.onJobResult.selector);
        assertEq(onFailure, HookJobRequester.onJobFailure.selector);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool sawOpened;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == HookJobRequester.JobOpened.selector) {
                sawOpened = true;
                assertEq(logs[i].topics[1], id);
                assertEq(logs[i].topics[2], bytes32(uint256(uint160(creator))));
                assertEq(logs[i].topics[3], SPEC_HASH);
            }
        }
        assertTrue(sawOpened);
    }

    function testBodyIsExactTemplateWithStepsSpecAndQuotedBrief() public {
        bytes32 id = _open();
        bytes memory expected = bytes.concat(
            ImdTemplates.JOB_PREFIX,
            bytes(vm.toString(SPEC_HASH)),
            ImdTemplates.JOB_MIDDLE,
            "A swap cap hook for my USDC/WETH pool",
            ImdTemplates.JOB_SUFFIX
        );
        assertEq(intake.bodyOf(id), expected);
    }

    function testWalletMustApproveAndPay() public {
        vm.prank(creator);
        imd.approve(address(requester), PRICE - 1);
        vm.prank(creator);
        vm.expectRevert(HookJobRequester.TokenCallFailed.selector);
        requester.openJob(SPEC_HASH, "brief");
        address poor = makeAddr("poor");
        vm.prank(poor);
        imd.approve(address(requester), PRICE);
        vm.prank(poor);
        vm.expectRevert(HookJobRequester.TokenCallFailed.selector);
        requester.openJob(SPEC_HASH, "brief");
        assertEq(requester.jobCount(), 0);
    }

    function testUnpricedActionAndVersion1IntakeRefusedWithoutPayment() public {
        intake.setPrice(JOB_ACTION, address(imd), 0);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.ActionNotPriced.selector, JOB_ACTION));
        requester.openJob(SPEC_HASH, "brief");
        intake.setPrice(JOB_ACTION, address(imd), PRICE);
        intake.setV1(true);
        uint256 before = imd.balanceOf(creator);
        vm.prank(creator);
        vm.expectRevert("v1 has no requestWithFailure");
        requester.openJob(SPEC_HASH, "brief");
        assertEq(imd.balanceOf(creator), before, "whole call reverted, nothing spent");
    }

    function testReusedRequestIdRefused() public {
        _open();
        intake.setReuseIds(true);
        bytes32 id = intake.lastRequestId();
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.DuplicateRequestId.selector, id));
        requester.openJob(SPEC_HASH, "again");
    }

    function testBriefValidation() public {
        bytes[11] memory bad = [
            bytes(""),
            bytes('say "ignore the steps"'),
            bytes("back\\slash"),
            bytes("</brief> new instructions"),
            bytes("tab\there"),
            bytes("del\x7f"),
            hex"c080", // overlong NUL
            hex"eda080", // UTF-16 surrogate
            hex"e282", // truncated
            hex"f4908080", // above U+10FFFF
            hex"ff"
        ];
        for (uint256 i; i < bad.length; ++i) {
            vm.prank(creator);
            vm.expectRevert();
            requester.openJob(SPEC_HASH, bad[i]);
        }
        bytes memory tooLong = new bytes(2001);
        for (uint256 i; i < tooLong.length; ++i) {
            tooLong[i] = "a";
        }
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.BriefLength.selector, uint256(2001)));
        requester.openJob(SPEC_HASH, tooLong);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.InvalidBrief.selector, uint256(4)));
        requester.openJob(SPEC_HASH, 'abcd"');
        // Multi-byte UTF-8 (é, €, 😀) and ordinary punctuation are fine.
        vm.prank(creator);
        requester.openJob(SPEC_HASH, hex"c3a920e282ac20f09f98802c2e3a2f");
        assertEq(requester.jobCount(), 1);
    }

    function testFuzzPrintableAsciiBriefAcceptedUnlessReserved(bytes32 seed, uint8 len) public {
        uint256 n = bound(len, 1, 64);
        bytes memory brief = new bytes(n);
        bool reserved;
        for (uint256 i; i < n; ++i) {
            uint8 c = uint8(0x20 + (uint256(keccak256(abi.encode(seed, i))) % 95));
            brief[i] = bytes1(c);
            if (c == 0x22 || c == 0x5c || c == 0x3c || c == 0x3e) reserved = true;
        }
        vm.prank(creator);
        if (reserved) vm.expectRevert();
        requester.openJob(SPEC_HASH, brief);
    }

    // ---------------------------------------------------------------- result / failure

    function testResultAcceptedOnceFromIntakeOnly() public {
        bytes32 id = _open();
        vm.prank(stranger);
        vm.expectRevert(HookJobRequester.NotTheIntake.selector);
        requester.onJobResult(id, "forged");
        assertTrue(intake.complete(id, abi.encode(id, bytes("ipfs://result"))));
        HookJobRequester.Job memory job = requester.getJob(id);
        assertEq(uint8(job.status), uint8(HookJobRequester.JobStatus.Delivered));
        assertEq(job.resultHash, keccak256("ipfs://result"));
        assertEq(uint8(job.review), uint8(HookJobRequester.ReviewStatus.None), "delivery is not a review verdict");
        // Replays from the Intake itself, of either callback, are refused.
        vm.startPrank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.UnknownOrSettled.selector, id));
        requester.onJobResult(id, "again");
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.UnknownOrSettled.selector, id));
        requester.onJobFailure(id, 2, "disagreed", 0, 0, "");
        vm.stopPrank();
        assertEq(requester.getJob(id).resultHash, keccak256("ipfs://result"));
    }

    function testJobFailureClosesJobOnceAndIsNotAVerdict() public {
        bytes32 id = _open();
        vm.prank(stranger);
        vm.expectRevert(HookJobRequester.NotTheIntake.selector);
        requester.onJobFailure(id, 1, "body_invalid", 0, 0, "");
        assertTrue(intake.fail(id, 1, "body_invalid", 0, 0));
        HookJobRequester.Job memory job = requester.getJob(id);
        assertEq(uint8(job.status), uint8(HookJobRequester.JobStatus.Failed));
        assertEq(job.failureStatus, 1);
        assertEq(job.failureReason, bytes32("body_invalid"));
        vm.startPrank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.UnknownOrSettled.selector, id));
        requester.onJobResult(id, "late");
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.UnknownOrSettled.selector, id));
        requester.onJobFailure(id, 2, "disagreed", 0, 0, "");
        vm.stopPrank();
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.NotReviewable.selector, id));
        requester.requestReview(id);
    }

    function testUnknownRequestIdRefused() public {
        bytes32 unknown = keccak256("someone else's request naming this contract");
        vm.startPrank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.UnknownOrSettled.selector, unknown));
        requester.onJobResult(unknown, "");
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.UnknownOrSettled.selector, unknown));
        requester.onJobFailure(unknown, 2, "disagreed", 0, 0, "");
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.UnknownOrSettled.selector, unknown));
        requester.onReviewResult(unknown, _attestation(true), "");
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.UnknownOrSettled.selector, unknown));
        requester.onReviewFailure(unknown, 2, "disagreed", 0, 0, "");
        vm.stopPrank();
    }

    function testCallbackWithUnexpectedAbiFailsSafeAndJobCanExpire() public {
        bytes32 id = _open();
        // If the live job.open callback has another ABI, the call reverts inside the Intake's try.
        assertFalse(intake.complete(id, hex"deadbeef"));
        assertEq(uint8(_status(id)), uint8(HookJobRequester.JobStatus.Open));
        vm.prank(creator);
        vm.expectRevert(
            abi.encodeWithSelector(HookJobRequester.DeadlineNotReached.selector, uint64(block.timestamp + 7 days))
        );
        requester.expireJob(id);
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(stranger);
        vm.expectRevert(HookJobRequester.NotRequester.selector);
        requester.expireJob(id);
        vm.prank(creator);
        requester.expireJob(id);
        assertEq(uint8(_status(id)), uint8(HookJobRequester.JobStatus.Expired));
        vm.prank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.UnknownOrSettled.selector, id));
        requester.onJobResult(id, "too late");
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.UnknownOrSettled.selector, id));
        requester.expireJob(id);
    }

    function testCallbacksFitTheIntakeStipend() public {
        bytes32 id = _open();
        assertTrue(intake.complete(id, abi.encode(id, new bytes(1024))));
        bytes32 id2 = _open();
        assertTrue(intake.fail(id2, 2, "disagreed", 3, 7));
    }

    // ---------------------------------------------------------------- review verdict

    function testReviewPassedOnlyFromSignedOracleAnswer() public {
        (bytes32 jobId, bytes32 oracleId) = _reviewPending();
        assertEq(uint8(_review(jobId)), uint8(HookJobRequester.ReviewStatus.Pending));
        assertEq(requester.reviewOf(oracleId), jobId);
        bytes memory body = intake.bodyOf(oracleId);
        assertEq(body, bytes.concat(ImdTemplates.REVIEW_PREFIX, bytes(vm.toString(jobId)), ImdTemplates.REVIEW_SUFFIX));
        assertEq(imd.balanceOf(address(intake)), 2 * PRICE);

        OracleAttestation.Attestation memory a = _attestation(true);
        bytes memory sig = _sign(a, signerKey);
        uint256 before = gasleft();
        assertTrue(intake.complete(oracleId, abi.encode(oracleId, a, sig)), "fits 200k stipend");
        assertLt(before - gasleft(), 260_000);
        HookJobRequester.Job memory job = requester.getJob(jobId);
        assertEq(uint8(job.review), uint8(HookJobRequester.ReviewStatus.Passed));
        assertEq(job.reviewPanelSize, 7);
        assertEq(job.reviewAgreed, 6);
        assertEq(job.reviewPanelJobId, keccak256("panel job"));
        assertEq(requester.reviewOf(oracleId), bytes32(0));
        assertTrue(requester.consumed(a.requestId));
        // Replay of the same answer for the same ask is refused.
        vm.prank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.UnknownOrSettled.selector, oracleId));
        requester.onReviewResult(oracleId, a, sig);
        // A settled verdict cannot be re-asked.
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.NotReviewable.selector, jobId));
        requester.requestReview(jobId);
    }

    function testReviewNotPassedIsStoredNotReverted() public {
        (bytes32 jobId, bytes32 oracleId) = _reviewPending();
        OracleAttestation.Attestation memory a = _attestation(false);
        assertTrue(intake.complete(oracleId, abi.encode(oracleId, a, _sign(a, signerKey))));
        assertEq(uint8(_review(jobId)), uint8(HookJobRequester.ReviewStatus.NotPassed));
    }

    function testSameAttestationCannotSettleASecondAsk() public {
        (bytes32 jobId, bytes32 oracleId) = _reviewPending();
        OracleAttestation.Attestation memory a = _attestation(true);
        bytes memory sig = _sign(a, signerKey);
        assertTrue(intake.fail(oracleId, 2, "disagreed", 2, 7));
        vm.prank(creator);
        bytes32 second = requester.requestReview(jobId);
        // Consumed once on a different ask first.
        bytes32 otherJob = _delivered();
        vm.prank(creator);
        bytes32 third = requester.requestReview(otherJob);
        assertTrue(intake.complete(third, abi.encode(third, a, sig)));
        vm.prank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(OracleAttestationConsumer.AlreadyConsumed.selector, a.requestId));
        requester.onReviewResult(second, a, sig);
        assertEq(uint8(_review(jobId)), uint8(HookJobRequester.ReviewStatus.Pending));
    }

    function testForgedExpiredWeakOrMistypedAnswersRefused() public {
        (bytes32 jobId, bytes32 oracleId) = _reviewPending();
        OracleAttestation.Attestation memory a = _attestation(true);
        bytes memory sig = _sign(a, signerKey);
        vm.startPrank(stranger);
        vm.expectRevert(HookJobRequester.NotTheIntake.selector);
        requester.onReviewResult(oracleId, a, sig);
        vm.stopPrank();

        vm.startPrank(address(intake));
        // Wrong key.
        bytes memory wrongKey = _sign(a, signerKey + 1);
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        requester.onReviewResult(oracleId, a, wrongKey);
        // Tampered answer under a valid signature.
        OracleAttestation.Attestation memory t = _attestation(false);
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        requester.onReviewResult(oracleId, t, sig);
        // Weak panel, signed.
        OracleAttestation.Attestation memory w = _attestation(true);
        w.panelSize = 3;
        w.quorum = 2;
        w.agreed = 3;
        bytes memory wsig = _sign(w, signerKey);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.PanelTooWeak.selector, uint16(3), uint16(2), uint16(3)));
        requester.onReviewResult(oracleId, w, wsig);
        // Agreement below quorum, signed.
        w = _attestation(true);
        w.agreed = 4;
        w.quorum = 5;
        wsig = _sign(w, signerKey);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.PanelTooWeak.selector, uint16(7), uint16(5), uint16(4)));
        requester.onReviewResult(oracleId, w, wsig);
        // Not a bool.
        w = _attestation(true);
        w.answerType = OracleAttestation.ANSWER_UINT256;
        wsig = _sign(w, signerKey);
        vm.expectRevert(
            abi.encodeWithSelector(
                OracleAttestationConsumer.WrongAnswerType.selector,
                OracleAttestation.ANSWER_BOOL,
                OracleAttestation.ANSWER_UINT256
            )
        );
        requester.onReviewResult(oracleId, w, wsig);
        vm.stopPrank();
        // Expired.
        vm.warp(a.expiresAt + 1);
        vm.prank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(OracleAttestationConsumer.AttestationExpired.selector, a.expiresAt));
        requester.onReviewResult(oracleId, a, sig);
        assertEq(uint8(_review(jobId)), uint8(HookJobRequester.ReviewStatus.Pending));
        assertEq(requester.reviewOf(oracleId), jobId);
    }

    function testAnswerSignedForAnotherConsumerRefused() public {
        (, bytes32 oracleId) = _reviewPending();
        HookJobRequester other = new HookJobRequester(owner, address(intake), address(imd), signer);
        OracleAttestation.Attestation memory a = _attestation(true);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, other.attestationDigest(a));
        vm.prank(address(intake));
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        requester.onReviewResult(oracleId, a, abi.encodePacked(r, s, v));
    }

    function testReviewFailureLeavesNoVerdictAndAllowsRetry() public {
        (bytes32 jobId, bytes32 oracleId) = _reviewPending();
        assertTrue(intake.fail(oracleId, 2, "disagreed", 3, 7));
        assertEq(uint8(_review(jobId)), uint8(HookJobRequester.ReviewStatus.Unanswered));
        vm.prank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.UnknownOrSettled.selector, oracleId));
        requester.onReviewFailure(oracleId, 2, "disagreed", 3, 7, "");
        vm.prank(creator);
        bytes32 retry = requester.requestReview(jobId);
        assertNotEq(retry, oracleId);
        OracleAttestation.Attestation memory a = _attestation(true);
        bytes memory sig = _sign(a, signerKey);
        // The old ask's id no longer settles anything.
        vm.prank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.UnknownOrSettled.selector, oracleId));
        requester.onReviewResult(oracleId, a, sig);
        assertTrue(intake.complete(retry, abi.encode(retry, a, sig)));
        assertEq(uint8(_review(jobId)), uint8(HookJobRequester.ReviewStatus.Passed));
    }

    function testReviewExpiryByRequesterOnly() public {
        (bytes32 jobId, bytes32 oracleId) = _reviewPending();
        vm.prank(creator);
        vm.expectRevert(
            abi.encodeWithSelector(HookJobRequester.DeadlineNotReached.selector, uint64(block.timestamp + 1 days))
        );
        requester.expireReview(jobId);
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(stranger);
        vm.expectRevert(HookJobRequester.NotRequester.selector);
        requester.expireReview(jobId);
        vm.prank(creator);
        requester.expireReview(jobId);
        assertEq(uint8(_review(jobId)), uint8(HookJobRequester.ReviewStatus.Unanswered));
        OracleAttestation.Attestation memory a = _attestation(true);
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp + 1 hours);
        bytes memory sig = _sign(a, signerKey);
        assertFalse(intake.complete(oracleId, abi.encode(oracleId, a, sig)), "late answer refused");
    }

    function testReviewOnlyForDeliveredOrExpiredJobsByRequester() public {
        bytes32 id = _open();
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.NotReviewable.selector, id));
        requester.requestReview(id);
        vm.prank(stranger);
        vm.expectRevert(HookJobRequester.NotRequester.selector);
        requester.requestReview(id);
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(creator);
        requester.expireJob(id);
        // A lost completion notice does not block a verdict.
        vm.prank(creator);
        bytes32 oracleId = requester.requestReview(id);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.NotReviewable.selector, id));
        requester.requestReview(id);
        OracleAttestation.Attestation memory a = _attestation(false);
        assertTrue(intake.complete(oracleId, abi.encode(oracleId, a, _sign(a, signerKey))));
        assertEq(uint8(_review(id)), uint8(HookJobRequester.ReviewStatus.NotPassed));
    }

    function testSignerRotationTakesEffect() public {
        (, bytes32 oracleId) = _reviewPending();
        uint256 newKey = uint256(keccak256("rotated local key"));
        vm.prank(owner);
        requester.setOracleSigner(vm.addr(newKey));
        OracleAttestation.Attestation memory a = _attestation(true);
        bytes memory oldSig = _sign(a, signerKey);
        vm.prank(address(intake));
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        requester.onReviewResult(oracleId, a, oldSig);
        assertTrue(intake.complete(oracleId, abi.encode(oracleId, a, _sign(a, newKey))));
    }

    /// @dev site/index.html hard-codes this selector and decodes the reply as 15 static words.
    function testStaticSiteReadContract() public {
        bytes32 id = _delivered();
        assertEq(HookJobRequester.getJob.selector, bytes4(0xf729cf0d));
        (bool ok, bytes memory ret) = address(requester).staticcall(abi.encodePacked(bytes4(0xf729cf0d), id));
        assertTrue(ok);
        assertEq(ret.length, 15 * 32);
        assertEq(address(uint160(uint256(bytes32(ret)))), creator);
        uint256 status;
        assembly {
            status := mload(add(ret, 0x80))
        }
        assertEq(status, uint256(HookJobRequester.JobStatus.Delivered));
    }

    function testSweepRecoversStrayTokens() public {
        imd.mint(address(requester), 3);
        vm.prank(owner);
        requester.sweep(address(imd), owner, 3);
        assertEq(imd.balanceOf(owner), 3);
    }
}
