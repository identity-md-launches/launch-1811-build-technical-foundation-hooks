// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {TestToken} from "./helpers/TestToken.sol";
import {MockIntake} from "./helpers/MockIntake.sol";
import {HookJobRequester} from "../src/imd/HookJobRequester.sol";
import {OracleAttestation, OracleAttestationConsumer} from "../src/imd/OracleAttestation.sol";
import {StoreAdmin} from "../src/store/StoreAdmin.sol";
import {ImdTemplates} from "./helpers/ImdTemplates.sol";

abstract contract HookJobRequesterFixture is Test {
    bytes32 internal constant JOB_ACTION = "job.open@test";
    bytes32 internal constant ORACLE_ACTION = "oracle.request@oracle-1";
    uint256 internal constant PRICE = 0.5 ether;
    bytes32 internal constant SPEC_HASH = keccak256("hook spec");
    bytes32 internal constant RESULT_HASH = keccak256("result document");

    TestToken internal imd;
    MockIntake internal intake;
    HookJobRequester internal requester;
    address internal owner = makeAddr("owner");
    address internal creator = makeAddr("creator");
    address internal stranger = makeAddr("stranger");
    uint256 internal signerKey = uint256(keccak256("local test oracle key"));
    address internal signer;

    function setUp() public virtual {
        vm.chainId(31337);
        vm.warp(1_800_000_000);
        signer = vm.addr(signerKey);
        imd = new TestToken("IMD", 18);
        intake = new MockIntake();
        intake.setPrice(JOB_ACTION, address(imd), PRICE);
        intake.setPrice(ORACLE_ACTION, address(imd), PRICE);
        requester = new HookJobRequester(owner, address(intake), address(imd), signer, PRICE);
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
        id = requester.openJob(SPEC_HASH, "A swap cap hook for my USDC/WETH pool", 0.5 ether);
    }

    function _delivered() internal returns (bytes32 id) {
        id = _open();
        assertTrue(intake.complete(id, abi.encode(id, RESULT_HASH, "ipfs://result")));
    }

    function _reviewPending() internal returns (bytes32 jobId, bytes32 oracleId) {
        jobId = _delivered();
        oracleId = _requestReview(jobId);
    }

    function _attestation(bytes32 intakeId, bool passed)
        internal
        view
        returns (OracleAttestation.Attestation memory a)
    {
        a = OracleAttestation.Attestation({
            requestId: bytes32(bytes16(keccak256(abi.encode("mock oracle UUID", intakeId)))),
            chainId: 31337,
            // Local fixture only: NOT the protocol canonical hash algorithm.
            questionHash: keccak256(abi.encode("mock canonical question", intake.bodyOf(intakeId))),
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

    function _requestReview(bytes32 jobId) internal returns (bytes32 intakeId) {
        vm.prank(creator);
        intakeId = requester.requestReview(jobId, 0.5 ether);
        _bind(intakeId);
    }

    function _confirmExpiry(bytes32 intakeId) internal {
        vm.prank(owner);
        requester.confirmReviewExpiry(intakeId);
    }

    function _bind(bytes32 intakeId) internal {
        OracleAttestation.Attestation memory a = _attestation(intakeId, true);
        bytes32 bodyHash = keccak256(intake.bodyOf(intakeId));
        vm.prank(owner);
        requester.bindReview(intakeId, bodyHash, a.requestId, a.questionHash, a.chainId, a.fromBlock, a.toBlock);
    }
}

contract HookJobRequesterTest is HookJobRequesterFixture {
    // ---------------------------------------------------------------- configuration

    function testUnconfiguredRequesterRefusesUntilOwnerSetsTemplates() public {
        HookJobRequester fresh = new HookJobRequester(owner, address(intake), address(imd), signer, PRICE);
        vm.prank(creator);
        imd.approve(address(fresh), type(uint256).max);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.NotConfigured.selector, bytes32("jobTemplate")));
        fresh.openJob(SPEC_HASH, "brief", 0.5 ether);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.NotConfigured.selector, bytes32("reviewTemplate")));
        fresh.requestReview(bytes32(uint256(1)), 0.5 ether);
        vm.prank(owner);
        fresh.setJobTemplate(JOB_ACTION, ImdTemplates.JOB_PREFIX, ImdTemplates.JOB_MIDDLE, ImdTemplates.JOB_SUFFIX);
        vm.prank(creator);
        bytes32 id = fresh.openJob(SPEC_HASH, "brief", 0.5 ether);
        assertEq(uint8(fresh.getJob(id).status), uint8(HookJobRequester.JobStatus.Open));
    }

    function testConstructorRefusesZeroAddresses() public {
        vm.expectRevert(StoreAdmin.InvalidAddress.selector);
        new HookJobRequester(address(0), address(intake), address(imd), signer, PRICE);
        vm.expectRevert(HookJobRequester.ZeroAddress.selector);
        new HookJobRequester(owner, address(0), address(imd), signer, PRICE);
        vm.expectRevert(HookJobRequester.ZeroAddress.selector);
        new HookJobRequester(owner, address(intake), address(0), signer, PRICE);
        vm.expectRevert(OracleAttestationConsumer.ZeroSigner.selector);
        new HookJobRequester(owner, address(intake), address(imd), address(0), PRICE);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.PriceAboveCeiling.selector, uint256(0), uint256(0)));
        new HookJobRequester(owner, address(intake), address(imd), signer, 0);
    }

    function testPriceCeilingProtectsStandingAllowance() public {
        // The creator gave an unlimited allowance in setUp. A price move above the ceiling is refused.
        intake.setPrice(JOB_ACTION, address(imd), PRICE + 1);
        uint256 before = imd.balanceOf(creator);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.PriceAboveCeiling.selector, PRICE + 1, PRICE));
        requester.openJob(SPEC_HASH, "brief", 0.5 ether);
        assertEq(imd.balanceOf(creator), before, "nothing pulled");
        // A lower price is pulled as is, never the ceiling.
        intake.setPrice(JOB_ACTION, address(imd), PRICE / 2);
        _open();
        assertEq(imd.balanceOf(creator), before - PRICE / 2);
        // The owner raises the ceiling with the asset, and the higher price goes through.
        intake.setPrice(JOB_ACTION, address(imd), PRICE + 1);
        vm.prank(owner);
        vm.expectEmit(true, false, false, true, address(requester));
        emit HookJobRequester.PaymentSet(address(imd), PRICE + 1);
        requester.setPayment(address(imd), PRICE + 1);
        vm.prank(creator);
        requester.openJob(SPEC_HASH, "brief", PRICE + 1);
        assertEq(imd.balanceOf(creator), before - PRICE / 2 - PRICE - 1);
        // The review ask is under the same ceiling.
        intake.setPrice(ORACLE_ACTION, address(imd), 2 * PRICE);
        intake.setPrice(JOB_ACTION, address(imd), PRICE);
        bytes32 id = _delivered();
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.PriceAboveCeiling.selector, 2 * PRICE, PRICE + 1));
        requester.requestReview(id, 0.5 ether);
    }

    function testVersion1IntakeWorksWithTheFailureHookOff() public {
        intake.setV1(true);
        vm.prank(owner);
        vm.expectEmit(false, false, false, true, address(requester));
        emit HookJobRequester.FailureHookSet(false);
        requester.setFailureHook(false);
        assertFalse(requester.failureHook());
        bytes32 id = _open();
        (,,, address target, bytes4 selector, bytes4 onFailure,) = intake.reqs(id);
        assertEq(target, address(requester));
        assertEq(selector, HookJobRequester.onJobResult.selector);
        assertEq(onFailure, bytes4(0), "no failure function named on a version 1 ask");
        assertEq(imd.allowance(address(requester), address(intake)), 0);
        // A refused ask never reaches the contract: the version 1 intake has no failure call.
        vm.expectRevert("not pending");
        intake.fail(id, 1, "body_invalid", 0, 0);
        // The requester still has the deadline path.
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(creator);
        requester.expireJob(id);
        assertEq(uint8(_status(id)), uint8(HookJobRequester.JobStatus.Expired));
        // And a completion for a version 1 ask is accepted the same way.
        bytes32 id2 = _open();
        assertTrue(intake.complete(id2, abi.encode(id2, RESULT_HASH, "ipfs://result")));
        assertEq(uint8(_status(id2)), uint8(HookJobRequester.JobStatus.Delivered));
        // The review ask on a version 1 intake is a plain request too.
        vm.prank(creator);
        bytes32 oracleId = requester.requestReview(id2, 0.5 ether);
        (,,,,, bytes4 reviewFailure,) = intake.reqs(oracleId);
        assertEq(reviewFailure, bytes4(0));
        // Back on, the version 1 intake refuses the whole call and nothing is spent.
        vm.prank(owner);
        requester.setFailureHook(true);
        uint256 before = imd.balanceOf(creator);
        vm.prank(creator);
        vm.expectRevert("v1 has no requestWithFailure");
        requester.openJob(SPEC_HASH, "brief", 0.5 ether);
        assertEq(imd.balanceOf(creator), before);
    }

    function testJobIdCollidingWithPendingReviewAskRefused() public {
        (, bytes32 oracleId) = _reviewPending();
        intake.setReuseIds(true);
        assertEq(intake.lastRequestId(), oracleId);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.DuplicateRequestId.selector, oracleId));
        requester.openJob(SPEC_HASH, "would share the review ask's id", 0.5 ether);
    }

    function testOwnerSettersAreOwnerOnlyAndValidated() public {
        vm.startPrank(stranger);
        vm.expectRevert(StoreAdmin.NotOwner.selector);
        requester.setIntake(stranger);
        vm.expectRevert(StoreAdmin.NotOwner.selector);
        requester.setPayment(stranger, 1);
        vm.expectRevert(StoreAdmin.NotOwner.selector);
        requester.setFailureHook(false);
        vm.expectRevert(StoreAdmin.NotOwner.selector);
        requester.setOracleSigner(stranger);
        vm.expectRevert(StoreAdmin.NotOwner.selector);
        requester.setJobTemplate(JOB_ACTION, "", "", "");
        vm.expectRevert(StoreAdmin.NotOwner.selector);
        requester.setReviewTemplate(ORACLE_ACTION, "", "", 5, 4);
        vm.expectRevert(StoreAdmin.NotOwner.selector);
        requester.setTimeouts(1 days, 1 days);
        vm.expectRevert(StoreAdmin.NotOwner.selector);
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
        vm.expectRevert(HookJobRequester.ZeroAddress.selector);
        requester.setPayment(address(0), 1);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.PriceAboveCeiling.selector, uint256(0), uint256(0)));
        requester.setPayment(address(imd), 0);
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
        requester.openJob(SPEC_HASH, "brief", 0.5 ether);
        address poor = makeAddr("poor");
        vm.prank(poor);
        imd.approve(address(requester), PRICE);
        vm.prank(poor);
        vm.expectRevert(HookJobRequester.TokenCallFailed.selector);
        requester.openJob(SPEC_HASH, "brief", 0.5 ether);
        assertEq(requester.jobCount(), 0);
    }

    function testUnpricedActionAndVersion1IntakeRefusedWithoutPayment() public {
        intake.setPrice(JOB_ACTION, address(imd), 0);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.ActionNotPriced.selector, JOB_ACTION));
        requester.openJob(SPEC_HASH, "brief", 0.5 ether);
        intake.setPrice(JOB_ACTION, address(imd), PRICE);
        intake.setV1(true);
        uint256 before = imd.balanceOf(creator);
        vm.prank(creator);
        vm.expectRevert("v1 has no requestWithFailure");
        requester.openJob(SPEC_HASH, "brief", 0.5 ether);
        assertEq(imd.balanceOf(creator), before, "whole call reverted, nothing spent");
    }

    function testReusedRequestIdRefused() public {
        _open();
        intake.setReuseIds(true);
        bytes32 id = intake.lastRequestId();
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.DuplicateRequestId.selector, id));
        requester.openJob(SPEC_HASH, "again", 0.5 ether);
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
            requester.openJob(SPEC_HASH, bad[i], 0.5 ether);
        }
        bytes memory tooLong = new bytes(2001);
        for (uint256 i; i < tooLong.length; ++i) {
            tooLong[i] = "a";
        }
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.BriefLength.selector, uint256(2001)));
        requester.openJob(SPEC_HASH, tooLong, 0.5 ether);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.InvalidBrief.selector, uint256(4)));
        requester.openJob(SPEC_HASH, 'abcd"', 0.5 ether);
        // Multi-byte UTF-8 (é, €, 😀) and ordinary punctuation are fine.
        vm.prank(creator);
        requester.openJob(SPEC_HASH, hex"c3a920e282ac20f09f98802c2e3a2f", 0.5 ether);
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
        requester.openJob(SPEC_HASH, brief, 0.5 ether);
    }

    // ---------------------------------------------------------------- result / failure

    function testResultAcceptedOnceFromIntakeOnly() public {
        bytes32 id = _open();
        vm.prank(stranger);
        vm.expectRevert(HookJobRequester.NotTheIntake.selector);
        requester.onJobResult(id, keccak256("forged"), "ipfs://result");
        assertTrue(intake.complete(id, abi.encode(id, RESULT_HASH, "ipfs://result")));
        HookJobRequester.Job memory job = requester.getJob(id);
        assertEq(uint8(job.status), uint8(HookJobRequester.JobStatus.Delivered));
        assertEq(job.resultHash, RESULT_HASH);
        assertEq(uint8(job.review), uint8(HookJobRequester.ReviewStatus.None), "delivery is not a review verdict");
        // Replays from the Intake itself, of either callback, are refused.
        vm.startPrank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.UnknownOrSettled.selector, id));
        requester.onJobResult(id, keccak256("again"), "ipfs://result");
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.UnknownOrSettled.selector, id));
        requester.onJobFailure(id, 2, "disagreed", 0, 0, "");
        vm.stopPrank();
        assertEq(requester.getJob(id).resultHash, RESULT_HASH);
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
        requester.onJobResult(id, keccak256("late"), "ipfs://result");
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.UnknownOrSettled.selector, id));
        requester.onJobFailure(id, 2, "disagreed", 0, 0, "");
        vm.stopPrank();
        vm.prank(creator);
        requester.requestReview(id, PRICE);
        assertEq(uint8(_review(id)), uint8(HookJobRequester.ReviewStatus.Pending));
    }

    function testUnknownRequestIdRefused() public {
        bytes32 unknown = keccak256("someone else's request naming this contract");
        vm.startPrank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.UnknownOrSettled.selector, unknown));
        requester.onJobResult(unknown, RESULT_HASH, "");
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.UnknownOrSettled.selector, unknown));
        requester.onJobFailure(unknown, 2, "disagreed", 0, 0, "");
        OracleAttestation.Attestation memory a = _attestation(unknown, true);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.UnknownOrSettled.selector, unknown));
        requester.onReviewResult(unknown, a, "");
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.UnknownOrSettled.selector, unknown));
        requester.onReviewFailure(unknown, 2, "disagreed", 0, 0, "");
        vm.stopPrank();
    }

    function testCallbackWithUnexpectedAbiFailsSafeAndJobCanExpire() public {
        bytes32 id = _open();
        // Malformed tuple data reverts inside the Intake's one-shot call.
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
        requester.onJobResult(id, keccak256("late authenticated result"), "ipfs://result");
        assertEq(uint8(_status(id)), uint8(HookJobRequester.JobStatus.Delivered));
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.UnknownOrSettled.selector, id));
        requester.expireJob(id);
    }

    function testCallbacksFitTheIntakeStipend() public {
        bytes32 id = _open();
        assertTrue(intake.complete(id, abi.encode(id, RESULT_HASH, string(new bytes(1024)))));
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

        OracleAttestation.Attestation memory a = _attestation(oracleId, true);
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
        requester.requestReview(jobId, 0.5 ether);
    }

    function testReviewNotPassedIsStoredNotReverted() public {
        (bytes32 jobId, bytes32 oracleId) = _reviewPending();
        OracleAttestation.Attestation memory a = _attestation(oracleId, false);
        assertTrue(intake.complete(oracleId, abi.encode(oracleId, a, _sign(a, signerKey))));
        assertEq(uint8(_review(jobId)), uint8(HookJobRequester.ReviewStatus.NotPassed));
    }

    function testSameAttestationCannotSettleASecondAsk() public {
        (, bytes32 oracleId) = _reviewPending();
        OracleAttestation.Attestation memory a = _attestation(oracleId, true);
        bytes memory sig = _sign(a, signerKey);
        assertTrue(intake.complete(oracleId, abi.encode(oracleId, a, sig)));
        (bytes32 otherJob, bytes32 otherAsk) = _reviewPending();
        vm.prank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(OracleAttestationConsumer.AlreadyConsumed.selector, a.requestId));
        requester.onReviewResult(otherAsk, a, sig);
        assertEq(uint8(_review(otherJob)), uint8(HookJobRequester.ReviewStatus.Pending));
        assertEq(requester.reviewOf(otherAsk), otherJob);
    }

    function testForgedExpiredWeakOrMistypedAnswersRefused() public {
        (bytes32 jobId, bytes32 oracleId) = _reviewPending();
        OracleAttestation.Attestation memory a = _attestation(oracleId, true);
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
        OracleAttestation.Attestation memory t = _attestation(oracleId, false);
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        requester.onReviewResult(oracleId, t, sig);
        // Weak panel, signed.
        OracleAttestation.Attestation memory w = _attestation(oracleId, true);
        w.panelSize = 3;
        w.quorum = 2;
        w.agreed = 3;
        bytes memory wsig = _sign(w, signerKey);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.PanelTooWeak.selector, uint16(3), uint16(2), uint16(3)));
        requester.onReviewResult(oracleId, w, wsig);
        // Agreement below quorum, signed.
        w = _attestation(oracleId, true);
        w.agreed = 4;
        w.quorum = 5;
        wsig = _sign(w, signerKey);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.PanelTooWeak.selector, uint16(7), uint16(5), uint16(4)));
        requester.onReviewResult(oracleId, w, wsig);
        // Not a bool.
        w = _attestation(oracleId, true);
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
        HookJobRequester other = new HookJobRequester(owner, address(intake), address(imd), signer, PRICE);
        OracleAttestation.Attestation memory a = _attestation(oracleId, true);
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
        bytes32 retry = _requestReview(jobId);
        assertNotEq(retry, oracleId);
        OracleAttestation.Attestation memory a = _attestation(retry, true);
        bytes memory sig = _sign(a, signerKey);
        // The old ask's id no longer settles anything.
        vm.prank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.UnknownOrSettled.selector, oracleId));
        requester.onReviewResult(oracleId, a, sig);
        assertTrue(intake.complete(retry, abi.encode(retry, a, sig)));
        assertEq(uint8(_review(jobId)), uint8(HookJobRequester.ReviewStatus.Passed));
    }

    function testReviewExpiryRequestedByRequesterAndConfirmedByOwner() public {
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
        assertEq(uint8(_review(jobId)), uint8(HookJobRequester.ReviewStatus.Pending));
        _confirmExpiry(oracleId);
        assertEq(uint8(_review(jobId)), uint8(HookJobRequester.ReviewStatus.Unanswered));
        OracleAttestation.Attestation memory a = _attestation(oracleId, true);
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp + 1 hours);
        bytes memory sig = _sign(a, signerKey);
        assertFalse(intake.complete(oracleId, abi.encode(oracleId, a, sig)), "late answer refused");
    }

    function testReviewOnlyForDeliveredOrExpiredJobsByRequester() public {
        bytes32 id = _open();
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.NotReviewable.selector, id));
        requester.requestReview(id, 0.5 ether);
        vm.prank(stranger);
        vm.expectRevert(HookJobRequester.NotRequester.selector);
        requester.requestReview(id, 0.5 ether);
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(creator);
        requester.expireJob(id);
        // A lost completion notice does not block a verdict.
        bytes32 oracleId = _requestReview(id);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(HookJobRequester.NotReviewable.selector, id));
        requester.requestReview(id, 0.5 ether);
        OracleAttestation.Attestation memory a = _attestation(oracleId, false);
        assertTrue(intake.complete(oracleId, abi.encode(oracleId, a, _sign(a, signerKey))));
        assertEq(uint8(_review(id)), uint8(HookJobRequester.ReviewStatus.NotPassed));
    }

    function testSignerRotationTakesEffect() public {
        (, bytes32 oracleId) = _reviewPending();
        uint256 newKey = uint256(keccak256("rotated local key"));
        vm.prank(owner);
        requester.setOracleSigner(vm.addr(newKey));
        OracleAttestation.Attestation memory a = _attestation(oracleId, true);
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
        // The page lists a wallet's jobs with jobsOf(address) and reads the history from these events.
        assertEq(HookJobRequester.jobsOf.selector, bytes4(0x6373d2ea));
        (ok, ret) = address(requester).staticcall(abi.encodePacked(bytes4(0x6373d2ea), uint256(uint160(creator))));
        assertTrue(ok);
        bytes32[] memory ids = abi.decode(ret, (bytes32[]));
        assertEq(ids.length, 1);
        assertEq(ids[0], id);
        // Event topics the page filters eth_getLogs with; the job id is always topic 1.
        assertEq(
            HookJobRequester.ReviewExpiryRequested.selector,
            0xa7024fcc5fd62012d81f0e16c29223c201804a965e2bdb516254ed5a4b138d2a
        );
        assertEq(
            HookJobRequester.JobOpened.selector, 0x95e6cf60266f65ecf4a509b236fccd720bc64ef7099f4a859a49d18cab89334c
        );
        assertEq(
            HookJobRequester.JobDelivered.selector, 0xcf3572188b51dfe2ff3d594bd6f949f6d927563dccd01a16ed91de08773031f3
        );
        assertEq(
            HookJobRequester.JobResultURI.selector, 0xb7024b3387ec94e50f20e6f13d42c52ecb72ae8b532d7c595b5a094954a78e0b
        );
        assertEq(
            HookJobRequester.JobFailed.selector, 0x109fbcdb2357a12dbc99347a26add088ce1785932ff8fd91290dd66e482e3f52
        );
        assertEq(
            HookJobRequester.JobExpired.selector, 0xc4b18028cd4e987c6f51b76fe353bf20701009babc05208e39e32044646b0557
        );
        assertEq(
            HookJobRequester.ReviewRequested.selector,
            0xcbcbb95076ab2e4932fc45c7613d06ad31955e4c5b283dbac36586c7a37c89a6
        );
        assertEq(
            HookJobRequester.ReviewBound.selector, 0x5d8ee2f21c4a5f065cce0842c0bc1b6cb0838886b1101420cec56054813a4b5e
        );
        assertEq(
            HookJobRequester.ReviewReceived.selector, 0x61d368d8c6034f66f1814ed323248d8afc47b96ca585d93f7d458dd52666f7a3
        );
        assertEq(
            HookJobRequester.ReviewReceiptDiscarded.selector,
            0x7d97b7975a86eb91759cd2a633f4a61154f14e74399974b33e1ce3748e66f887
        );
        assertEq(
            HookJobRequester.ReviewAnswered.selector, 0x80495876c6bc99afc83ec191e4b474b0b92cc26c5d47d78c10c1ec1706f02a5f
        );
        assertEq(
            HookJobRequester.ReviewUnanswered.selector,
            0x3c2152c9ef2bb1c0a603d6af74cce504897849f75c6d98f1f11b23a94d179538
        );
    }

    function testSweepRecoversStrayTokens() public {
        imd.mint(address(requester), 3);
        vm.prank(owner);
        requester.sweep(address(imd), owner, 3);
        assertEq(imd.balanceOf(owner), 3);
    }
}
