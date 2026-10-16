// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookJobRequesterFixture} from "./HookJobRequester.t.sol";
import {HookJobRequester} from "../src/imd/HookJobRequester.sol";
import {OracleAttestation} from "../src/imd/OracleAttestation.sol";

contract ReviewReceiptPackingTest is HookJobRequesterFixture {
    function _unbound() private returns (bytes32 jobId, bytes32 askId) {
        jobId = _delivered();
        vm.prank(creator);
        askId = requester.requestReview(jobId);
    }

    function _roundTrip(bytes32 jobId, bytes32 askId, OracleAttestation.Attestation memory a) private {
        bytes memory signature = _sign(a, signerKey);
        vm.cool(address(requester));
        assertTrue(intake.complete(askId, abi.encode(askId, a, signature)));
        HookJobRequester.ReviewReceipt memory r = requester.getReviewReceipt(askId);
        assertEq(r.oracleRequestId, a.requestId);
        assertEq(r.questionHash, a.questionHash);
        assertEq(r.questionChainId, a.chainId);
        assertEq(r.panelJobId, a.panelJobId);
        assertEq(r.fromBlock, a.fromBlock);
        assertEq(r.toBlock, a.toBlock);
        assertEq(r.receivedAt, vm.getBlockTimestamp());
        assertEq(r.panelSize, a.panelSize);
        assertEq(r.agreed, a.agreed);
        assertEq(r.passed, abi.decode(a.answer, (bool)));
        assertFalse(requester.consumed(a.requestId));
        assertEq(requester.intakeReviewOfOracle(a.requestId), bytes32(0));
        bytes32 bodyHash = requester.getReviewAsk(askId).bodyHash;
        vm.prank(owner);
        requester.bindReview(askId, bodyHash, a.requestId, a.questionHash, a.chainId, a.fromBlock, a.toBlock);
        HookJobRequester.Job memory job = requester.getJob(jobId);
        assertEq(
            uint8(job.review),
            uint8(r.passed ? HookJobRequester.ReviewStatus.Passed : HookJobRequester.ReviewStatus.NotPassed)
        );
        assertEq(job.reviewPanelJobId, a.panelJobId);
        assertEq(job.reviewPanelSize, a.panelSize);
        assertEq(job.reviewAgreed, a.agreed);
        assertTrue(requester.consumed(a.requestId));
        assertEq(keccak256(abi.encode(requester.getReviewReceipt(askId))), keccak256(abi.encode(r)));
    }

    function testAllocatedMetadataIsNotAnAnswerAndReadAbiRemainsTenWords() public {
        (, bytes32 askId) = _unbound();
        HookJobRequester.ReviewReceipt memory empty;
        assertEq(abi.encode(requester.getReviewReceipt(askId)), abi.encode(empty));
        assertEq(abi.encode(requester.getReviewReceipt(bytes32(0))), abi.encode(empty));
        (bool ok, bytes memory result) =
            address(requester).staticcall(abi.encodeCall(requester.getReviewReceipt, (askId)));
        assertTrue(ok);
        assertEq(result.length, 10 * 32);
    }

    function testFuzzReceiptPreservesFullContextAndPackedFields(
        uint64 fromBlock,
        uint64 toBlock,
        uint64 receivedAt,
        uint16 panel,
        uint16 agreed,
        bool passed,
        uint256 chain
    ) public {
        vm.warp(bound(receivedAt, 0, type(uint64).max - 30 days));
        (bytes32 jobId, bytes32 askId) = _unbound();
        OracleAttestation.Attestation memory a = _attestation(askId, passed);
        a.fromBlock = fromBlock < toBlock ? fromBlock : toBlock;
        a.toBlock = fromBlock < toBlock ? toBlock : fromBlock;
        a.chainId = chain == 0 ? 1 : chain;
        a.panelSize = uint16(bound(panel, 5, type(uint16).max));
        a.agreed = uint16(bound(agreed, 5, a.panelSize));
        a.issuedAt = uint64(vm.getBlockTimestamp());
        a.expiresAt = a.issuedAt + 1 hours;
        _roundTrip(jobId, askId, a);
    }

    function testReceiptPackingMaximumValuesDoNotLeakIntoAdjacentFields() public {
        vm.warp(type(uint64).max - 30 days);
        (bytes32 jobId, bytes32 askId) = _unbound();
        OracleAttestation.Attestation memory a = _attestation(askId, true);
        a.requestId = bytes32(type(uint256).max);
        a.questionHash = bytes32(type(uint256).max);
        a.chainId = type(uint256).max;
        a.panelJobId = bytes32(type(uint256).max);
        a.fromBlock = type(uint64).max;
        a.toBlock = type(uint64).max;
        a.panelSize = type(uint16).max;
        a.agreed = type(uint16).max;
        a.quorum = type(uint16).max;
        a.issuedAt = uint64(vm.getBlockTimestamp());
        a.expiresAt = a.issuedAt + 1 hours;
        _roundTrip(jobId, askId, a);
    }
}
