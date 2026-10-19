// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AutomaticFixture, AutomaticGasTest} from "./AutomaticBinding.t.sol";
import {AutoHookJobRequester} from "../src/imd/automatic/AutoHookJobRequester.sol";
import {HookJobRequester} from "../src/imd/HookJobRequester.sol";
import {OracleAttestation} from "../src/imd/OracleAttestation.sol";
import {OracleQuestion} from "./helpers/OracleQuestion.sol";
import {HookRequestCodec} from "../src/imd/automatic/HookRequestCodec.sol";

/// @dev Distinct clocks are deliberate: vm.roll models the EVM's L1 height on Robinhood,
/// while this system-contract mock supplies the question chain's native L2 height.
contract WindowArbSysMock {
    uint256 public arbBlockNumber;

    function setHead(uint256 value) external {
        arbBlockNumber = value;
    }
}

contract OracleWindowRegressionTest is AutomaticFixture {
    function _prepared() internal {
        (jobId, askId) = _open();
        _deliver(jobId);
        _commit(jobId, _artifact(jobId));
    }

    function _reserveIntact() internal view {
        assertEq(imd.balanceOf(address(intake)), FEE, "only the build fee may be spent");
        assertEq(imd.balanceOf(address(automatic)), FEE);
        assertEq(automatic.reserved(address(imd)), FEE);
        (, uint256 amount,) = automatic.reserveOf(jobId);
        assertEq(amount, FEE);
        assertEq(automatic.getAsk(askId).intakeId, bytes32(0));
        assertEq(automatic.getAsk(askId).pin, address(0));
        assertEq(uint8(_review(jobId)), uint8(HookJobRequester.ReviewStatus.None));
        assertEq(imd.allowance(address(automatic), address(intake)), 0);
    }

    function testEarlyPermissionlessCallsCannotSpendReserve() public {
        _prepared();
        for (uint256 elapsed; elapsed < 8; ++elapsed) {
            vm.roll(1000 + elapsed);
            vm.prank(outsider);
            vm.expectRevert(AutoHookJobRequester.NotReady.selector);
            automatic.requestVerdict(askId);
            _reserveIntact();
        }
        vm.roll(1008);
        vm.prank(outsider);
        verdictId = automatic.requestVerdict(askId);
        assertEq(automatic.getAsk(askId).fromBlock, 1000);
        assertEq(automatic.getAsk(askId).toBlock, 1000);
        _answer(true);
    }

    function testEarliestIntakeAdmissionAlreadyHasFiveBlocksDepth() public {
        _prepared();
        vm.roll(1020);
        verdictId = automatic.requestVerdict(askId);
        AutoHookJobRequester.Ask memory a = automatic.getAsk(askId);
        // Even if read immediately it is deep enough. Ethereum Intake waits only three
        // confirmations (inclusion counts as one), so its earliest read can be head + 2.
        assertGe(1020 - a.toBlock, 5, "too shallow at trigger");
        assertGe(1022 - a.toBlock, 5, "too shallow at earliest Intake admission");
        assertEq(a.toBlock, 1012);
        // Fixed window intentionally ends before the oracle trigger; issuance does not.
        _answer(true);
    }

    function testRobinhoodUsesNativeClockForWindowAndCallback() public {
        vm.chainId(4663);
        spec.chainId = 4663;
        vm.etch(address(100), type(WindowArbSysMock).runtimeCode);
        WindowArbSysMock arb = WindowArbSysMock(address(100));
        arb.setHead(900_000);
        (jobId, askId) = _open();
        arb.setHead(900_010);
        _deliver(jobId);
        arb.setHead(900_020);
        _commit(jobId, _artifact(jobId));
        arb.setHead(900_028);
        vm.roll(1001);
        verdictId = automatic.requestVerdict(askId);
        assertEq(automatic.getAsk(askId).fromBlock, 900_020, "mixed L1/L2 start");
        assertEq(automatic.getAsk(askId).toBlock, 900_020, "mixed L1/L2 close");
        _answer(true);
    }

    function testUnsupportedClockFailsBeforeBuildPayment() public {
        vm.chainId(999_001);
        spec.chainId = block.chainid;
        vm.prank(creator);
        vm.expectRevert();
        automatic.openJob(spec, address(gated), "A bounded swap hook", FEE, FEE);
        assertEq(imd.balanceOf(creator), 100 ether);
        assertEq(imd.balanceOf(address(intake)), 0);
        assertEq(automatic.reserved(address(imd)), 0);
    }

    function testMissingRobinhoodSystemClockFailsBeforeBuildPayment() public {
        vm.chainId(4663);
        spec.chainId = 4663;
        vm.prank(creator);
        vm.expectRevert();
        automatic.openJob(spec, address(gated), "A bounded swap hook", FEE, FEE);
        assertEq(imd.balanceOf(creator), 100 ether);
        assertEq(imd.balanceOf(address(intake)), 0);
    }

    function testRetryMustMatureItsOwnWindowBeforeSpending() public {
        _ready();
        assertTrue(intake.fail(verdictId, 2, "disagreed", 2, 7));
        vm.prank(creator);
        bytes32 retry = automatic.retryVerdict(jobId, FEE);
        for (uint256 elapsed; elapsed < 8; ++elapsed) {
            vm.roll(1020 + elapsed);
            vm.prank(outsider);
            vm.expectRevert(AutoHookJobRequester.NotReady.selector);
            automatic.requestVerdict(retry);
            assertEq(imd.balanceOf(address(intake)), 2 * FEE);
            assertEq(automatic.reserved(address(imd)), FEE);
        }
        vm.roll(1028);
        bytes32 retriedId = automatic.requestVerdict(retry);
        assertEq(automatic.getAsk(retry).fromBlock, 1020);
        assertEq(automatic.getAsk(retry).toBlock, 1020);
        OracleAttestation.Attestation memory wrong = _att(askId, true);
        bytes memory signature = _sign(wrong);
        vm.prank(address(intake));
        vm.expectRevert(AutoHookJobRequester.WrongQuestion.selector);
        automatic.onReviewResult(retriedId, wrong, signature);
        OracleAttestation.Attestation memory right = _att(retry, true);
        assertTrue(intake.complete(retriedId, abi.encode(retriedId, right, _sign(right))));
        assertEq(automatic.approvedArtifact(jobId), automatic.candidateDigest(jobId));
    }
}

