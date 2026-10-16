// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookJobRequesterFixture} from "./HookJobRequester.t.sol";
import {HookJobRequester} from "../src/imd/HookJobRequester.sol";
import {OracleAttestation, OracleAttestationConsumer} from "../src/imd/OracleAttestation.sol";
import {ThresholdReceiptSigner, ColdReadReceiptSigner} from "./helpers/ReceiptSigners.sol";

contract ReviewReceiptGasTest is HookJobRequesterFixture {
    bytes32 private earlyJob;
    bytes32 private earlyAsk;
    bytes32 private boundJob;
    bytes32 private boundAsk;
    ThresholdReceiptSigner private multisigner;
    ColdReadReceiptSigner private auditSigner;
    ColdReadReceiptSigner private overBudgetSigner;
    uint256[] private memberKeys;

    function setUp() public override {
        super.setUp();
        // Payment and receipt allocation happen in setUp, a separate EVM transaction from each
        // measured test. Otherwise the metadata SSTORE could be unrealistically cheap (dirty).
        earlyJob = _delivered();
        vm.prank(creator);
        earlyAsk = requester.requestReview(earlyJob);
        (boundJob, boundAsk) = _reviewPending();
        address[] memory members = new address[](7);
        for (uint256 i; i < 7; ++i) {
            memberKeys.push(uint256(keccak256(abi.encode("gas test member", i))));
        }
        // Strictly ascending signer addresses allow the registry to reject duplicate signatures.
        for (uint256 i; i < memberKeys.length; ++i) {
            for (uint256 j = i + 1; j < memberKeys.length; ++j) {
                if (vm.addr(memberKeys[j]) < vm.addr(memberKeys[i])) {
                    (memberKeys[i], memberKeys[j]) = (memberKeys[j], memberKeys[i]);
                }
            }
            members[i] = vm.addr(memberKeys[i]);
        }
        multisigner = new ThresholdReceiptSigner(members, 5);
        auditSigner = new ColdReadReceiptSigner(signer, 22);
        overBudgetSigner = new ColdReadReceiptSigner(signer, 64);
    }

    function _useSigner(address oracle) private {
        vm.prank(owner);
        requester.setOracleSigner(oracle);
    }

    function _multisig(OracleAttestation.Attestation memory a) private view returns (bytes memory signature) {
        for (uint256 i; i < 5; ++i) {
            signature = bytes.concat(signature, _sign(a, memberKeys[i]));
        }
    }

    function _confirm(bytes32 askId, OracleAttestation.Attestation memory a) private {
        bytes32 bodyHash = requester.getReviewAsk(askId).bodyHash;
        vm.prank(owner);
        requester.bindReview(askId, bodyHash, a.requestId, a.questionHash, a.chainId, a.fromBlock, a.toBlock);
    }

    function _complete(bytes32 askId, OracleAttestation.Attestation memory a, bytes memory signature, address oracle)
        private
        returns (bool)
    {
        bytes memory payload = abi.encode(askId, a, signature);
        vm.cool(address(requester));
        vm.cool(oracle);
        return intake.complete(askId, payload);
    }

    /// @dev Minimum *forwarded* gas, not a test/transaction gas report, refunded cost, or a
    /// warmed estimate. Restore state and cool the entire consumer and signer on EVERY trial.
    function _minimumGas(bytes32 askId, OracleAttestation.Attestation memory a, bytes memory signature, address oracle)
        private
        returns (uint256)
    {
        bytes memory payload = abi.encodeCall(requester.onReviewResult, (askId, a, signature));
        uint256 low = 50_000;
        uint256 high = 300_000;
        while (low < high) {
            uint256 cap = (low + high) / 2;
            uint256 snapshot = vm.snapshotState();
            vm.cool(address(requester));
            vm.cool(oracle);
            vm.prank(address(intake));
            (bool success,) = address(requester).call{gas: cap}(payload);
            assertTrue(vm.revertToStateAndDelete(snapshot));
            if (success) high = cap;
            else low = cap + 1;
        }
        return high;
    }

    function testColdEoaReceiptGasAndExactStipend() public {
        OracleAttestation.Attestation memory a = _attestation(earlyAsk, false);
        bytes memory signature = _sign(a, signerKey);
        uint256 gasUsed = _minimumGas(earlyAsk, a, signature, signer);
        emit log_named_uint("Cold EOA receipt minimum forwarded gas", gasUsed);
        assertLt(gasUsed, 140_000);
        assertTrue(_complete(earlyAsk, a, signature, signer));
        _confirm(earlyAsk, a);
        assertEq(uint8(_review(earlyJob)), uint8(HookJobRequester.ReviewStatus.NotPassed));
    }

    function testColdFiveOfSevenReceiptAndBoundCallbacksFitStipend() public {
        _useSigner(address(multisigner));
        OracleAttestation.Attestation memory a = _attestation(earlyAsk, false);
        bytes memory signature = _multisig(a);
        // The signer itself performs five recoveries and eleven cold policy/config SLOADs.
        bytes memory callData =
            abi.encodeCall(multisigner.isValidSignature, (requester.attestationDigest(a), signature));
        vm.cool(address(multisigner));
        (bool verified, bytes memory result) = address(multisigner).staticcall{gas: 60_000}(callData);
        assertTrue(verified, "supported cold signer budget is 60k");
        assertEq(abi.decode(result, (bytes4)), bytes4(0x1626ba7e));
        uint256 earlyGas = _minimumGas(earlyAsk, a, signature, address(multisigner));
        emit log_named_uint("Cold 5-of-7 receipt minimum forwarded gas", earlyGas);
        assertLt(earlyGas, 190_000, "retain at least 10k of the 200k cap");
        assertTrue(_complete(earlyAsk, a, signature, address(multisigner)));
        assertEq(uint8(_review(earlyJob)), uint8(HookJobRequester.ReviewStatus.Pending));
        assertEq(requester.getReviewReceipt(earlyAsk).oracleRequestId, a.requestId);
        _confirm(earlyAsk, a);
        assertEq(uint8(_review(earlyJob)), uint8(HookJobRequester.ReviewStatus.NotPassed));
        OracleAttestation.Attestation memory b = _attestation(boundAsk, true);
        signature = _multisig(b);
        uint256 boundGas = _minimumGas(boundAsk, b, signature, address(multisigner));
        emit log_named_uint("Cold 5-of-7 bound minimum forwarded gas", boundGas);
        assertLt(boundGas, 200_000);
        assertTrue(_complete(boundAsk, b, signature, address(multisigner)));
        assertEq(uint8(_review(boundJob)), uint8(HookJobRequester.ReviewStatus.Passed));
    }

    function testAudit22ColdReadsNowRetainsOneShotReceiptAndBoundVerdict() public {
        _useSigner(address(auditSigner));
        OracleAttestation.Attestation memory a = _attestation(earlyAsk, true);
        bytes memory signature = _sign(a, signerKey);
        uint256 gasUsed = _minimumGas(earlyAsk, a, signature, address(auditSigner));
        emit log_named_uint("Cold audit registry +22 reads receipt minimum forwarded gas", gasUsed);
        assertLt(gasUsed, 195_000, "audit regression must fit with headroom");
        assertTrue(_complete(earlyAsk, a, signature, address(auditSigner)));
        assertEq(requester.getReviewReceipt(earlyAsk).oracleRequestId, a.requestId);
        _confirm(earlyAsk, a);
        OracleAttestation.Attestation memory b = _attestation(boundAsk, false);
        signature = _sign(b, signerKey);
        gasUsed = _minimumGas(boundAsk, b, signature, address(auditSigner));
        emit log_named_uint("Cold audit registry +22 reads bound minimum forwarded gas", gasUsed);
        assertTrue(_complete(boundAsk, b, signature, address(auditSigner)));
        assertEq(uint8(_review(earlyJob)), uint8(HookJobRequester.ReviewStatus.Passed));
        assertEq(uint8(_review(boundJob)), uint8(HookJobRequester.ReviewStatus.NotPassed));
        assertEq(imd.balanceOf(address(intake)), 4 * PRICE, "no second fee");
    }

    function testOverBudgetSignerStillFailsClosedAndLosesSingleAttemptWithoutPartialReceipt() public {
        _useSigner(address(overBudgetSigner));
        OracleAttestation.Attestation memory a = _attestation(earlyAsk, true);
        bytes memory signature = _sign(a, signerKey);
        assertFalse(_complete(earlyAsk, a, signature, address(overBudgetSigner)));
        assertEq(requester.getReviewReceipt(earlyAsk).oracleRequestId, bytes32(0));
        assertFalse(requester.consumed(a.requestId));
        assertEq(requester.intakeReviewOfOracle(a.requestId), bytes32(0));
        assertEq(uint8(_review(earlyJob)), uint8(HookJobRequester.ReviewStatus.Pending));
        (,,,,,, bool settled) = intake.reqs(earlyAsk);
        assertTrue(settled);
        bytes memory payload = abi.encode(earlyAsk, a, signature);
        vm.expectRevert("not pending");
        intake.complete(earlyAsk, payload);
        vm.warp(requester.getReviewAsk(earlyAsk).deadline + 1);
        vm.prank(creator);
        requester.expireReview(earlyJob);
        assertEq(imd.balanceOf(address(intake)), 4 * PRICE, "gas failure has no refund");
        assertEq(uint8(_review(earlyJob)), uint8(HookJobRequester.ReviewStatus.Unanswered));
    }

    function testFuzzMultisignerRefusesWrongKeyDuplicateRevokedExpiredOrInsufficientSignatures(uint8 fault) public {
        fault = uint8(bound(fault, 0, 4));
        _useSigner(address(multisigner));
        OracleAttestation.Attestation memory a = _attestation(earlyAsk, true);
        if (fault == 3) {
            vm.warp(vm.getBlockTimestamp() + 31 days);
            // Read the mutated clock through the cheatcode, avoiding compiler timestamp caching.
            // Attestation is fresh; only signer membership has expired.
            a.issuedAt = uint64(vm.getBlockTimestamp());
            a.expiresAt = a.issuedAt + 1 hours;
        }
        bytes memory signature;
        for (uint256 i; i < (fault == 4 ? 4 : 5); ++i) {
            uint256 key = memberKeys[i];
            if (fault == 0 && i == 0) key = signerKey;
            if (fault == 1 && i == 1) key = memberKeys[0];
            signature = bytes.concat(signature, _sign(a, key));
        }
        if (fault == 2) multisigner.revoke(vm.addr(memberKeys[0]));
        vm.prank(address(intake));
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        requester.onReviewResult(earlyAsk, a, signature);
        assertFalse(_complete(earlyAsk, a, signature, address(multisigner)));
        assertEq(requester.getReviewReceipt(earlyAsk).oracleRequestId, bytes32(0));
        assertFalse(requester.consumed(a.requestId));
    }
}
