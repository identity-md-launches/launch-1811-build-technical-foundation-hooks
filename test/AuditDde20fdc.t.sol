// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AutomaticFixture} from "./AutomaticBinding.t.sol";
import {AutoHookJobRequester} from "../src/imd/automatic/AutoHookJobRequester.sol";
import {HookJobRequester} from "../src/imd/HookJobRequester.sol";
import {TestToken} from "./helpers/TestToken.sol";
import {MockIntake} from "./helpers/MockIntake.sol";

interface TokenCaps {
    function maxPriceOf(address token) external view returns (uint256);
}

contract AuditDde20fdcTest is AutomaticFixture {
    function _protocol(TestToken token, uint256 cap) private {
        automatic.setProtocol(address(intake), address(token), cap, automatic.jobAction(), automatic.reviewAction());
    }

    function _prepared(bool sixDecimals) private returns (TestToken token, uint256 fee, uint256 cap) {
        token = sixDecimals ? new TestToken("local six decimals", 6) : imd;
        fee = sixDecimals ? 500_000 : FEE;
        cap = 2 * fee;
        _protocol(token, cap);
        intake.setPrice(automatic.jobAction(), address(token), fee);
        intake.setPrice(automatic.reviewAction(), address(token), fee);
        token.mint(creator, 100 * cap);
        vm.startPrank(creator);
        token.approve(address(automatic), 100 * cap);
        (jobId, askId) = automatic.openJob(spec, address(gated), "bounded hook", fee, fee);
        vm.stopPrank();
        _deliver(jobId);
        _commit(jobId, _artifact(jobId));
        vm.roll(vm.getBlockNumber() + 8);
    }

    function _rotate(bool fromSix) private returns (TestToken replacement) {
        replacement = new TestToken("replacement local asset", fromSix ? 18 : 6);
        _protocol(replacement, fromSix ? 2 ether : 2_000_000);
    }

    function testRotation18To6TopUpKeepsOriginalUnits() public {
        _topUp(false);
    }

    function testRotation6To18TopUpKeepsOriginalUnits() public {
        _topUp(true);
    }

    function _topUp(bool fromSix) private {
        (TestToken token, uint256 fee, uint256 cap) = _prepared(fromSix);
        bytes32 jobBefore = keccak256(abi.encode(automatic.getJob(jobId)));
        bytes32 askBefore = keccak256(abi.encode(automatic.getAsk(askId)));
        bytes32 candidate = automatic.candidateDigest(jobId);
        _rotate(fromSix);
        intake.setPrice(automatic.reviewAction(), address(token), fee + 1);
        vm.prank(creator);
        automatic.topUpReserve(jobId, 1);
        assertEq(automatic.reserved(address(token)), fee + 1);
        assertEq(keccak256(abi.encode(automatic.getJob(jobId))), jobBefore);
        assertEq(keccak256(abi.encode(automatic.getAsk(askId))), askBefore);
        assertEq(automatic.candidateDigest(jobId), candidate);
        assertEq(automatic.jobAsk(jobId), askId);
        assertEq(token.balanceOf(address(intake)), fee);
        vm.prank(creator);
        vm.expectRevert(AutoHookJobRequester.InvalidConfig.selector);
        automatic.topUpReserve(jobId, cap - fee); // total cap + 1, regardless of current asset units
        (bool ready,,,) = automatic.verdictReadiness(askId);
        assertFalse(ready);
        vm.roll(vm.getBlockNumber() + 8);
        verdictId = automatic.requestVerdict(askId);
        _answer(false);
        assertEq(token.balanceOf(address(intake)), 2 * fee + 1);
        assertEq(automatic.reserved(address(token)), 0);
    }

    function testRotation18To6RetryKeepsOriginalUnits() public {
        _retry(false);
    }

    function testRotation6To18RetryKeepsOriginalUnits() public {
        _retry(true);
    }

    function _retry(bool fromSix) private {
        (TestToken token, uint256 fee, uint256 cap) = _prepared(fromSix);
        verdictId = automatic.requestVerdict(askId);
        assertTrue(intake.fail(verdictId, 2, "no answer", 0, 7));
        _rotate(fromSix);
        vm.prank(creator);
        vm.expectRevert(AutoHookJobRequester.InvalidConfig.selector);
        automatic.retryVerdict(jobId, cap + 1);
        vm.prank(creator);
        bytes32 next = automatic.retryVerdict(jobId, fee);
        assertNotEq(next, askId);
        assertEq(next, keccak256(abi.encode(block.chainid, address(automatic), uint256(2))));
        assertEq(automatic.reserved(address(token)), fee);
        assertEq(automatic.getAsk(next).jobId, jobId);
        vm.roll(vm.getBlockNumber() + 8);
        askId = next;
        verdictId = automatic.requestVerdict(askId);
        _answer(true);
    }

    function testConstructorAndRotationsOnlyWriteSelectedTokenCap() public {
        assertEq(TokenCaps(address(automatic)).maxPriceOf(address(imd)), FEE);
        TestToken other = _rotate(false);
        assertEq(TokenCaps(address(automatic)).maxPriceOf(address(imd)), FEE);
        assertEq(TokenCaps(address(automatic)).maxPriceOf(address(other)), 2_000_000);
        assertEq(automatic.maxPrice(), 2_000_000);
        _protocol(imd, 3 * FEE);
        assertEq(automatic.maxPrice(), 3 * FEE);
        assertEq(TokenCaps(address(automatic)).maxPriceOf(address(other)), 2_000_000);
        assertEq(TokenCaps(address(automatic)).maxPriceOf(outsider), 0);
    }

    function testSameTokenReductionSurvivesRotationAndFundedTriggerStillWorks() public {
        (TestToken token, uint256 fee,) = _prepared(false);
        _protocol(token, fee - 1);
        _rotate(false);
        vm.prank(creator);
        vm.expectRevert(AutoHookJobRequester.InvalidConfig.selector);
        automatic.topUpReserve(jobId, 1);
        verdictId = automatic.requestVerdict(askId); // already funded reserve retains its bound
        assertTrue(intake.fail(verdictId, 2, "no answer", 0, 7));
        vm.prank(creator);
        vm.expectRevert(AutoHookJobRequester.InvalidConfig.selector);
        automatic.retryVerdict(jobId, fee);
        _protocol(token, fee);
        vm.prank(creator);
        askId = automatic.retryVerdict(jobId, fee);
        assertEq(automatic.reserved(address(token)), fee);
    }

    function testNewJobsUseCurrentAssetCapAndAskNonceIsShared() public {
        _prepared(false);
        assertEq(askId, keccak256(abi.encode(block.chainid, address(automatic), uint256(1))));
        verdictId = automatic.requestVerdict(askId);
        assertTrue(intake.fail(verdictId, 2, "no answer", 0, 7));
        vm.prank(creator);
        bytes32 retry = automatic.retryVerdict(jobId, FEE);
        assertEq(retry, keccak256(abi.encode(block.chainid, address(automatic), uint256(2))));
        TestToken other = _rotate(false);
        intake.setPrice(automatic.jobAction(), address(other), 500_000);
        intake.setPrice(automatic.reviewAction(), address(other), 500_000);
        other.mint(creator, 10_000_000);
        vm.startPrank(creator);
        other.approve(address(automatic), 10_000_000);
        vm.expectRevert(abi.encodeWithSelector(AutoHookJobRequester.PriceExceeded.selector, 2_000_001, 2_000_000));
        automatic.openJob(spec, address(gated), "bounded hook", 500_000, 2_000_001);
        (, bytes32 next) = automatic.openJob(spec, address(gated), "bounded hook", 500_000, 500_000);
        vm.stopPrank();
        assertEq(next, keccak256(abi.encode(block.chainid, address(automatic), uint256(3))));
        assertEq(automatic.reserved(address(other)), 500_000);
        assertEq(automatic.reserved(address(imd)), FEE);
    }
}