contract OracleWindowPolicyTest is AutomaticFixture {
    function _native(uint256 height) private {
        WindowArbSysMock(address(100)).setHead(height);
    }

    function _robinhood(uint256 height) private {
        vm.chainId(4663);
        spec.chainId = 4663;
        vm.etch(address(100), type(WindowArbSysMock).runtimeCode);
        _native(height);
    }

    function _assertReadiness(bytes32 ask, bool expected, uint64 current, uint64 start, uint64 end) private view {
        (bool ready, uint64 h, uint64 from, uint64 to) = automatic.verdictReadiness(ask);
        assertEq(ready, expected);
        assertEq(h, current);
        assertEq(from, start);
        assertEq(to, end);
    }

    function testNativeClockRecordedAtOpenDeliveryAndCommit() public {
        _robinhood(900_000);
        (jobId, askId) = _open();
        _assertReadiness(askId, false, 900_000, 900_000, 899_992);
        _native(900_010);
        _deliver(jobId);
        _assertReadiness(askId, false, 900_010, 900_010, 900_002);
        _native(900_020);
        _commit(jobId, _artifact(jobId));
        _native(900_027);
        _assertReadiness(askId, false, 900_027, 900_020, 900_019);
        // Advancing only the L1 block height cannot mature an L2 window.
        vm.roll(30_000_000);
        vm.expectRevert(AutoHookJobRequester.NotReady.selector);
        automatic.requestVerdict(askId);
        assertEq(automatic.reserved(address(imd)), FEE);
        _native(900_028);
        _assertReadiness(askId, true, 900_028, 900_020, 900_020);
        verdictId = automatic.requestVerdict(askId);
        _answer(true); // The large L1 height must not make the L2 window stale.
        (jobId, askId) = _open();
        _native(900_030);
        _deliver(jobId);
        _native(900_040);
        _commit(jobId, _artifact(jobId));
        _native(900_047);
        _assertReadiness(askId, false, 900_047, 900_040, 900_039);
        _native(900_048);
        _assertReadiness(askId, true, 900_048, 900_040, 900_040);
        verdictId = automatic.requestVerdict(askId);
        _answer(false);
    }

    function testNativeRetryClockAndWrongOldQuestion() public {
        _robinhood(900_000);
        (jobId, askId) = _open();
        _deliver(jobId);
        _commit(jobId, _artifact(jobId));
        _native(900_008);
        verdictId = automatic.requestVerdict(askId);
        assertTrue(intake.fail(verdictId, 2, "disagreed", 2, 7));
        _native(910_000);
        vm.prank(creator);
        bytes32 retry = automatic.retryVerdict(jobId, FEE);
        _native(910_007);
        vm.roll(30_000_000);
        _assertReadiness(retry, false, 910_007, 910_000, 909_999);
        vm.expectRevert(AutoHookJobRequester.NotReady.selector);
        automatic.requestVerdict(retry);
        assertEq(automatic.reserved(address(imd)), FEE);
        _native(910_008);
        _assertReadiness(retry, true, 910_008, 910_000, 910_000);
        bytes32 id = automatic.requestVerdict(retry);
        OracleAttestation.Attestation memory a = _att(askId, true);
        bytes memory sig = _sign(a);
        vm.prank(address(intake));
        vm.expectRevert(AutoHookJobRequester.WrongQuestion.selector);
        automatic.onReviewResult(id, a, sig);
        a = _att(retry, false);
        assertTrue(intake.complete(id, abi.encode(id, a, _sign(a))));
        vm.prank(creator);
        vm.expectRevert(AutoHookJobRequester.NotReady.selector);
        automatic.retryVerdict(jobId, FEE);
    }

    function testNativeFreshnessBoundaryAndFutureClosingBlock() public {
        _robinhood(900_000);
        (jobId, askId) = _open();
        _deliver(jobId);
        _commit(jobId, _artifact(jobId));
        _native(900_008);
        verdictId = automatic.requestVerdict(askId);
        OracleAttestation.Attestation memory a = _att(askId, true);
        bytes memory sig = _sign(a);
        uint256 snapshot = vm.snapshotState();
        _native(907_201);
        assertFalse(intake.complete(verdictId, abi.encode(verdictId, a, sig)));
        assertFalse(automatic.consumed(a.requestId));
        assertTrue(vm.revertToStateAndDelete(snapshot));
        snapshot = vm.snapshotState();
        _native(900_000); // signed closing block must be strictly behind the native head
        assertFalse(intake.complete(verdictId, abi.encode(verdictId, a, sig)));
        assertTrue(vm.revertToStateAndDelete(snapshot));
        snapshot = vm.snapshotState();
        _native(899_999);
        assertFalse(intake.complete(verdictId, abi.encode(verdictId, a, sig)));
        assertTrue(vm.revertToStateAndDelete(snapshot));
        _native(907_200);
        assertTrue(intake.complete(verdictId, abi.encode(verdictId, a, sig)));
    }

    function testFuzzReadinessExactEightBlockBoundary(uint8 elapsed) public {
        (jobId, askId) = _open();
        vm.roll(1010);
        _deliver(jobId);
        vm.roll(1020);
        _commit(jobId, _artifact(jobId));
        uint256 n = bound(elapsed, 0, 20);
        vm.roll(1020 + n);
        (bool ready,, uint64 from, uint64 to) = automatic.verdictReadiness(askId);
        assertEq(ready, n >= 8);
        assertEq(from, 1020);
        assertEq(to, 1012 + n);
        if (!ready) {
            vm.prank(outsider);
            vm.expectRevert(AutoHookJobRequester.NotReady.selector);
            automatic.requestVerdict(askId);
            assertEq(imd.balanceOf(address(intake)), FEE);
            assertEq(automatic.reserved(address(imd)), FEE);
        } else {
            verdictId = automatic.requestVerdict(askId);
            _answer(true);
        }
    }

    function testSmallNativeHeadDoesNotUnderflowOrSpend() public {
        _robinhood(0);
        (jobId, askId) = _open();
        _deliver(jobId);
        _commit(jobId, _artifact(jobId));
        for (uint256 i; i < 8; ++i) {
            _native(i);
            _assertReadiness(askId, false, uint64(i), 0, 0);
            vm.expectRevert(AutoHookJobRequester.NotReady.selector);
            automatic.requestVerdict(askId);
            assertEq(automatic.reserved(address(imd)), FEE);
        }
        _native(8);
        _assertReadiness(askId, true, 8, 0, 0);
        verdictId = automatic.requestVerdict(askId);
        _answer(true);
    }

    function testClockFailureCannotSpendTriggerOrRetryAndCannotRecordLifecycleHeights() public {
        _robinhood(1000);
        (jobId, askId) = _open();
        _native(1 << 64); // must not truncate to a plausible low block
        artifact = _artifact(jobId);
        vm.prank(creator);
        vm.expectRevert();
        automatic.commitArtifact(jobId, artifact, COMMIT);
        assertEq(automatic.candidateDigest(jobId), bytes32(0));
        assertFalse(intake.complete(jobId, abi.encode(jobId, keccak256("result"), "ipfs://local")));
        assertEq(uint8(automatic.getJob(jobId).status), uint8(HookJobRequester.JobStatus.Open));
        // A fresh job is needed because the mock correctly models one-shot callback loss.
        _native(1010);
        (jobId, askId) = _open();
        _deliver(jobId);
        _native(1 << 64);
        artifact = _artifact(jobId);
        vm.prank(creator);
        vm.expectRevert(HookRequestCodec.InvalidClock.selector);
        automatic.commitArtifact(jobId, artifact, COMMIT);
        assertEq(automatic.candidateDigest(jobId), bytes32(0));
        _native(1010);
        _commit(jobId, _artifact(jobId));
        _native(1 << 53); // the protocol also requires exact JavaScript integers
        vm.expectRevert();
        automatic.requestVerdict(askId);
        assertEq(automatic.reserved(address(imd)), 2 * FEE);
        _native(1018);
        verdictId = automatic.requestVerdict(askId);
        assertTrue(intake.fail(verdictId, 2, "disagreed", 2, 7));
        uint256 balance = imd.balanceOf(creator);
        _native(1 << 64);
        vm.prank(creator);
        vm.expectRevert();
        automatic.retryVerdict(jobId, FEE);
        assertEq(imd.balanceOf(creator), balance);
        assertEq(automatic.jobAsk(jobId), askId);
    }

    function testUnavailableAndMalformedArbSysNeverFallbackToBlockNumber() public {
        _robinhood(1000);
        for (uint256 i; i < 3; ++i) {
            uint256 snap = vm.snapshotState();
            if (i == 0) vm.etch(address(100), hex"60006000fd"); // revert
            if (i == 1) vm.etch(address(100), hex"60016000f3"); // short return
            if (i == 2) vm.etch(address(100), hex"60406000f3"); // oversized return
            vm.prank(creator);
            vm.expectRevert();
            automatic.openJob(spec, address(gated), "bounded hook", FEE, FEE);
            assertEq(imd.balanceOf(creator), 100 ether);
            assertTrue(vm.revertToStateAndDelete(snap));
        }
    }

    function testEthereumAndSepoliaUseEVMClockEvenWithArbSysCode() public {
        _robinhood(999_999);
        vm.roll(1234);
        vm.chainId(1);
        assertEq(automatic.head(), 1234);
        vm.chainId(11155111);
        assertEq(automatic.head(), 1234);
    }

    function testSignedIssuanceExpiryAndAgeBoundaries() public {
        _ready();
        OracleAttestation.Attestation memory a = _att(askId, true);
        uint256 now_ = vm.getBlockTimestamp();
        a.expiresAt = uint64(now_ + 2 hours);
        bytes memory sig = _sign(a);
        uint256 snap = vm.snapshotState();
        vm.warp(now_ + 1 hours + 1);
        assertTrue(intake.complete(verdictId, abi.encode(verdictId, a, sig)));
        assertTrue(vm.revertToStateAndDelete(snap));
        for (uint256 i; i < 3; ++i) {
            snap = vm.snapshotState();
            OracleAttestation.Attestation memory bad = _att(askId, false);
            if (i == 0) bad.issuedAt = uint64(now_ - 1);
            if (i == 1) bad.issuedAt = uint64(now_ + 301);
            if (i == 2) bad.expiresAt = uint64(now_ - 1);
            assertFalse(intake.complete(verdictId, abi.encode(verdictId, bad, _sign(bad))));
            assertFalse(automatic.consumed(bad.requestId));
            assertTrue(vm.revertToStateAndDelete(snap));
        }
        vm.warp(now_ + 1 hours);
        assertTrue(intake.complete(verdictId, abi.encode(verdictId, a, sig)));
    }

    function testReadinessDeadlineUnknownAndSettledBoundaries() public {
        _assertReadiness(keccak256("unknown"), false, 1000, 0, 992);
        (jobId, askId) = _open();
        _deliver(jobId);
        _commit(jobId, _artifact(jobId));
        vm.roll(1008);
        uint256 deadline = automatic.getJob(jobId).deadline;
        vm.warp(deadline + 1);
        _assertReadiness(askId, false, 1008, 1000, 1000);
        vm.expectRevert(AutoHookJobRequester.NotReady.selector);
        automatic.requestVerdict(askId);
        assertEq(automatic.reserved(address(imd)), FEE);
        vm.warp(deadline);
        _assertReadiness(askId, true, 1008, 1000, 1000);
        verdictId = automatic.requestVerdict(askId);
        _assertReadiness(askId, false, 1008, 1000, 1000);
        _answer(false);
        _assertReadiness(askId, false, 1008, 1000, 1000);
    }

    function testQuoteCapsAndSnapshottedReserveSurviveSizeRefactoring() public {
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(AutoHookJobRequester.PriceExceeded.selector, FEE, FEE - 1));
        automatic.openJob(spec, address(gated), "bounded hook", FEE - 1, FEE);
        assertEq(imd.balanceOf(address(intake)), 0);
        (jobId, askId) = _open();
        _deliver(jobId);
        _commit(jobId, _artifact(jobId));
        automatic.setProtocol(address(intake), address(imd), FEE / 2, automatic.jobAction(), automatic.reviewAction());
        vm.roll(1008);
        verdictId = automatic.requestVerdict(askId); // already-prepaid reserve keeps its original cap
        assertEq(imd.balanceOf(address(intake)), 2 * FEE);
        assertTrue(intake.fail(verdictId, 2, "disagreed", 2, 7));
        vm.prank(creator);
        vm.expectRevert(AutoHookJobRequester.InvalidConfig.selector);
        automatic.retryVerdict(jobId, FEE); // a new payment obeys the current cap
    }

    function testDeployerBindingStillCheckedBeforePayment() public {
        vm.prank(creator);
        vm.expectRevert(HookRequestCodec.InvalidConfig.selector);
        automatic.openJob(spec, outsider, "bounded hook", FEE, FEE);
        assertEq(imd.balanceOf(address(intake)), 0);
        assertEq(automatic.reserved(address(imd)), 0);
    }

    function testWindowAgePolicyCannotMakeFreshestWindowUnusable() public {
        vm.expectRevert(AutoHookJobRequester.InvalidConfig.selector);
        automatic.setPanel(7, 5, 7);
        automatic.setPanel(7, 5, 8);
        _ready();
        _answer(true); // age == depth is the minimum valid policy, with no delivery slack
    }

    function testOfficialOracleQuestionVectorAndExistingPrefixAgree() public {
        OracleQuestion.Question memory q;
        q.question = "Which Uniswap v4 pool did the most WETH volume in the last day?";
        q.chainId = 1;
        q.fromBlock = 100;
        q.toBlock = 200;
        q.answerType = 5;
        q.head = 1;
        q.definitions = new OracleQuestion.Definition[](1);
        q.definitions[0] =
            OracleQuestion.Definition("denomination", "WETH, summed as the absolute swapped amount on the WETH side");
        bytes32 expected = 0x2117f4362ebfa37aa8a8c0fed548604fe09ac46faf8ae7559cd64780f26a46fb;
        assertEq(OracleQuestion.hash(q), expected);
        bytes memory prefix =
            '{"answerType":"bytes32[]","chainId":1,"definitions":{"denomination":"WETH, summed as the absolute swapped amount on the WETH side"},"head":1,"question":"Which Uniswap v4 pool did the most WETH volume in the last day?","v":1,"window":{"fromBlock":';
        assertEq(keccak256(codec.document(prefix, 100, 200)), expected);
    }

    function _checkOfficialQuestionAndSaveBody() private {
        (jobId, askId) = _open();
        _deliver(jobId);
        _commit(jobId, _artifact(jobId));
        if (block.chainid == 4663) _native(900_008);
        else vm.roll(1008);
        verdictId = automatic.requestVerdict(askId);
        string memory body = string(intake.bodyOf(verdictId));
        OracleQuestion.Question memory q;
        q.question = vm.parseJsonString(body, ".question");
        q.chainId = vm.parseJsonUint(body, ".chainId");
        q.fromBlock = vm.parseJsonUint(body, ".window.fromBlock");
        q.toBlock = vm.parseJsonUint(body, ".window.toBlock");
        q.answerType = 0;
        q.panelEvidence = true;
        q.definitions = new OracleQuestion.Definition[](3);
        q.definitions[0] = OracleQuestion.Definition("acceptance", vm.parseJsonString(body, ".definitions.acceptance"));
        q.definitions[1] = OracleQuestion.Definition("build", vm.parseJsonString(body, ".definitions.build"));
        q.definitions[2] = OracleQuestion.Definition("review", vm.parseJsonString(body, ".definitions.review"));
        assertEq(OracleQuestion.hash(q), automatic.expectedQuestionHash(askId, uint64(q.fromBlock), uint64(q.toBlock)));
        emit log_named_string("JOB_BODY", string(intake.bodyOf(jobId)));
        emit log_named_string("ORACLE_BODY", body);
        emit log_named_bytes32("QUESTION_HASH", OracleQuestion.hash(q));
        // Exact signed window ends at the latest input, eight blocks before this trigger.
        assertEq(q.fromBlock, q.toBlock);
        _answer(true);
    }

    function testSaveEthereumBodyAndOfficialQuestionCompatibility() public {
        vm.chainId(1);
        spec.chainId = 1;
        _checkOfficialQuestionAndSaveBody();
    }

    function testSaveRobinhoodBodyAndOfficialQuestionCompatibility() public {
        _robinhood(900_000);
        _checkOfficialQuestionAndSaveBody();
    }
}

/// @dev Repeat every isolated EOA/ERC-1271 and job callback gas check with an actual
/// external system-clock read and native heights far from Solidity's block.number.
contract EthereumAutomaticGasTest is AutomaticGasTest {
    function _ready() internal override {
        vm.chainId(1);
        spec.chainId = 1;
        super._ready();
    }
}

contract RobinhoodAutomaticGasTest is AutomaticGasTest {
    function _ready() internal override {
        vm.chainId(4663);
        spec.chainId = 4663;
        vm.etch(address(100), type(WindowArbSysMock).runtimeCode);
        WindowArbSysMock arb = WindowArbSysMock(address(100));
        arb.setHead(900_000);
        (jobId, askId) = _open();
        artifact = _artifact(jobId);
        _deliver(jobId);
        _commit(jobId, artifact);
        arb.setHead(900_008);
        verdictId = automatic.requestVerdict(askId);
    }
}
