// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AutomaticFixture} from "./AutomaticBinding.t.sol";
import {WindowArbSysMock} from "./OracleWindowRegression.t.sol";
import {AutoHookJobRequester} from "../src/imd/automatic/AutoHookJobRequester.sol";
import {HookJobRequester} from "../src/imd/HookJobRequester.sol";
import {HookRequestCodec} from "../src/imd/automatic/HookRequestCodec.sol";
import {OracleAttestation} from "../src/imd/OracleAttestation.sol";
import {GatedHookDeployer} from "../src/deployment/GatedHookDeployer.sol";
import {MockIntake} from "./helpers/MockIntake.sol";
import {TestToken} from "./helpers/TestToken.sol";
import {StoreTokenMock} from "./helpers/StoreTokenMock.sol";

// Interfaces let the original red regressions compile before the implementation exists.
interface ReserveFunding {
    function topUpReserve(bytes32 jobId, uint256 amount) external;
    function verdictFunding(bytes32 askId) external view returns (uint256 price, uint256 reserve, address token);
}

contract Audit7db42bb7Test is AutomaticFixture {
    function _chain(uint256 chain) internal virtual {
        vm.chainId(chain);
        spec.chainId = chain;
        if (chain == 4663) {
            _installNativeClock();
            WindowArbSysMock(address(100)).setHead(900_000);
        }
        automatic = new AutoHookJobRequester(address(this), address(intake), address(imd), vm.addr(key), 2 * FEE, codec);
        gated = new GatedHookDeployer(address(this), HookJobRequester(address(automatic)));
        vm.prank(creator);
        imd.approve(address(automatic), 100 ether);
    }

    function _advance(uint256 blocks_) internal {
        if (block.chainid == 4663) {
            WindowArbSysMock(address(100)).setHead(uint256(automatic.head()) + blocks_);
        } else {
            vm.roll(vm.getBlockNumber() + blocks_);
        }
    }

    function _prepared() internal {
        (jobId, askId) = _open();
        _deliver(jobId);
        artifact = _artifact(jobId);
        _commit(jobId, artifact);
        _advance(8);
    }

    function _horizon(uint256 chain, bool passed) internal {
        _chain(chain);
        _prepared();
        verdictId = automatic.requestVerdict(askId);
        AutoHookJobRequester.Ask memory ctx = automatic.getAsk(askId);
        OracleAttestation.Attestation memory a = _att(askId, passed);
        a.issuedAt = ctx.deadline + 300;
        a.expiresAt = a.issuedAt + 1 days;
        // Advance BOTH clocks at the specified cadence floor for the entire delivery horizon.
        vm.warp(a.expiresAt);
        _advance(chain == 4663 ? 3_462_000 : chain == 31337 ? 173_100 : 14_425);
        assertEq(uint256(automatic.head()) - ctx.toBlock, chain == 4663 ? 3_462_008 : chain == 31337 ? 173_108 : 14_433);
        assertTrue(intake.complete(verdictId, abi.encode(verdictId, a, _sign(a))), "full-horizon valid answer lost");
        assertEq(
            uint8(_review(jobId)),
            uint8(passed ? HookJobRequester.ReviewStatus.Passed : HookJobRequester.ReviewStatus.NotPassed)
        );
        assertEq(automatic.approvedArtifact(jobId), passed ? automatic.candidateDigest(jobId) : bytes32(0));
        assertTrue(automatic.consumed(a.requestId));
        if (!passed) {
            vm.prank(creator);
            vm.expectRevert(AutoHookJobRequester.NotReady.selector);
            automatic.retryVerdict(jobId, FEE);
        }
    }

    function testFullHorizonEthereumTrue() public {
        _horizon(1, true);
    }

    function testFullHorizonEthereumFalse() public {
        _horizon(1, false);
    }

    function testFullHorizonRobinhoodTrue() public {
        _horizon(4663, true);
    }

    function testFullHorizonRobinhoodFalse() public {
        _horizon(4663, false);
    }

    function testFullHorizonSepolia() public {
        _horizon(11155111, true);
    }

    function testFullHorizonLocal() public {
        _horizon(31337, false);
    }

    function testOwnerCannotPreemptStillValidFalseAtDeadline() public {
        _ready();
        AutoHookJobRequester.Ask memory ctx = automatic.getAsk(askId);
        vm.warp(uint256(ctx.deadline) + 1);
        vm.expectRevert(AutoHookJobRequester.DeadlineNotReached.selector);
        automatic.confirmReviewExpiry(verdictId);
        _answer(false);
    }

    function testExpiryStrictlyAfterLastValidDelivery() public {
        _ready();
        uint256 last = uint256(automatic.getAsk(askId).deadline) + 300 + 1 days;
        vm.warp(last);
        vm.expectRevert(AutoHookJobRequester.DeadlineNotReached.selector);
        automatic.confirmReviewExpiry(verdictId);
        vm.warp(last + 1);
        automatic.confirmReviewExpiry(verdictId);
        assertEq(uint8(_review(jobId)), uint8(HookJobRequester.ReviewStatus.Unanswered));
    }

    function testPriceRiseTopUpPreservesBuildCandidateAndAsk() public {
        _chain(31337);
        _prepared();
        intake.setPrice(automatic.reviewAction(), address(imd), FEE + 1);
        bytes32 digest = automatic.candidateDigest(jobId);
        vm.prank(creator);
        ReserveFunding(address(automatic)).topUpReserve(jobId, 1);
        (uint256 price, uint256 reserve, address token) = ReserveFunding(address(automatic)).verdictFunding(askId);
        assertEq(price, FEE + 1);
        assertEq(reserve, FEE + 1);
        assertEq(token, address(imd));
        assertEq(automatic.jobAsk(jobId), askId);
        assertEq(automatic.candidateDigest(jobId), digest);
        assertEq(imd.balanceOf(address(intake)), FEE, "must not repay the build");
        assertEq(automatic.reserved(address(imd)), FEE + 1);
        (bool ready,,,) = automatic.verdictReadiness(askId);
        assertFalse(ready, "top-up refresh must mature again");
        _advance(8);
        verdictId = automatic.requestVerdict(askId);
        _answer(false);
    }

    function testChainPolicyConstructorAndSetterBoundaries() public {
        uint256[4] memory chains = [uint256(1), 11155111, 4663, 31337];
        uint64[4] memory minimums = [uint64(14_433), 14_433, 3_462_008, 173_108];
        for (uint256 i; i < chains.length; ++i) {
            _chain(chains[i]);
            assertEq(codec.minimumWindowAgeBlocks(), minimums[i]);
            assertEq(automatic.maxWindowAgeBlocks(), minimums[i]);
            vm.expectRevert(AutoHookJobRequester.InvalidConfig.selector);
            automatic.setPanel(7, 5, minimums[i] - 1);
            automatic.setPanel(7, 5, minimums[i] + 10);
            assertEq(automatic.maxWindowAgeBlocks(), minimums[i] + 10);
            automatic.setPanel(7, 5, minimums[i]);
        }
        vm.chainId(999001);
        vm.expectRevert(abi.encodeWithSelector(HookRequestCodec.UnsupportedClock.selector, 999001));
        codec.minimumWindowAgeBlocks();
        vm.expectRevert(abi.encodeWithSelector(HookRequestCodec.UnsupportedClock.selector, 999001));
        new AutoHookJobRequester(address(this), address(intake), address(imd), vm.addr(key), FEE, codec);
    }

    function testPolicyCheckedBeforeNativeClockAndPayment() public {
        // Model an undersized deployment by changing chain after construction. Do not let a
        // missing/malformed native clock mask the policy error or allow even the build payment.
        vm.chainId(4663);
        spec.chainId = 4663;
        vm.mockCallRevert(address(100), abi.encodeWithSignature("arbBlockNumber()"), bytes("clock unavailable"));
        vm.expectRevert(HookRequestCodec.InvalidConfig.selector);
        automatic.head();
        vm.prank(creator);
        vm.expectRevert(HookRequestCodec.InvalidConfig.selector);
        automatic.openJob(spec, address(gated), "bounded hook", FEE, FEE);
        assertEq(imd.balanceOf(creator), 100 ether);
        assertEq(imd.balanceOf(address(intake)), 0);
        automatic.setPanel(7, 5, codec.minimumWindowAgeBlocks());
        vm.expectRevert(HookRequestCodec.InvalidClock.selector);
        automatic.head();
    }

    function testFuzzWindowAgeAndPanelStaySnapshotted(bool robinhood) public {
        _chain(robinhood ? 4663 : 1);
        uint64 minimum = codec.minimumWindowAgeBlocks();
        automatic.setPanel(7, 5, minimum + 100);
        _prepared();
        verdictId = automatic.requestVerdict(askId);
        automatic.setPanel(100, 100, minimum);
        OracleAttestation.Attestation memory a = _att(askId, false);
        _advance(uint256(minimum) + 1 - 8);
        assertTrue(intake.complete(verdictId, abi.encode(verdictId, a, _sign(a))));
        assertEq(uint8(_review(jobId)), uint8(HookJobRequester.ReviewStatus.NotPassed));
    }

    function testFuzzExpiryBothOrdersAtFullHorizonAndOneSecondLater(bool robinhood, bool passed) public {
        _chain(robinhood ? 4663 : 1);
        _prepared();
        verdictId = automatic.requestVerdict(askId);
        OracleAttestation.Attestation memory a = _att(askId, passed);
        a.issuedAt = automatic.getAsk(askId).deadline + 300;
        a.expiresAt = a.issuedAt + 1 days;
        vm.warp(a.expiresAt);
        _advance(robinhood ? 3_462_000 : 14_425);
        bytes memory signature = _sign(a);
        uint256 snapshot = vm.snapshotState();
        assertTrue(intake.complete(verdictId, abi.encode(verdictId, a, signature)));
        vm.expectRevert(AutoHookJobRequester.UnknownOrSettled.selector);
        automatic.confirmReviewExpiry(verdictId);
        assertTrue(vm.revertToStateAndDelete(snapshot));
        snapshot = vm.snapshotState();
        vm.expectRevert(AutoHookJobRequester.DeadlineNotReached.selector);
        automatic.confirmReviewExpiry(verdictId);
        assertTrue(intake.complete(verdictId, abi.encode(verdictId, a, signature)));
        assertTrue(vm.revertToStateAndDelete(snapshot));
        vm.warp(uint256(a.expiresAt) + 1);
        vm.prank(creator);
        vm.expectRevert();
        automatic.confirmReviewExpiry(verdictId);
        // The same signed answer is no longer admissible even before owner closure.
        vm.prank(address(intake));
        vm.expectRevert(AutoHookJobRequester.InvalidWindow.selector);
        automatic.onReviewResult(verdictId, a, signature);
        automatic.confirmReviewExpiry(verdictId);
        assertFalse(intake.complete(verdictId, abi.encode(verdictId, a, signature)));
        assertFalse(automatic.consumed(a.requestId));
        vm.prank(creator);
        bytes32 retry = automatic.retryVerdict(jobId, FEE);
        assertNotEq(retry, askId);
    }

    function testFuzzTopUpRefreshesExpiredOrLiveWindowOnBothClocks(bool robinhood, bool expired) public {
        _chain(robinhood ? 4663 : 1);
        _prepared();
        uint64 previousDeadline = automatic.reserveDeadline(jobId);
        if (expired) vm.warp(uint256(previousDeadline) + 1);
        _advance(30);
        uint64 start = automatic.head();
        bytes32 beforeAsk = keccak256(abi.encode(automatic.getAsk(askId)));
        bytes32 beforeJob = keccak256(abi.encode(automatic.getJob(jobId)));
        bytes32 beforeCandidate = keccak256(abi.encode(automatic.getCandidate(jobId)));
        // A top-up does not buy anything or require an available quote.
        intake.setPrice(automatic.reviewAction(), address(imd), 0);
        vm.prank(creator);
        automatic.topUpReserve(jobId, FEE);
        assertEq(automatic.reserveDeadline(jobId), expired ? vm.getBlockTimestamp() + 1 days : previousDeadline);
        assertEq(keccak256(abi.encode(automatic.getAsk(askId))), beforeAsk);
        assertEq(keccak256(abi.encode(automatic.getJob(jobId))), beforeJob);
        assertEq(keccak256(abi.encode(automatic.getCandidate(jobId))), beforeCandidate);
        assertEq(automatic.jobAsk(jobId), askId);
        assertEq(automatic.reserved(address(imd)), 2 * FEE);
        for (uint256 i; i < 8; ++i) {
            (bool ready,, uint64 from,) = automatic.verdictReadiness(askId);
            assertFalse(ready);
            assertEq(from, start);
            vm.expectRevert(AutoHookJobRequester.NotReady.selector);
            automatic.requestVerdict(askId);
            _advance(1);
        }
        intake.setPrice(automatic.reviewAction(), address(imd), 2 * FEE);
        verdictId = automatic.requestVerdict(askId);
        _answer(true);
        assertEq(imd.balanceOf(address(intake)), 3 * FEE);
    }

    function testTopUpPositiveCapOverflowAndRequesterChecksAreAtomic() public {
        _chain(31337);
        _prepared();
        vm.prank(outsider);
        vm.expectRevert(AutoHookJobRequester.NotRequester.selector);
        automatic.topUpReserve(jobId, 1);
        for (uint256 i; i < 3; ++i) {
            uint256 amount = i == 0 ? 0 : i == 1 ? FEE + 1 : type(uint256).max;
            vm.prank(creator);
            vm.expectRevert();
            automatic.topUpReserve(jobId, amount);
            assertEq(automatic.reserved(address(imd)), FEE);
            assertEq(imd.balanceOf(creator), 100 ether - 2 * FEE);
        }
        automatic.setProtocol(address(intake), address(imd), FEE - 1, automatic.jobAction(), automatic.reviewAction());
        vm.prank(creator);
        vm.expectRevert(AutoHookJobRequester.InvalidConfig.selector);
        automatic.topUpReserve(jobId, 1);
        // Lowering the current cap cannot confiscate the already-prepaid reserve.
        verdictId = automatic.requestVerdict(askId);
        _answer(false);
    }

    function _cannotTopUp() private {
        vm.prank(creator);
        vm.expectRevert(AutoHookJobRequester.NotReady.selector);
        automatic.topUpReserve(jobId, 1);
    }

    function testTopUpRejectsUndeliveredUncommittedCancelledAndEverySettledPhase() public {
        _chain(31337);
        (jobId, askId) = _open();
        _cannotTopUp();
        vm.warp(automatic.getJob(jobId).deadline + 1);
        vm.prank(creator);
        automatic.expireJob(jobId);
        _cannotTopUp();
        _deliver(jobId);
        _cannotTopUp(); // Delivered but no immutable candidate
        _commit(jobId, _artifact(jobId));
        vm.warp(automatic.reserveDeadline(jobId) + 1);
        vm.prank(creator);
        automatic.cancelReserve(jobId);
        _cannotTopUp();
        _prepared();
        verdictId = automatic.requestVerdict(askId);
        _cannotTopUp(); // Pending
        uint256 snapshot = vm.snapshotState();
        _answer(true);
        _cannotTopUp();
        assertTrue(vm.revertToStateAndDelete(snapshot));
        snapshot = vm.snapshotState();
        _answer(false);
        _cannotTopUp();
        assertTrue(vm.revertToStateAndDelete(snapshot));
        assertTrue(intake.fail(verdictId, 2, "no answer", 0, 7));
        _cannotTopUp(); // Unanswered needs a new paid retry, never reuse this spent ask
        vm.prank(creator);
        askId = automatic.retryVerdict(jobId, FEE);
        vm.prank(creator);
        automatic.topUpReserve(jobId, 1); // the retry's new unspent ask is eligible
    }

    function testTopUpAndFundingUseOriginalProtocolAndRefundAllSurplus() public {
        _chain(31337);
        _prepared();
        bytes32 originalAction = automatic.reviewAction();
        MockIntake replacement = new MockIntake();
        TestToken other = new TestToken("other local asset", 6);
        automatic.setProtocol(address(replacement), address(other), 2 * FEE, "other build", "other review");
        replacement.setPrice("other review", address(other), 1);
        intake.setPrice(originalAction, address(imd), FEE + FEE / 2);
        vm.prank(creator);
        automatic.topUpReserve(jobId, FEE);
        (uint256 price, uint256 reserve, address token) = automatic.verdictFunding(askId);
        assertEq(price, FEE + FEE / 2);
        assertEq(reserve, 2 * FEE);
        assertEq(token, address(imd));
        _advance(8);
        verdictId = automatic.requestVerdict(askId);
        _answer(true);
        assertEq(imd.balanceOf(address(intake)), FEE + price);
        assertEq(other.balanceOf(address(replacement)), 0);
        assertEq(imd.allowance(address(automatic), address(intake)), 0);
        assertEq(automatic.refunds(address(imd), creator), FEE / 2);
        assertEq(automatic.reserved(address(imd)), FEE / 2);
        vm.expectRevert(AutoHookJobRequester.EscrowProtected.selector);
        automatic.sweep(address(imd), outsider, 1);
        vm.prank(creator);
        automatic.withdrawRefund(address(imd));
        vm.prank(creator);
        automatic.withdrawRefund(address(imd));
        assertEq(imd.balanceOf(creator), 100 ether - FEE - price);
        assertEq(automatic.reserved(address(imd)), 0);
    }

    function testToppedUpUnspentReserveCancelsAndRefundsExactlyOnce() public {
        _chain(31337);
        _prepared();
        vm.prank(creator);
        automatic.topUpReserve(jobId, FEE);
        vm.warp(automatic.reserveDeadline(jobId) + 1);
        vm.prank(creator);
        automatic.cancelReserve(jobId);
        vm.prank(creator);
        automatic.cancelReserve(jobId);
        _cannotTopUp();
        assertEq(automatic.refunds(address(imd), creator), 2 * FEE);
        vm.prank(creator);
        automatic.withdrawRefund(address(imd));
        assertEq(imd.balanceOf(creator), 100 ether - FEE);
        assertEq(automatic.reserved(address(imd)), 0);
    }

    function testFuzzTopUpExactPullAndReentrancy(uint8 mode) public {
        StoreTokenMock token = new StoreTokenMock();
        automatic.setProtocol(address(intake), address(token), 2 * FEE, automatic.jobAction(), automatic.reviewAction());
        intake.setPrice(automatic.jobAction(), address(token), FEE);
        intake.setPrice(automatic.reviewAction(), address(token), FEE);
        token.mint(creator, 100 ether);
        vm.prank(creator);
        token.approve(address(automatic), 100 ether);
        _prepared();
        StoreTokenMock.Mode chosen = StoreTokenMock.Mode(bound(mode, 0, 8));
        token.setMode(chosen);
        token.setCallback(address(automatic), abi.encodeCall(automatic.topUpReserve, (jobId, 1)));
        uint64 deadline = automatic.reserveDeadline(jobId);
        bool valid = chosen == StoreTokenMock.Mode.Good || chosen == StoreTokenMock.Mode.NoReturn;
        vm.prank(creator);
        if (!valid) vm.expectRevert();
        automatic.topUpReserve(jobId, FEE);
        assertEq(automatic.reserved(address(token)), valid ? 2 * FEE : FEE);
        assertEq(token.balanceOf(creator), 100 ether - (valid ? 3 * FEE : 2 * FEE));
        assertEq(automatic.reserveDeadline(jobId), deadline);
        if (valid) {
            assertFalse(token.callbackSucceeded());
            assertEq(bytes4(token.callbackResult()), AutoHookJobRequester.Reentrancy.selector);
        }
    }

    function testFundingZeroUnavailableAndUnknownNeverSpends() public {
        _chain(31337);
        _prepared();
        bytes32 action = automatic.reviewAction();
        intake.setPrice(action, address(imd), 0);
        (uint256 price, uint256 reserve, address token) = automatic.verdictFunding(askId);
        assertEq(price, 0);
        assertEq(reserve, FEE);
        assertEq(token, address(imd));
        vm.expectRevert(AutoHookJobRequester.NotConfigured.selector);
        automatic.requestVerdict(askId);
        vm.mockCallRevert(
            address(intake), abi.encodeCall(intake.priceOf, (action, address(imd))), bytes("quote offline")
        );
        vm.expectRevert();
        automatic.verdictFunding(askId);
        vm.expectRevert();
        automatic.requestVerdict(askId);
        vm.expectRevert(AutoHookJobRequester.NotReady.selector);
        automatic.verdictFunding(keccak256("unknown ask"));
        assertEq(automatic.reserved(address(imd)), FEE);
        assertEq(imd.balanceOf(address(intake)), FEE);
    }
}
